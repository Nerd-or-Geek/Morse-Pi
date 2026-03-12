// ============================================================================
//  Morse-Pi — Zig backend.  HTTP server, route dispatch, all handlers.
//
//  Entry-point: `main()` at the bottom.
//  Uses a simple TCP-based HTTP/1.1 server with one thread per connection.
// ============================================================================
const std = @import("std");
const state = @import("state.zig");
const morse = @import("morse.zig");
const keyboard = @import("keyboard.zig");
const gpio = @import("gpio.zig");
const sound = @import("sound.zig");
const network = @import("network.zig");

// ════════════════════════════════════════════════════════════════════════════
//  HTTP HELPERS
// ════════════════════════════════════════════════════════════════════════════

const Method = enum { GET, POST, OTHER };

const Request = struct {
    method: Method,
    path: []const u8,
    body: []const u8,
};

/// Parse an HTTP request from the stream.  Returns null on error.
fn parseRequest(stream: std.net.Stream) ?Request {
    var buf: [65536]u8 = undefined;
    var total: usize = 0;

    // Read until we have the full headers
    while (total < buf.len) {
        const n = stream.read(buf[total..]) catch return null;
        if (n == 0) return null;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
    }

    const data = buf[0..total];
    const req_line_end = std.mem.indexOf(u8, data, "\r\n") orelse return null;
    const req_line = data[0..req_line_end];

    // Parse "METHOD /path HTTP/1.x"
    var parts = std.mem.splitScalar(u8, req_line, ' ');
    const method_str = parts.next() orelse return null;
    const path = parts.next() orelse return null;

    const method: Method = if (std.mem.eql(u8, method_str, "GET"))
        .GET
    else if (std.mem.eql(u8, method_str, "POST"))
        .POST
    else
        .OTHER;

    // Find headers end
    const header_end = (std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null) + 4;

    // Check Content-Length for body
    var content_length: usize = 0;
    var header_it = std.mem.splitSequence(u8, data[0..header_end], "\r\n");
    _ = header_it.next(); // skip request line
    while (header_it.next()) |line| {
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const val = std.mem.trimLeft(u8, line["content-length:".len..], " ");
            content_length = std.fmt.parseInt(usize, val, 10) catch 0;
        }
    }

    // Read body if needed
    const body_start = header_end;
    var body_data = data[body_start..total];
    if (content_length > 0 and body_data.len < content_length) {
        // Need to read more body data — for simplicity, read remaining into buf
        while (total - header_end < content_length and total < buf.len) {
            const n = stream.read(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
        body_data = buf[header_end..@min(header_end + content_length, total)];
    } else if (content_length > 0) {
        body_data = data[header_end..@min(header_end + content_length, total)];
    } else {
        body_data = &.{};
    }

    return .{ .method = method, .path = path, .body = body_data };
}

fn sendResponse(stream: std.net.Stream, status: u16, content_type: []const u8, body: []const u8) void {
    const status_text: []const u8 = switch (status) {
        200 => "OK",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        else => "OK",
    };
    var header_buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {} {s}\r\nContent-Type: {s}\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
        .{ status, status_text, content_type, body.len },
    ) catch return;
    stream.writeAll(header) catch {};
    stream.writeAll(body) catch {};
}

fn sendJson(stream: std.net.Stream, body: []const u8) void {
    sendResponse(stream, 200, "application/json", body);
}

fn send404(stream: std.net.Stream) void {
    sendResponse(stream, 404, "text/plain", "Not Found");
}

fn send405(stream: std.net.Stream) void {
    sendResponse(stream, 405, "text/plain", "Method Not Allowed");
}

// ── JSON extraction from request body ────────────────────────────────────────

fn jsonStr(body: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, body, needle) orelse return null;
    const after = body[idx + needle.len ..];
    const trimmed = std.mem.trimLeft(u8, after, " \t");
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, trimmed, 1, '"') orelse return null;
        return trimmed[1..end];
    }
    // Non-string value — find end (comma, }, whitespace)
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != ',' and trimmed[end] != '}' and
        trimmed[end] != ' ' and trimmed[end] != '\r' and trimmed[end] != '\n') : (end += 1)
    {}
    return trimmed[0..end];
}

fn jsonBool(body: []const u8, key: []const u8) ?bool {
    const val = jsonStr(body, key) orelse return null;
    if (std.mem.eql(u8, val, "true")) return true;
    if (std.mem.eql(u8, val, "false")) return false;
    return null;
}

fn jsonInt(body: []const u8, key: []const u8) ?i64 {
    const val = jsonStr(body, key) orelse return null;
    return std.fmt.parseInt(i64, val, 10) catch null;
}

fn jsonFloat(body: []const u8, key: []const u8) ?f64 {
    const val = jsonStr(body, key) orelse return null;
    return std.fmt.parseFloat(f64, val) catch null;
}

// ════════════════════════════════════════════════════════════════════════════
//  TEMPLATE SERVING
// ════════════════════════════════════════════════════════════════════════════

fn serveTemplate(stream: std.net.Stream, filename: []const u8) void {
    const alloc = state.gpa;
    const file = std.fs.cwd().openFile(filename, .{}) catch {
        send404(stream);
        return;
    };
    defer file.close();
    const content = file.readToEndAlloc(alloc, 1 << 22) catch {
        sendResponse(stream, 500, "text/plain", "Read error");
        return;
    };
    defer alloc.free(content);

    // Template substitution for Jinja-like expressions
    var result = std.ArrayList(u8).init(alloc);
    defer result.deinit();

    var i: usize = 0;
    while (i < content.len) {
        if (i + 2 < content.len and content[i] == '{' and content[i + 1] == '{') {
            // Find closing }}
            if (std.mem.indexOfPos(u8, content, i + 2, "}}")) |close_idx| {
                const expr = std.mem.trim(u8, content[i + 2 .. close_idx], " ");
                substituteExpr(&result, expr);
                i = close_idx + 2;
                continue;
            }
        }
        result.append(content[i]) catch {};
        i += 1;
    }

    sendResponse(stream, 200, "text/html; charset=utf-8", result.items);
}

