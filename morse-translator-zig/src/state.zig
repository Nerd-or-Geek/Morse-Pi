// ============================================================================
//  Morse-Pi — Shared state, settings, statistics.
//
//  Central state module. Imported by every other module.
//  Uses a global allocator + mutex for thread-safe mutable state.
// ============================================================================
const std = @import("std");

// ── Allocator ────────────────────────────────────────────────────────────────
var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
pub const gpa = gpa_instance.allocator();

// ── Mutex (protects settings, state, stats) ──────────────────────────────────
pub var mu: std.Thread.Mutex = .{};

// ════════════════════════════════════════════════════════════════════════════
//  SETTINGS
// ════════════════════════════════════════════════════════════════════════════

pub const Settings = struct {
    speaker_pin: i32 = 18,
    speaker_pin2: ?i32 = null,
    speaker_gnd_mode: []const u8 = "3v3",
    output_type: []const u8 = "speaker",
    pin_mode: []const u8 = "single",
    data_pin: i32 = 17,
    dot_pin: i32 = 22,
    dash_pin: i32 = 27,
    ground_pin: ?i32 = null,
    grounded_pins: []const i32 = &.{},
    use_external_switch: bool = false,
    dot_freq: i32 = 700,
    dash_freq: i32 = 500,
    volume: f64 = 0.75,
    wpm_target: i32 = 20,
    theme: []const u8 = "dark",
    difficulty: []const u8 = "easy",
    quiz_categories: []const []const u8 = &.{"words"},
    practice_chars: []const u8 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    farnsworth_enabled: bool = false,
    farnsworth_letter_mult: f64 = 2.0,
    farnsworth_word_mult: f64 = 2.0,
    device_name: []const u8 = "Morse Pi",
    kb_enabled: bool = false,
    kb_mode: []const u8 = "letters",
    kb_dot_key: []const u8 = "z",
    kb_dash_key: []const u8 = "x",
};

pub var settings: Settings = .{};
pub var settings_json: ?std.json.Parsed(std.json.Value) = null;

/// Raw JSON bytes of current settings (for serving API & templates).
pub var settings_raw: []u8 = &.{};

pub fn loadSettings() void {
    const data = std.fs.cwd().readFileAlloc(gpa, "settings.json", 1 << 20) catch {
        reserializeSettings();
        return;
    };
    defer gpa.free(data);

    // Parse into Value tree (keeps original JSON shape for unknown keys)
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{
        .ignore_unknown_fields = true,
    }) catch {
        reserializeSettings();
        return;
    };

    // Extract known fields into the typed struct
    if (parsed.value == .object) {
        const obj = &parsed.value.object;
        if (obj.get("speaker_pin")) |v| if (v == .integer) {
            settings.speaker_pin = @intCast(v.integer);
        };
        if (obj.get("speaker_pin2")) |v| {
            settings.speaker_pin2 = if (v == .integer) @as(?i32, @intCast(v.integer)) else null;
        };
        inline for (.{
            .{ "speaker_gnd_mode", "speaker_gnd_mode" },
            .{ "output_type", "output_type" },
            .{ "pin_mode", "pin_mode" },
            .{ "theme", "theme" },
            .{ "difficulty", "difficulty" },
            .{ "practice_chars", "practice_chars" },
            .{ "device_name", "device_name" },
            .{ "kb_mode", "kb_mode" },
            .{ "kb_dot_key", "kb_dot_key" },
            .{ "kb_dash_key", "kb_dash_key" },
        }) |pair| {
            if (obj.get(pair[0])) |v| if (v == .string) {
                @field(settings, pair[1]) = gpa.dupe(u8, v.string) catch pair[1];
            };
        }
        inline for (.{
            .{ "data_pin", "data_pin" },
            .{ "dot_pin", "dot_pin" },
            .{ "dash_pin", "dash_pin" },
            .{ "dot_freq", "dot_freq" },
            .{ "dash_freq", "dash_freq" },
            .{ "wpm_target", "wpm_target" },
        }) |pair| {
            if (obj.get(pair[0])) |v| if (v == .integer) {
                @field(settings, pair[1]) = @intCast(v.integer);
            };
        }
        if (obj.get("ground_pin")) |v| {
            settings.ground_pin = if (v == .integer) @as(?i32, @intCast(v.integer)) else null;
        };
        if (obj.get("volume")) |v| {
            settings.volume = switch (v) {
                .float => v.float,
                .integer => @floatFromInt(v.integer),
                else => 0.75,
            };
        }
        if (obj.get("farnsworth_letter_mult")) |v| {
            settings.farnsworth_letter_mult = switch (v) {
                .float => v.float,
                .integer => @floatFromInt(v.integer),
                else => 2.0,
            };
        }
        if (obj.get("farnsworth_word_mult")) |v| {
            settings.farnsworth_word_mult = switch (v) {
                .float => v.float,
                .integer => @floatFromInt(v.integer),
                else => 2.0,
            };
        }
        if (obj.get("use_external_switch")) |v| if (v == .bool) {
            settings.use_external_switch = v.bool;
        };
        if (obj.get("farnsworth_enabled")) |v| if (v == .bool) {
            settings.farnsworth_enabled = v.bool;
        };
        if (obj.get("kb_enabled")) |v| if (v == .bool) {
            settings.kb_enabled = v.bool;
        };
        // grounded_pins (array of ints)
        if (obj.get("grounded_pins")) |v| if (v == .array) {
            var list = std.ArrayList(i32).init(gpa);
            for (v.array.items) |item| {
                if (item == .integer) {
                    list.append(@intCast(item.integer)) catch {};
                }
            }
            settings.grounded_pins = list.toOwnedSlice() catch &.{};
        };
    }
    parsed.deinit();
    reserializeSettings();
}