fn substituteExpr(result: *std.ArrayList(u8), expr: []const u8) void {
    // Handle: state|tojson, settings|tojson, settings | tojson, gpio_available|tojson, morse_code|tojson
    const trimmed = std.mem.trim(u8, expr, " ");
    if (std.mem.indexOf(u8, trimmed, "state") != null and std.mem.indexOf(u8, trimmed, "tojson") != null) {
        state.writeStateJson(result.writer()) catch {};
    } else if (std.mem.indexOf(u8, trimmed, "settings") != null and std.mem.indexOf(u8, trimmed, "tojson") != null) {
        result.appendSlice(state.settings_raw) catch {};
    } else if (std.mem.indexOf(u8, trimmed, "gpio_available") != null) {
        result.appendSlice(if (state.gpio_available) "true" else "false") catch {};
    } else if (std.mem.indexOf(u8, trimmed, "morse_code") != null and std.mem.indexOf(u8, trimmed, "tojson") != null) {
        morse.writeMorseTableJson(result.writer()) catch {};
    } else {
        // Unknown expression — output as-is
        result.appendSlice("{{") catch {};
        result.appendSlice(expr) catch {};
        result.appendSlice("}}") catch {};
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  ROUTE DISPATCH
// ════════════════════════════════════════════════════════════════════════════

fn handleConnection(conn: std.net.Server.Connection) void {
    defer conn.stream.close();

    const req = parseRequest(conn.stream) orelse return;

    // Dispatch based on method + path
    if (req.method == .GET) {
        routeGet(conn.stream, req.path);
    } else if (req.method == .POST) {
        routePost(conn.stream, req.path, req.body);
    } else {
        send405(conn.stream);
    }
}

fn routeGet(stream: std.net.Stream, path: []const u8) void {
    if (std.mem.eql(u8, path, "/")) return serveTemplate(stream, "templates/index.html");
    if (std.mem.eql(u8, path, "/diag")) return serveTemplate(stream, "templates/diag.html");
    if (std.mem.eql(u8, path, "/status")) return handleStatus(stream);
    if (std.mem.eql(u8, path, "/gpio_poll")) return handleGpioPoll(stream);
    if (std.mem.eql(u8, path, "/get_settings")) return sendJson(stream, state.settings_raw);
    if (std.mem.eql(u8, path, "/peers")) return handlePeers(stream);
    if (std.mem.eql(u8, path, "/net_status")) return handleNetStatus(stream);
    if (std.mem.eql(u8, path, "/kb_status")) return handleKbStatus(stream);
    send404(stream);
}

fn routePost(stream: std.net.Stream, path: []const u8, body: []const u8) void {
    if (std.mem.eql(u8, path, "/set_mode")) return handleSetMode(stream, body);
    if (std.mem.eql(u8, path, "/encode")) return handleEncode(stream, body);
    if (std.mem.eql(u8, path, "/play")) return handlePlay(stream);
    if (std.mem.eql(u8, path, "/play_phrase")) return handlePlayPhrase(stream);
    if (std.mem.eql(u8, path, "/wpm_test")) return handleWpmTest(stream);
    if (std.mem.eql(u8, path, "/save_settings")) return handleSaveSettings(stream, body);
    if (std.mem.eql(u8, path, "/preview_tone")) return handlePreviewTone(stream, body);
    if (std.mem.eql(u8, path, "/decode_submit")) return handleDecodeSubmit(stream, body);
    if (std.mem.eql(u8, path, "/submit_test")) return handleSubmitTest(stream, body);
    if (std.mem.eql(u8, path, "/clear")) return handleClear(stream);
    if (std.mem.eql(u8, path, "/toggle_cheat_sheet")) return handleToggleCheatSheet(stream);
    if (std.mem.eql(u8, path, "/receive_morse")) return handleReceiveMorse(stream, body);
    if (std.mem.eql(u8, path, "/send_to_peer")) return handleSendToPeer(stream, body);
    if (std.mem.eql(u8, path, "/clear_inbox")) return handleClearInbox(stream);
    if (std.mem.eql(u8, path, "/assign_gpio")) return handleAssignGpio(stream, body);
    if (std.mem.eql(u8, path, "/net_key_mode")) return handleNetKeyMode(stream, body);
    if (std.mem.eql(u8, path, "/net_key_press")) return handleNetKeyPress(stream, body);
    if (std.mem.eql(u8, path, "/net_clear_morse")) return handleNetClearMorse(stream);
    if (std.mem.eql(u8, path, "/net_send_morse")) return handleNetSendMorse(stream, body);
    if (std.mem.eql(u8, path, "/kb_enable")) return handleKbEnable(stream, body);
    if (std.mem.eql(u8, path, "/kb_hid_setup")) return handleKbHidSetup(stream);
    if (std.mem.eql(u8, path, "/kb_mode")) return handleKbMode(stream, body);
    if (std.mem.eql(u8, path, "/kb_set_keys")) return handleKbSetKeys(stream, body);
    if (std.mem.eql(u8, path, "/kb_clear")) return handleKbClear(stream);
    if (std.mem.eql(u8, path, "/kb_send_custom")) return handleKbSendCustom(stream, body);
    if (std.mem.eql(u8, path, "/key_press")) return handleKeyPress(stream, body);
    if (std.mem.eql(u8, path, "/key_press_dual")) return handleKeyPressDual(stream, body);
    if (std.mem.eql(u8, path, "/reset_stats")) return handleResetStats(stream);
    if (std.mem.eql(u8, path, "/clear_speed")) return handleClearSpeed(stream);
    if (std.mem.eql(u8, path, "/gpio_reinit")) return handleGpioReinit(stream);
    send404(stream);
}

// ════════════════════════════════════════════════════════════════════════════
//  GET HANDLERS
// ════════════════════════════════════════════════════════════════════════════

fn handleStatus(stream: std.net.Stream) void {
    var buf = std.ArrayList(u8).init(state.gpa);
    defer buf.deinit();
    const w = buf.writer();

    // Merge state + extra fields (matches Python /status)
    state.writeStateJson(w) catch {};
    // Need to inject extra fields before the closing }
    // Replace the last } with extra fields
    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '}') {
        buf.items.len -= 1; // remove closing }
    }
    std.fmt.format(w,
        \\,"gpio_available":{s},"pin_states":{{}},"keyer_state":"{s}","kb_enabled":{s},"kb_mode":"{s}","kb_dot_key":"{s}","kb_dash_key":"{s}","usb_hid_available":{s}}}
    , .{
        if (state.gpio_available) "true" else "false",
        sound.keyer_state_label,
        if (state.settings.kb_enabled) "true" else "false",
        state.settings.kb_mode,
        state.settings.kb_dot_key,
        state.settings.kb_dash_key,
        if (keyboard.usb_hid_available) "true" else "false",
    }) catch {};
    sendJson(stream, buf.items);
}

fn handleGpioPoll(stream: std.net.Stream) void {
    var buf = std.ArrayList(u8).init(state.gpa);
    defer buf.deinit();
    const w = buf.writer();
    const s = &state.settings;

    w.writeAll("{") catch {};
    std.fmt.format(w,
        \\"gpio_available":{s},
    , .{if (state.gpio_available) "true" else "false"}) catch {};
    // gpio_error — needs quoting when present
    if (state.gpio_error) |e| {
        std.fmt.format(w, "\"gpio_error\":\"{s}\",", .{e}) catch {};
    } else {
        w.writeAll("\"gpio_error\":null,") catch {};
    }
    std.fmt.format(w,
        \\"pin_mode":"{s}","output_type":"{s}",
    , .{ s.pin_mode, s.output_type }) catch {};
    std.fmt.format(w,
        \\"data_pin":{},"dot_pin":{},"dash_pin":{},"speaker_pin":{},
    , .{ s.data_pin, s.dot_pin, s.dash_pin, s.speaker_pin }) catch {};
    // speaker_pin2 — optional
    if (s.speaker_pin2) |sp2| {
        std.fmt.format(w, "\"speaker_pin2\":{},", .{sp2}) catch {};
    } else {
        w.writeAll("\"speaker_pin2\":null,") catch {};
    }
    std.fmt.format(w,
        \\"speaker_gnd_mode":"{s}",
    , .{s.speaker_gnd_mode}) catch {};
    // ground_pin — optional
    if (s.ground_pin) |gp| {
        std.fmt.format(w, "\"ground_pin\":{},", .{gp}) catch {};
    } else {
        w.writeAll("\"ground_pin\":null,") catch {};
    }

    // grounded_pins
    w.writeAll("\"grounded_pins\":[") catch {};
    for (s.grounded_pins, 0..) |gp, i| {
        if (i > 0) w.writeAll(",") catch {};
        std.fmt.format(w, "{}", .{gp}) catch {};
    }
    w.writeAll("],") catch {};

    // states
    w.writeAll("\"states\":") catch {};
    gpio.writePinStatesJson(w) catch {};
    w.writeAll(",") catch {};

    // power_pins
    w.writeAll("\"power_pins\":") catch {};
    gpio.writePowerPinsJson(w) catch {};
    w.writeAll(",") catch {};

    // errors
    w.writeAll("\"errors\":[],") catch {};

    // timestamp
    const ts = @as(f64, @floatFromInt(std.time.milliTimestamp())) / 1000.0;
    std.fmt.format(w, "\"timestamp\":{d:.3}", .{ts}) catch {};

    w.writeAll("}") catch {};
    sendJson(stream, buf.items);
}

fn handlePeers(stream: std.net.Stream) void {
    var buf = std.ArrayList(u8).init(state.gpa);
    defer buf.deinit();
    network.writePeersJson(buf.writer()) catch {};
    sendJson(stream, buf.items);
}

fn handleNetStatus(stream: std.net.Stream) void {
    var buf = std.ArrayList(u8).init(state.gpa);
    defer buf.deinit();
    const w = buf.writer();
    const ip = network.getLocalIp();
    const now = std.time.milliTimestamp();

    std.fmt.format(w,
        \\{{"self":{{"uuid":"{s}","name":"{s}","ip":"{s}","port":5000}},"peers":[
    , .{ &network.device_uuid, state.settings.device_name, ip }) catch {};

    network.peers_mu.lock();
    defer network.peers_mu.unlock();
    var first = true;
    for (network.peers) |maybe_peer| {
        if (maybe_peer) |peer| {
            if (!first) w.writeAll(",") catch {};
            first = false;
            const ago = @as(f64, @floatFromInt(now - peer.last_seen)) / 1000.0;
            std.fmt.format(w,
                \\{{"uuid":"{s}","name":"{s}","ip":"{s}","port":{},"last_seen_ago":{d:.1}}}
            , .{ &peer.uuid, peer.name[0..peer.name_len], peer.ip[0..peer.ip_len], peer.port, ago }) catch {};
        }
    }

    w.writeAll("],\"inbox\":[") catch {};
    // Write inbox in reverse order
    if (state.net_inbox_len > 0) {
        var i: usize = state.net_inbox_len;
        var first2 = true;
        while (i > 0) {
            i -= 1;
            if (state.net_inbox[i]) |msg| {
                if (!first2) w.writeAll(",") catch {};
                first2 = false;
                std.fmt.format(w,
                    \\{{"sender":"{s}","text":"{s}","morse":"{s}","ts":{d}}}
                , .{ msg.sender, msg.text, msg.morse, msg.ts }) catch {};
            }
        }
    }
    w.writeAll("]}") catch {};
    sendJson(stream, buf.items);
}

fn handleKbStatus(stream: std.net.Stream) void {
    _ = keyboard.checkUsbHid();
    var buf: [512]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"kb_enabled":{s},"kb_mode":"{s}","kb_dot_key":"{s}","kb_dash_key":"{s}","kb_output":"{s}","usb_hid_available":{s}}}
    , .{
        if (state.settings.kb_enabled) "true" else "false",
        state.settings.kb_mode,
        state.settings.kb_dot_key,
        state.settings.kb_dash_key,
        state.kb_output,
        if (keyboard.usb_hid_available) "true" else "false",
    }) catch return;
    sendJson(stream, json);
}

// ════════════════════════════════════════════════════════════════════════════
//  POST HANDLERS
// ════════════════════════════════════════════════════════════════════════════

fn handleSetMode(stream: std.net.Stream, body: []const u8) void {
    const mode_str = jsonStr(body, "mode") orelse {
        sendStateJson(stream);
        return;
    };
    const valid_modes = [_][]const u8{ "send", "encode", "decode", "speed", "settings", "stats", "network" };
    var valid = false;
    for (valid_modes) |m| {
        if (std.mem.eql(u8, mode_str, m)) {
            valid = true;
            break;
        }
    }
    if (!valid) {
        sendStateJson(stream);
        return;
    }
    state.setStr(&state.mode, mode_str);

    if (std.mem.eql(u8, mode_str, "decode")) {
        const phrase = morse.randomPhrase(state.settings.difficulty);
        state.setStr(&state.current_phrase, phrase);
        state.setStr(&state.decode_result, "");
    } else if (std.mem.eql(u8, mode_str, "speed")) {
        const phrase = morse.randomPhrase(state.settings.difficulty);
        state.setStr(&state.speed_phrase, phrase);
        state.setStr(&state.speed_result, "");
        state.setStr(&state.speed_morse_buffer, "");
        state.setStr(&state.speed_morse_output, "");
        sound.recreateGpio();
    } else if (std.mem.eql(u8, mode_str, "send")) {
        sound.recreateGpio();
    }
    sendStateJson(stream);
}