pub fn reserializeSettings() void {
    if (settings_raw.len > 0) gpa.free(settings_raw);
    var buf = std.ArrayList(u8).init(gpa);
    std.json.stringify(settings, .{}, buf.writer()) catch {};
    settings_raw = buf.toOwnedSlice() catch &.{};
}

pub fn saveSettings() void {
    reserializeSettings();
    const file = std.fs.cwd().createFile("settings.json", .{}) catch return;
    defer file.close();
    file.writeAll(settings_raw) catch {};
}

// ════════════════════════════════════════════════════════════════════════════
//  STATISTICS
// ════════════════════════════════════════════════════════════════════════════

pub const Stats = struct {
    total_attempts: i64 = 0,
    correct: i64 = 0,
    streak: i64 = 0,
    best_streak: i64 = 0,
    total_chars: i64 = 0,
};

pub var stats: Stats = .{};

pub fn loadStats() void {
    const data = std.fs.cwd().readFileAlloc(gpa, "stats.json", 1 << 20) catch return;
    defer gpa.free(data);
    const parsed = std.json.parseFromSlice(Stats, gpa, data, .{
        .ignore_unknown_fields = true,
    }) catch return;
    stats = parsed.value;
    parsed.deinit();
}

pub fn saveStats() void {
    const file = std.fs.cwd().createFile("stats.json", .{}) catch return;
    defer file.close();
    std.json.stringify(stats, .{}, file.writer()) catch {};
}

// ════════════════════════════════════════════════════════════════════════════
//  RUNTIME STATE (mutable strings backed by gpa)
// ════════════════════════════════════════════════════════════════════════════

pub var mode: []u8 = &.{};
pub var cheat_sheet: bool = false;
pub var current_phrase: []u8 = &.{};
pub var decode_result: []u8 = &.{};
pub var decode_correct_answer: []u8 = &.{};
pub var speed_phrase: []u8 = &.{};
pub var speed_result: []u8 = &.{};
pub var speed_morse_buffer: []u8 = &.{};
pub var speed_morse_output: []u8 = &.{};
pub var send_output: []u8 = &.{};
pub var encode_output: []u8 = &.{};
pub var encode_input: []u8 = &.{};
pub var button_active: bool = false;
pub var current_morse_buffer: []u8 = &.{};
pub var net_key_mode_enabled: bool = false;
pub var net_morse_buffer_str: []u8 = &.{};
pub var net_morse_output_str: []u8 = &.{};
pub var kb_output: []u8 = &.{};

/// Replace an allocated state string.
pub fn setStr(dest: *[]u8, new_val: []const u8) void {
    if (dest.len > 0) gpa.free(dest.*);
    dest.* = gpa.dupe(u8, new_val) catch &.{};
}

/// Append to an allocated state string.
pub fn appendStr(dest: *[]u8, suffix: []const u8) void {
    if (suffix.len == 0) return;
    const new = gpa.alloc(u8, dest.len + suffix.len) catch return;
    @memcpy(new[0..dest.len], dest.*);
    @memcpy(new[dest.len..], suffix);
    if (dest.len > 0) gpa.free(dest.*);
    dest.* = new;
}