fn handleEncode(stream: std.net.Stream, body: []const u8) void {
    const text = jsonStr(body, "text") orelse "";
    state.setStr(&state.encode_input, text);
    const encoded = morse.encode(text);
    defer state.gpa.free(encoded);
    state.setStr(&state.encode_output, encoded);

    var buf: [8192]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"morse":"{s}"}}
    , .{state.encode_output}) catch return;
    sendJson(stream, json);
}

fn handlePlay(stream: std.net.Stream) void {
    const text = state.gpa.dupe(u8, state.encode_input) catch "";
    const thread = std.Thread.spawn(.{}, struct {
        fn f(t: []const u8) void {
            sound.playMorseString(t);
            state.gpa.free(t);
        }
    }.f, .{text}) catch null;
    if (thread) |t| t.detach();
    sendJson(stream, "{\"status\":\"playing\"}");
}

fn handlePlayPhrase(stream: std.net.Stream) void {
    const text = state.gpa.dupe(u8, state.current_phrase) catch "";
    const thread = std.Thread.spawn(.{}, struct {
        fn f(t: []const u8) void {
            sound.playMorseString(t);
            state.gpa.free(t);
        }
    }.f, .{text}) catch null;
    if (thread) |t| t.detach();
    sendJson(stream, "{\"status\":\"playing\"}");
}

fn handleWpmTest(stream: std.net.Stream) void {
    const thread = std.Thread.spawn(.{}, struct {
        fn f() void {
            sound.playMorseString("PARIS");
        }
    }.f, .{}) catch null;
    if (thread) |t| t.detach();
    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"status":"playing","wpm":{}}}
    , .{state.settings.wpm_target}) catch return;
    sendJson(stream, json);
}

fn handleSaveSettings(stream: std.net.Stream, body: []const u8) void {
    // Apply fields from JSON body to settings
    if (jsonInt(body, "speaker_pin")) |v| state.settings.speaker_pin = @intCast(v);
    if (jsonStr(body, "speaker_pin2")) |v| {
        if (std.mem.eql(u8, v, "null")) {
            state.settings.speaker_pin2 = null;
        } else {
            state.settings.speaker_pin2 = @as(?i32, @intCast(std.fmt.parseInt(i64, v, 10) catch 0));
        }
    }
    inline for (.{
        .{ "speaker_gnd_mode", "speaker_gnd_mode" },
        .{ "output_type", "output_type" },
        .{ "pin_mode", "pin_mode" },
        .{ "theme", "theme" },
        .{ "difficulty", "difficulty" },
        .{ "device_name", "device_name" },
        .{ "kb_mode", "kb_mode" },
        .{ "kb_dot_key", "kb_dot_key" },
        .{ "kb_dash_key", "kb_dash_key" },
        .{ "practice_chars", "practice_chars" },
    }) |pair| {
        if (jsonStr(body, pair[0])) |v| {
            @field(state.settings, pair[1]) = state.gpa.dupe(u8, v) catch @field(state.settings, pair[1]);
        }
    }
    inline for (.{
        .{ "data_pin", "data_pin" },
        .{ "dot_pin", "dot_pin" },
        .{ "dash_pin", "dash_pin" },
        .{ "dot_freq", "dot_freq" },
        .{ "dash_freq", "dash_freq" },
        .{ "wpm_target", "wpm_target" },
    }) |pair| {
        if (jsonInt(body, pair[0])) |v| @field(state.settings, pair[1]) = @intCast(v);
    }
    if (jsonStr(body, "ground_pin")) |v| {
        if (std.mem.eql(u8, v, "null")) {
            state.settings.ground_pin = null;
        } else {
            state.settings.ground_pin = @as(?i32, @intCast(std.fmt.parseInt(i64, v, 10) catch 0));
        }
    }
    if (jsonFloat(body, "volume")) |v| state.settings.volume = v;
    if (jsonFloat(body, "farnsworth_letter_mult")) |v| state.settings.farnsworth_letter_mult = v;
    if (jsonFloat(body, "farnsworth_word_mult")) |v| state.settings.farnsworth_word_mult = v;
    if (jsonBool(body, "use_external_switch")) |v| state.settings.use_external_switch = v;
    if (jsonBool(body, "farnsworth_enabled")) |v| state.settings.farnsworth_enabled = v;
    if (jsonBool(body, "kb_enabled")) |v| state.settings.kb_enabled = v;

    state.saveSettings();
    sound.recreateGpio();
    sendJson(stream, state.settings_raw);
}

fn handlePreviewTone(stream: std.net.Stream, body: []const u8) void {
    const freq: u32 = @intCast(jsonInt(body, "freq") orelse state.settings.dot_freq);
    const dur_secs = jsonFloat(body, "duration") orelse sound.getDotUnitSecs();
    const dur_ns: u64 = @intFromFloat(dur_secs * 1_000_000_000.0);
    const thread = std.Thread.spawn(.{}, struct {
        fn f(fr: u32, d: u64) void {
            sound.playTone(fr, d);
            sound.stopTone();
        }
    }.f, .{ freq, dur_ns }) catch null;
    if (thread) |t| t.detach();
    sendJson(stream, "{\"status\":\"previewed\"}");
}

fn handleDecodeSubmit(stream: std.net.Stream, body: []const u8) void {
    const answer = jsonStr(body, "answer") orelse "";
    const correct_phrase = state.current_phrase;

    // Compare uppercase
    var ans_upper = state.gpa.alloc(u8, answer.len) catch return;
    defer state.gpa.free(ans_upper);
    for (answer, 0..) |c, i| ans_upper[i] = std.ascii.toUpper(c);
    // Trim
    const ans_trimmed = std.mem.trim(u8, ans_upper, " ");
    const phrase_trimmed = std.mem.trim(u8, correct_phrase, " ");

    var phrase_upper = state.gpa.alloc(u8, phrase_trimmed.len) catch return;
    defer state.gpa.free(phrase_upper);
    for (phrase_trimmed, 0..) |c, i| phrase_upper[i] = std.ascii.toUpper(c);

    const correct = std.mem.eql(u8, ans_trimmed, phrase_upper);
    state.stats.total_attempts += 1;
    if (correct) {
        state.stats.correct += 1;
        state.stats.streak += 1;
        if (state.stats.streak > state.stats.best_streak) state.stats.best_streak = state.stats.streak;
    } else {
        state.stats.streak = 0;
    }
    state.setStr(&state.decode_result, if (correct) "correct" else "wrong");
    state.setStr(&state.decode_correct_answer, phrase_upper);
    state.saveStats();

    var buf = std.ArrayList(u8).init(state.gpa);
    defer buf.deinit();
    const w = buf.writer();
    std.fmt.format(w,
        \\{{"result":"{s}","correct_answer":"{s}","stats":
    , .{ if (correct) "correct" else "wrong", phrase_upper }) catch {};
    state.writeStatsJson(w) catch {};
    w.writeAll("}") catch {};
    sendJson(stream, buf.items);
}

fn handleSubmitTest(stream: std.net.Stream, body: []const u8) void {
    const input_morse = std.mem.trim(u8, state.speed_morse_output, " ");
    const elapsed = jsonFloat(body, "elapsed") orelse 1.0;

    if (input_morse.len == 0) {
        state.setStr(&state.speed_result, "no_input");
        sendJson(stream, "{\"result\":\"no_input\"}");
        return;
    }

    const decoded = morse.decode(input_morse);
    defer state.gpa.free(decoded);

    var decoded_upper = state.gpa.alloc(u8, decoded.len) catch return;
    defer state.gpa.free(decoded_upper);
    for (decoded, 0..) |c, i| decoded_upper[i] = std.ascii.toUpper(c);

    const expected = state.speed_phrase;
    var expected_upper = state.gpa.alloc(u8, expected.len) catch return;
    defer state.gpa.free(expected_upper);
    for (expected, 0..) |c, i| expected_upper[i] = std.ascii.toUpper(c);

    const max_len = @max(expected_upper.len, decoded_upper.len);
    var correct_count: usize = 0;
    for (0..max_len) |i| {
        const exp_c: u8 = if (i < expected_upper.len) expected_upper[i] else 0;
        const got_c: u8 = if (i < decoded_upper.len) decoded_upper[i] else 0;
        if (exp_c == got_c and exp_c != 0) correct_count += 1;
    }
    const accuracy: u32 = if (expected_upper.len > 0)
        @intCast((correct_count * 100) / expected_upper.len)
    else
        0;
    const perfect = std.mem.eql(u8, decoded_upper, expected_upper);

    // Count chars typed
    var chars_typed: usize = 0;
    for (input_morse) |c| {
        if (c != ' ' and c != '/') chars_typed += 1;
    }
    const wpm: f64 = if (elapsed > 0)
        @as(f64, @floatFromInt(chars_typed)) / 5.0 / (elapsed / 60.0)
    else
        0;

    state.stats.total_attempts += 1;
    if (perfect) {
        state.stats.correct += 1;
        state.stats.streak += 1;
        if (state.stats.streak > state.stats.best_streak) state.stats.best_streak = state.stats.streak;
    } else {
        state.stats.streak = 0;
    }
    state.saveStats();

    var buf = std.ArrayList(u8).init(state.gpa);
    defer buf.deinit();
    const w = buf.writer();
    std.fmt.format(w,
        \\{{"result":"{s}","decoded":"{s}","expected":"{s}","accuracy":{},"wpm":{d:.1},
    , .{
        if (perfect) "correct" else "wrong",
        decoded_upper,
        expected_upper,
        accuracy,
        wpm,
    }) catch {};

    // char_results array
    w.writeAll("\"char_results\":[") catch {};
    for (0..max_len) |i| {
        if (i > 0) w.writeAll(",") catch {};
        const exp_c: u8 = if (i < expected_upper.len) expected_upper[i] else 0;
        const got_c: u8 = if (i < decoded_upper.len) decoded_upper[i] else 0;
        const is_match = (exp_c == got_c and exp_c != 0);
        std.fmt.format(w,
            \\{{"expected":"{c}","got":"{c}","correct":{s}}}
        , .{
            if (exp_c != 0) exp_c else ' ',
            if (got_c != 0) got_c else ' ',
            if (is_match) "true" else "false",
        }) catch {};
    }
    w.writeAll("],\"stats\":") catch {};
    state.writeStatsJson(w) catch {};
    w.writeAll("}") catch {};

    state.setStr(&state.speed_morse_output, "");
    state.setStr(&state.speed_morse_buffer, "");
    sendJson(stream, buf.items);
}

fn handleClear(stream: std.net.Stream) void {
    state.setStr(&state.send_output, "");
    state.setStr(&state.encode_output, "");
    state.setStr(&state.encode_input, "");
    state.setStr(&state.current_morse_buffer, "");
    sound.send_buffer.clearRetainingCapacity();
    state.setStr(&state.speed_morse_buffer, "");
    state.setStr(&state.speed_morse_output, "");
    sendStateJson(stream);
}

fn handleToggleCheatSheet(stream: std.net.Stream) void {
    state.cheat_sheet = !state.cheat_sheet;
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"cheat_sheet":{s}}}
    , .{if (state.cheat_sheet) "true" else "false"}) catch return;
    sendJson(stream, json);
}

fn handleReceiveMorse(stream: std.net.Stream, body: []const u8) void {
    const sender_name = jsonStr(body, "sender_name") orelse "Unknown";
    const text = jsonStr(body, "text") orelse "";
    const morse_str_raw = jsonStr(body, "morse") orelse "";

    var text_upper_buf: [512]u8 = undefined;
    var text_upper_len: usize = 0;
    for (text) |c| {
        if (text_upper_len < text_upper_buf.len) {
            text_upper_buf[text_upper_len] = std.ascii.toUpper(c);
            text_upper_len += 1;
        }
    }
    const text_upper = text_upper_buf[0..text_upper_len];

    var m = morse_str_raw;
    if (text_upper.len > 0 and m.len == 0) {
        const encoded = morse.encode(text_upper);
        m = encoded;
    }

    if (text_upper.len == 0 and m.len == 0) {
        sendJson(stream, "{\"ok\":false,\"error\":\"no content\"}");
        return;
    }

    state.addInboxMessage(sender_name, text_upper, m);

    if (text_upper.len > 0) {
        const text_copy = state.gpa.dupe(u8, text_upper) catch "";
        const thread = std.Thread.spawn(.{}, struct {
            fn f(t: []const u8) void {
                sound.playMorseString(t);
                state.gpa.free(t);
            }
        }.f, .{text_copy}) catch null;
        if (thread) |t| t.detach();
    }

    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"ok":true,"received":"{s}"}}
    , .{text_upper}) catch return;
    sendJson(stream, json);
}