// ── Network inbox ────────────────────────────────────────────────────────
pub const NetMessage = struct {
    sender: []const u8,
    text: []const u8,
    morse: []const u8,
    ts: f64,
};

pub var net_inbox: [32]?NetMessage = .{null} ** 32;
pub var net_inbox_len: usize = 0;

pub fn addInboxMessage(sender: []const u8, text: []const u8, morse_str: []const u8) void {
    const msg = NetMessage{
        .sender = gpa.dupe(u8, sender) catch "?",
        .text = gpa.dupe(u8, text) catch "",
        .morse = gpa.dupe(u8, morse_str) catch "",
        .ts = @as(f64, @floatFromInt(std.time.milliTimestamp())) / 1000.0,
    };
    if (net_inbox_len < 32) {
        net_inbox[net_inbox_len] = msg;
        net_inbox_len += 1;
    } else {
        // shift left, drop oldest
        var i: usize = 0;
        while (i < 31) : (i += 1) net_inbox[i] = net_inbox[i + 1];
        net_inbox[31] = msg;
    }
}

pub fn clearInbox() void {
    net_inbox_len = 0;
    for (&net_inbox) |*slot| slot.* = null;
}

// ── GPIO state ───────────────────────────────────────────────────────────
pub var gpio_available: bool = false;
pub var gpio_error: ?[]const u8 = null;
pub var gpio_error_log: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(gpa);

pub var pin_states: [28]?bool = .{null} ** 28; // indexed by BCM number

// ── pigpio handle ────────────────────────────────────────────────────────
pub var pi_handle: i32 = -1;
pub var wave_id: i32 = -1;
pub var spk_pin1: ?i32 = null;
pub var spk_pin2: ?i32 = null;

// ── Initialisation ───────────────────────────────────────────────────────
pub fn init() void {
    loadSettings();
    loadStats();
    setStr(&mode, "send");
}

// ── JSON helpers ─────────────────────────────────────────────────────────

/// Write full runtime state as JSON (matches Python's shared.state dict).
pub fn writeStateJson(w: anytype) !void {
    try w.writeAll("{");
    try std.fmt.format(w,
        \\"mode":"{s}","cheat_sheet":{s},"current_phrase":"{s}","decode_result":"{s}",
    , .{ mode, if (cheat_sheet) "true" else "false", current_phrase, decode_result });
    try std.fmt.format(w,
        \\"decode_correct_answer":"{s}","speed_phrase":"{s}","speed_result":"{s}",
    , .{ decode_correct_answer, speed_phrase, speed_result });
    try std.fmt.format(w,
        \\"speed_morse_buffer":"{s}","speed_morse_output":"{s}",
    , .{ speed_morse_buffer, speed_morse_output });
    try std.fmt.format(w,
        \\"send_output":"{s}","encode_output":"{s}","encode_input":"{s}",
    , .{ send_output, encode_output, encode_input });
    try std.fmt.format(w,
        \\"button_active":{s},"current_morse_buffer":"{s}",
    , .{ if (button_active) "true" else "false", current_morse_buffer });
    try std.fmt.format(w,
        \\"net_key_mode":{s},"net_morse_buffer":"{s}","net_morse_output":"{s}",
    , .{ if (net_key_mode_enabled) "true" else "false", net_morse_buffer_str, net_morse_output_str });
    try std.fmt.format(w,
        \\"kb_output":"{s}",
    , .{kb_output});

    // stats
    try std.fmt.format(w,
        \\"stats":{{"total_attempts":{},"correct":{},"streak":{},"best_streak":{},"total_chars":{},"sessions":[]}}
    , .{ stats.total_attempts, stats.correct, stats.streak, stats.best_streak, stats.total_chars });

    // net_inbox
    try w.writeAll(",\"net_inbox\":[");
    var first = true;
    for (net_inbox[0..net_inbox_len]) |maybe_msg| {
        if (maybe_msg) |msg| {
            if (!first) try w.writeAll(",");
            first = false;
            try std.fmt.format(w,
                \\{{"sender":"{s}","text":"{s}","morse":"{s}","ts":{d}}}
            , .{ msg.sender, msg.text, msg.morse, msg.ts });
        }
    }
    try w.writeAll("]}");
}

/// Write stats object as JSON.
pub fn writeStatsJson(w: anytype) !void {
    try std.fmt.format(w,
        \\{{"total_attempts":{},"correct":{},"streak":{},"best_streak":{},"total_chars":{},"sessions":[]}}
    , .{ stats.total_attempts, stats.correct, stats.streak, stats.best_streak, stats.total_chars });
}