fn handleSendToPeer(stream: std.net.Stream, body: []const u8) void {
    const ip = jsonStr(body, "ip") orelse "";
    const port_val = jsonInt(body, "port") orelse 5000;
    const text = jsonStr(body, "text") orelse "";

    if (ip.len == 0 or text.len == 0) {
        sendJson(stream, "{\"ok\":false,\"error\":\"missing ip or text\"}");
        return;
    }

    var text_upper_buf: [512]u8 = undefined;
    var len: usize = 0;
    for (text) |c| {
        if (len < text_upper_buf.len) {
            text_upper_buf[len] = std.ascii.toUpper(c);
            len += 1;
        }
    }
    const text_upper = text_upper_buf[0..len];
    const encoded = morse.encode(text_upper);
    defer state.gpa.free(encoded);

    // Send HTTP POST to peer
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}:{}/receive_morse", .{ ip, port_val }) catch {
        sendJson(stream, "{\"ok\":false,\"error\":\"url format error\"}");
        return;
    };

    // Simple TCP request to peer
    const addr = std.net.Address.parseIp4(ip, @intCast(port_val)) catch {
        sendJson(stream, "{\"ok\":false,\"error\":\"invalid address\"}");
        return;
    };
    _ = url;

    const last_err: []const u8 = "connection failed";
    for (0..3) |attempt| {
        const peer_stream = std.net.tcpConnectToAddress(addr) catch {
            if (attempt < 2) std.time.sleep((attempt + 1) * 300 * std.time.ns_per_ms);
            continue;
        };
        defer peer_stream.close();

        var payload_buf: [2048]u8 = undefined;
        const payload = std.fmt.bufPrint(&payload_buf,
            \\{{"sender_name":"{s}","text":"{s}","morse":"{s}"}}
        , .{ state.settings.device_name, text_upper, encoded }) catch continue;

        var req_buf: [4096]u8 = undefined;
        const http_req = std.fmt.bufPrint(
            &req_buf,
            "POST /receive_morse HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{s}",
            .{ ip, payload.len, payload },
        ) catch continue;

        peer_stream.writeAll(http_req) catch continue;
        sendJson(stream, "{\"ok\":true,\"result\":{\"ok\":true}}");
        return;
    }

    var err_buf: [256]u8 = undefined;
    const err_json = std.fmt.bufPrint(&err_buf,
        \\{{"ok":false,"error":"{s}"}}
    , .{last_err}) catch return;
    sendJson(stream, err_json);
}

fn handleClearInbox(stream: std.net.Stream) void {
    state.clearInbox();
    sendJson(stream, "{\"ok\":true}");
}

fn handleAssignGpio(stream: std.net.Stream, body: []const u8) void {
    const bcm = jsonInt(body, "bcm") orelse {
        sendJson(stream, "{\"ok\":false,\"error\":\"missing bcm\"}");
        return;
    };
    const role = jsonStr(body, "role") orelse {
        sendJson(stream, "{\"ok\":false,\"error\":\"missing role\"}");
        return;
    };

    // Normalize role names
    var actual_role: []const u8 = role;
    if (std.mem.eql(u8, role, "dot")) actual_role = "dot_pin";
    if (std.mem.eql(u8, role, "dash")) actual_role = "dash_pin";
    if (std.mem.eql(u8, role, "straight") or std.mem.eql(u8, role, "data")) actual_role = "data_pin";
    if (std.mem.eql(u8, role, "speaker") or std.mem.eql(u8, role, "led")) actual_role = "speaker_pin";
    if (std.mem.eql(u8, role, "speaker2")) actual_role = "speaker_pin2";

    const bcm_i32: i32 = @intCast(bcm);

    if (std.mem.eql(u8, actual_role, "ground")) {
        // Can't ground a key or speaker pin
        if (bcm_i32 == state.settings.speaker_pin) {
            sendJson(stream, "{\"ok\":false,\"error\":\"Cannot ground the speaker pin\"}");
            return;
        }
        var grounded = std.ArrayList(i32).init(state.gpa);
        for (state.settings.grounded_pins) |gp| grounded.append(gp) catch {};
        if (std.mem.indexOfScalar(i32, grounded.items, bcm_i32) == null) {
            grounded.append(bcm_i32) catch {};
        }
        state.settings.grounded_pins = grounded.toOwnedSlice() catch state.settings.grounded_pins;
    } else if (std.mem.eql(u8, actual_role, "clear")) {
        if (state.settings.speaker_pin == bcm_i32) state.settings.speaker_pin = 18;
        if (state.settings.speaker_pin2) |sp2| if (sp2 == bcm_i32) {
            state.settings.speaker_pin2 = null;
        };
        if (state.settings.data_pin == bcm_i32) state.settings.data_pin = 17;
        if (state.settings.dot_pin == bcm_i32) state.settings.dot_pin = 22;
        if (state.settings.dash_pin == bcm_i32) state.settings.dash_pin = 27;
        if (state.settings.ground_pin) |gp| if (gp == bcm_i32) {
            state.settings.ground_pin = null;
        };
        // Remove from grounded_pins
        var new_grounded = std.ArrayList(i32).init(state.gpa);
        for (state.settings.grounded_pins) |gp| {
            if (gp != bcm_i32) new_grounded.append(gp) catch {};
        }
        state.settings.grounded_pins = new_grounded.toOwnedSlice() catch state.settings.grounded_pins;
    } else if (std.mem.eql(u8, actual_role, "speaker_pin")) {
        state.settings.speaker_pin = bcm_i32;
    } else if (std.mem.eql(u8, actual_role, "speaker_pin2")) {
        if (bcm_i32 == state.settings.speaker_pin) {
            sendJson(stream, "{\"ok\":false,\"error\":\"Pin 2 cannot be the same as Pin 1\"}");
            return;
        }
        state.settings.speaker_pin2 = bcm_i32;
    } else if (std.mem.eql(u8, actual_role, "data_pin")) {
        state.settings.data_pin = bcm_i32;
    } else if (std.mem.eql(u8, actual_role, "dot_pin")) {
        if (bcm_i32 == state.settings.dash_pin) {
            sendJson(stream, "{\"ok\":false,\"error\":\"Dot and dash pins cannot be the same\"}");
            return;
        }
        state.settings.dot_pin = bcm_i32;
    } else if (std.mem.eql(u8, actual_role, "dash_pin")) {
        if (bcm_i32 == state.settings.dot_pin) {
            sendJson(stream, "{\"ok\":false,\"error\":\"Dot and dash pins cannot be the same\"}");
            return;
        }
        state.settings.dash_pin = bcm_i32;
    } else {
        var err_buf: [128]u8 = undefined;
        const err = std.fmt.bufPrint(&err_buf,
            \\{{"ok":false,"error":"Unknown role: {s}"}}
        , .{actual_role}) catch return;
        sendJson(stream, err);
        return;
    }

    state.saveSettings();
    sound.recreateGpio();

    var buf = std.ArrayList(u8).init(state.gpa);
    defer buf.deinit();
    buf.appendSlice("{\"ok\":true,\"settings\":") catch {};
    buf.appendSlice(state.settings_raw) catch {};
    buf.appendSlice("}") catch {};
    sendJson(stream, buf.items);
}

fn handleNetKeyMode(stream: std.net.Stream, body: []const u8) void {
    const enabled = jsonBool(body, "enabled") orelse false;
    state.net_key_mode_enabled = enabled;
    if (!enabled) {
        state.setStr(&state.net_morse_buffer_str, "");
        state.setStr(&state.net_morse_output_str, "");
        sound.net_morse_buffer.clearRetainingCapacity();
    }
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"ok":true,"net_key_mode":{s}}}
    , .{if (state.net_key_mode_enabled) "true" else "false"}) catch return;
    sendJson(stream, json);
}

fn handleNetKeyPress(stream: std.net.Stream, body: []const u8) void {
    const pressed = jsonBool(body, "pressed") orelse false;
    if (pressed) sound.netKeyPressed() else sound.netKeyReleased();
    sendJson(stream, "{\"ok\":true}");
}

fn handleNetClearMorse(stream: std.net.Stream) void {
    state.setStr(&state.net_morse_buffer_str, "");
    state.setStr(&state.net_morse_output_str, "");
    sound.net_morse_buffer.clearRetainingCapacity();
    sendJson(stream, "{\"ok\":true}");
}

fn handleNetSendMorse(stream: std.net.Stream, body: []const u8) void {
    const ip = jsonStr(body, "ip") orelse "";
    const port_val = jsonInt(body, "port") orelse 5000;
    const text = state.net_morse_output_str;

    if (ip.len == 0 or text.len == 0) {
        sendJson(stream, "{\"ok\":false,\"error\":\"missing ip or no message composed\"}");
        return;
    }

    // Similar to handleSendToPeer — send the composed morse message
    var text_upper_buf: [512]u8 = undefined;
    var len: usize = 0;
    for (text) |c| {
        if (len < text_upper_buf.len) {
            text_upper_buf[len] = std.ascii.toUpper(c);
            len += 1;
        }
    }
    const text_upper = text_upper_buf[0..len];
    const encoded = morse.encode(text_upper);
    defer state.gpa.free(encoded);

    const addr = std.net.Address.parseIp4(ip, @intCast(port_val)) catch {
        sendJson(stream, "{\"ok\":false,\"error\":\"invalid address\"}");
        return;
    };

    for (0..3) |attempt| {
        const peer_stream = std.net.tcpConnectToAddress(addr) catch {
            if (attempt < 2) std.time.sleep((attempt + 1) * 300 * std.time.ns_per_ms);
            continue;
        };
        defer peer_stream.close();

        var payload_buf: [2048]u8 = undefined;
        const payload = std.fmt.bufPrint(&payload_buf,
            \\{{"sender_name":"{s}","text":"{s}","morse":"{s}"}}
        , .{ state.settings.device_name, text_upper, encoded }) catch continue;

        var req_buf: [4096]u8 = undefined;
        const http_req = std.fmt.bufPrint(
            &req_buf,
            "POST /receive_morse HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{s}",
            .{ ip, payload.len, payload },
        ) catch continue;

        peer_stream.writeAll(http_req) catch continue;
        // Clear the composed message
        state.setStr(&state.net_morse_buffer_str, "");
        state.setStr(&state.net_morse_output_str, "");
        sound.net_morse_buffer.clearRetainingCapacity();

        var resp_buf: [256]u8 = undefined;
        const resp = std.fmt.bufPrint(&resp_buf,
            \\{{"ok":true,"result":{{"ok":true}},"sent_text":"{s}"}}
        , .{text_upper}) catch "{\"ok\":true}";
        sendJson(stream, resp);
        return;
    }
    sendJson(stream, "{\"ok\":false,\"error\":\"connection failed\"}");
}

fn handleKbEnable(stream: std.net.Stream, body: []const u8) void {
    const enabled = jsonBool(body, "enabled") orelse false;
    _ = keyboard.checkUsbHid();
    state.settings.kb_enabled = enabled;
    state.saveSettings();
    var warning: []const u8 = "null";
    if (enabled and !keyboard.usb_hid_available) {
        warning = "\"Keyboard enabled but /dev/hidg0 not found. Try rebooting the Pi.\"";
    }
    var buf: [512]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"ok":true,"kb_enabled":{s},"usb_hid_available":{s},"warning":{s}}}
    , .{
        if (state.settings.kb_enabled) "true" else "false",
        if (keyboard.usb_hid_available) "true" else "false",
        warning,
    }) catch return;
    sendJson(stream, json);
}

fn handleKbHidSetup(stream: std.net.Stream) void {
    if (keyboard.checkUsbHid()) {
        sendJson(stream, "{\"ok\":true,\"usb_hid_available\":true,\"message\":\"HID device already available.\"}");
        return;
    }
    // Try starting the HID service
    _ = std.process.Child.run(.{
        .allocator = state.gpa,
        .argv = &.{ "sudo", "systemctl", "start", "morse-pi-hid" },
    }) catch {};
    _ = keyboard.checkUsbHid();
    if (keyboard.usb_hid_available) {
        sendJson(stream, "{\"ok\":true,\"usb_hid_available\":true,\"message\":\"HID gadget activated via service.\"}");
        return;
    }
    sendJson(stream, "{\"ok\":false,\"usb_hid_available\":false,\"error\":\"Could not activate HID gadget. Try rebooting.\"}");
}

fn handleKbMode(stream: std.net.Stream, body: []const u8) void {
    const m = jsonStr(body, "mode") orelse "letters";
    if (std.mem.eql(u8, m, "letters") or std.mem.eql(u8, m, "custom")) {
        state.settings.kb_mode = state.gpa.dupe(u8, m) catch state.settings.kb_mode;
        state.saveSettings();
    }
    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"ok":true,"kb_mode":"{s}"}}
    , .{state.settings.kb_mode}) catch return;
    sendJson(stream, json);
}

fn handleKbSetKeys(stream: std.net.Stream, body: []const u8) void {
    if (jsonStr(body, "dot_key")) |v| {
        state.settings.kb_dot_key = state.gpa.dupe(u8, v) catch state.settings.kb_dot_key;
    }
    if (jsonStr(body, "dash_key")) |v| {
        state.settings.kb_dash_key = state.gpa.dupe(u8, v) catch state.settings.kb_dash_key;
    }
    state.saveSettings();
    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"ok":true,"kb_dot_key":"{s}","kb_dash_key":"{s}"}}
    , .{ state.settings.kb_dot_key, state.settings.kb_dash_key }) catch return;
    sendJson(stream, json);
}

fn handleKbClear(stream: std.net.Stream) void {
    state.setStr(&state.kb_output, "");
    sendJson(stream, "{\"ok\":true,\"kb_output\":\"\"}");
}

fn handleKbSendCustom(stream: std.net.Stream, body: []const u8) void {
    if (!state.settings.kb_enabled) {
        sendJson(stream, "{\"ok\":false,\"error\":\"Keyboard not enabled\"}");
        return;
    }
    if (!std.mem.eql(u8, state.settings.kb_mode, "custom")) {
        sendJson(stream, "{\"ok\":false,\"error\":\"Not in custom mode\"}");
        return;
    }
    const key_type = jsonStr(body, "type") orelse "";
    const key_char = if (std.mem.eql(u8, key_type, "dot"))
        state.settings.kb_dot_key
    else if (std.mem.eql(u8, key_type, "dash"))
        state.settings.kb_dash_key
    else {
        sendJson(stream, "{\"ok\":false,\"error\":\"Invalid key type\"}");
        return;
    };
    const success = keyboard.sendCustomKey(key_char);
    if (success) {
        const dc: u8 = if (std.mem.eql(u8, key_char, "space")) ' ' else if (key_char.len > 0) key_char[0] else '?';
        state.appendStr(&state.kb_output, &.{dc});
    }
    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"ok":{s},"key_sent":"{s}","kb_output":"{s}"}}
    , .{ if (success) "true" else "false", key_char, state.kb_output }) catch return;
    sendJson(stream, json);
}

fn handleKeyPress(stream: std.net.Stream, body: []const u8) void {
    const pressed = jsonBool(body, "pressed") orelse false;
    if (std.mem.eql(u8, state.mode, "speed")) {
        if (pressed) sound.speedButtonPressed() else sound.speedButtonReleased();
    } else {
        if (pressed) sound.sendButtonPressed() else sound.sendButtonReleased();
    }
    sendJson(stream, "{\"ok\":true}");
}

fn handleKeyPressDual(stream: std.net.Stream, body: []const u8) void {
    const sym = jsonStr(body, "sym") orelse "";
    const pressed = jsonBool(body, "pressed") orelse false;
    if (std.mem.eql(u8, sym, "dot")) {
        sound.virtual_dot = pressed;
    } else if (std.mem.eql(u8, sym, "dash")) {
        sound.virtual_dash = pressed;
    }
    sendJson(stream, "{\"ok\":true}");
}

fn handleResetStats(stream: std.net.Stream) void {
    state.stats = .{};
    state.saveStats();
    var buf = std.ArrayList(u8).init(state.gpa);
    defer buf.deinit();
    state.writeStatsJson(buf.writer()) catch {};
    sendJson(stream, buf.items);
}

fn handleClearSpeed(stream: std.net.Stream) void {
    state.setStr(&state.speed_morse_buffer, "");
    state.setStr(&state.speed_morse_output, "");
    sound.speed_buffer.clearRetainingCapacity();
    sound.speed_active = false;
    sendStateJson(stream);
}

fn handleGpioReinit(stream: std.net.Stream) void {
    state.gpio_error_log.clearRetainingCapacity();
    if (state.gpio_error != null) {
        state.gpio_error_log.append("Import error: GPIO not available") catch {};
    } else {
        sound.recreateGpio();
    }
    sendJson(stream, "{\"ok\":true,\"errors\":[]}");
}

// ── Helper ───────────────────────────────────────────────────────────────────

fn sendStateJson(stream: std.net.Stream) void {
    var buf = std.ArrayList(u8).init(state.gpa);
    defer buf.deinit();
    state.writeStateJson(buf.writer()) catch {};
    sendJson(stream, buf.items);
}

// ════════════════════════════════════════════════════════════════════════════
//  MAIN
// ════════════════════════════════════════════════════════════════════════════

pub fn main() !void {
    // ── Initialise modules ──
    state.init();
    morse.loadWords();
    _ = keyboard.checkUsbHid();
    gpio.init();
    sound.recreateGpio();
    gpio.startPollThread();
    network.startBeacons();

    // ── Print startup banner ──
    const stdout = std.io.getStdOut().writer();
    try stdout.print("=== Morse-Pi (Zig) Starting ===\n", .{});
    try stdout.print(" GPIO available:   {}\n", .{state.gpio_available});
    try stdout.print(" Pin mode:         {s}\n", .{state.settings.pin_mode});
    try stdout.print(" USB HID:          {s}\n", .{if (keyboard.usb_hid_available) "AVAILABLE" else "NOT AVAILABLE"});
    try stdout.print(" Listening on:     http://0.0.0.0:5000\n", .{});
    try stdout.print("================================\n", .{});

    // ── Start HTTP server ──
    const address = try std.net.Address.parseIp("0.0.0.0", 5000);
    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    while (true) {
        const conn = server.accept() catch |err| {
            std.debug.print("accept error: {}\n", .{err});
            continue;
        };
        const thread = std.Thread.spawn(.{}, handleConnection, .{conn}) catch {
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}
