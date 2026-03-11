// ============================================================================
//  Morse-Pi — Sound output, GPIO hardware init, iambic keyer, and all
//  send / speed / network-key mode logic.
// ============================================================================
const std = @import("std");
const state = @import("state.zig");
const morse = @import("morse.zig");
const keyboard = @import("keyboard.zig");
const gpio = @import("gpio.zig");

// ════════════════════════════════════════════════════════════════════════════
//  TIMING HELPERS
// ════════════════════════════════════════════════════════════════════════════

/// Dot element duration in nanoseconds: 1200 ms / WPM.
pub fn getDotUnitNs() u64 {
    const wpm: u64 = @intCast(@max(5, state.settings.wpm_target));
    return (1_200_000_000) / wpm;
}

fn getLetterGapNs() u64 {
    const du = getDotUnitNs();
    var gap = du * 3;
    if (state.settings.farnsworth_enabled) {
        const mult = @max(1.0, state.settings.farnsworth_letter_mult);
        gap = @intFromFloat(@as(f64, @floatFromInt(gap)) * mult);
    }
    return gap;
}

fn getWordExtraNs() u64 {
    const du = getDotUnitNs();
    var gap = du * 4;
    if (state.settings.farnsworth_enabled) {
        const mult = @max(1.0, state.settings.farnsworth_word_mult);
        gap = @intFromFloat(@as(f64, @floatFromInt(gap)) * mult);
    }
    return gap;
}

/// Dot unit in seconds (f64) for compatibility with Python timing.
pub fn getDotUnitSecs() f64 {
    const wpm_f: f64 = @floatFromInt(@max(5, state.settings.wpm_target));
    return 1.2 / wpm_f;
}

// ════════════════════════════════════════════════════════════════════════════
//  LOW-LEVEL TONE / WAVE HELPERS (pigpio)
// ════════════════════════════════════════════════════════════════════════════

fn stopWave() void {
    if (!gpio.use_pigpio or state.pi_handle < 0) return;
    if (state.wave_id >= 0) {
        _ = gpio.wave_tx_stop(state.pi_handle);
        _ = gpio.wave_delete(state.pi_handle, @intCast(state.wave_id));
        state.wave_id = -1;
    }
    if (state.spk_pin1) |p1| gpio.writePin(p1, 0);
    if (state.spk_pin2) |p2| gpio.writePin(p2, 0);
}

fn startWave(freq: u32) bool {
    stopWave();
    if (!gpio.use_pigpio or state.pi_handle < 0) return false;
    const p1 = state.spk_pin1 orelse return false;
    const p2 = state.spk_pin2 orelse return false;
    const clamped_freq = @max(100, @min(4000, freq));
    const half_period_us: u32 = @max(1, 500_000 / clamped_freq);
    const mask1: u32 = @as(u32, 1) << @intCast(p1);
    const mask2: u32 = @as(u32, 1) << @intCast(p2);

    _ = gpio.set_mode(state.pi_handle, @intCast(p1), gpio.PI_OUTPUT);
    _ = gpio.set_mode(state.pi_handle, @intCast(p2), gpio.PI_OUTPUT);
    _ = gpio.wave_clear(state.pi_handle);

    var pulses = [2]gpio.GpioPulse{
        .{ .gpioOn = mask1, .gpioOff = mask2, .usDelay = half_period_us },
        .{ .gpioOn = mask2, .gpioOff = mask1, .usDelay = half_period_us },
    };
    _ = gpio.wave_add_generic(state.pi_handle, 2, &pulses);
    const wid = gpio.wave_create(state.pi_handle);
    if (wid >= 0) {
        state.wave_id = wid;
        _ = gpio.wave_send_repeat(state.pi_handle, @intCast(wid));
        return true;
    }
    state.wave_id = -1;
    return false;
}

// ════════════════════════════════════════════════════════════════════════════
//  PUBLIC TONE API
// ════════════════════════════════════════════════════════════════════════════

pub fn playTone(freq: u32, duration_ns: ?u64) void {
    if (!gpio.use_pigpio or state.pi_handle < 0) return;
    const dual = state.spk_pin2 != null;
    const output_type = state.settings.output_type;
    const is_led = std.mem.eql(u8, output_type, "led");

    state.mu.lock();
    defer state.mu.unlock();

    if (dual) {
        if (is_led) {
            stopWave();
            if (state.spk_pin1) |p1| gpio.writePin(p1, 1);
            if (state.spk_pin2) |p2| gpio.writePin(p2, 0);
        } else {
            _ = startWave(freq);
        }
        if (duration_ns) |dur| {
            std.time.sleep(dur);
            if (is_led) {
                if (state.spk_pin1) |p1| gpio.writePin(p1, 0);
                if (state.spk_pin2) |p2| gpio.writePin(p2, 0);
            } else {
                stopWave();
            }
        }
    } else {
        // Single pin PWM
        if (state.spk_pin1) |p1| {
            if (is_led) {
                gpio.writePin(p1, 1);
            } else {
                // Use hardware PWM: duty = volume * 1000000
                const duty: u32 = @intFromFloat(@max(0.01, @min(0.95, state.settings.volume)) * 1_000_000.0);
                _ = gpio.hardware_PWM(state.pi_handle, @intCast(p1), freq, duty);
            }
            if (duration_ns) |dur| {
                std.time.sleep(dur);
                if (is_led) {
                    gpio.writePin(p1, 0);
                } else {
                    _ = gpio.hardware_PWM(state.pi_handle, @intCast(p1), 0, 0);
                }
            }
        }
    }
}

pub fn stopTone() void {
    if (!gpio.use_pigpio or state.pi_handle < 0) return;
    const dual = state.spk_pin2 != null;
    const is_led = std.mem.eql(u8, state.settings.output_type, "led");

    if (dual) {
        if (is_led) {
            if (state.spk_pin1) |p1| gpio.writePin(p1, 0);
            if (state.spk_pin2) |p2| gpio.writePin(p2, 0);
        } else {
            stopWave();
        }
    } else if (state.spk_pin1) |p1| {
        if (is_led) {
            gpio.writePin(p1, 0);
        } else {
            _ = gpio.hardware_PWM(state.pi_handle, @intCast(p1), 0, 0);
        }
    }
}

/// Play plaintext as Morse code using proper WPM-based timing.
pub fn playMorseString(text: []const u8) void {
    const du = getDotUnitNs();
    for (text, 0..) |char, i| {
        const c = std.ascii.toUpper(char);
        if (c == ' ') {
            std.time.sleep(getWordExtraNs());
            continue;
        }
        const code = morse.charToMorse(c) orelse continue;
        if (std.mem.eql(u8, code, "/")) continue;
        for (code, 0..) |sym, j| {
            if (sym == '.') {
                playTone(@intCast(state.settings.dot_freq), du);
            } else if (sym == '-') {
                playTone(@intCast(state.settings.dash_freq), du * 3);
            }
            if (j < code.len - 1) std.time.sleep(du);
        }
        if (i < text.len - 1) std.time.sleep(getLetterGapNs());
    }
    stopTone();
}

// ════════════════════════════════════════════════════════════════════════════
//  GPIO HARDWARE INIT
// ════════════════════════════════════════════════════════════════════════════

pub fn initGpio() void {
    if (!gpio.use_pigpio or state.pi_handle < 0) return;
    stopWave();

    state.spk_pin1 = if (state.settings.speaker_pin >= 0) state.settings.speaker_pin else null;
    state.spk_pin2 = state.settings.speaker_pin2;

    // Set up speaker pins
    if (state.spk_pin1) |p1| gpio.setupOutputPin(p1);
    if (state.spk_pin2) |p2| gpio.setupOutputPin(p2);

    // Set up ground pins
    if (state.settings.ground_pin) |gp| {
        gpio.setupOutputPin(gp);
        gpio.writePin(gp, 0); // Hold LOW
    }
    for (state.settings.grounded_pins) |gp| {
        gpio.setupOutputPin(gp);
        gpio.writePin(gp, 0);
    }

    // Set up key/button pins
    if (std.mem.eql(u8, state.settings.pin_mode, "dual")) {
        gpio.setupInputPin(state.settings.dot_pin);
        gpio.setupInputPin(state.settings.dash_pin);
        startKeyerThread();
    } else {
        gpio.setupInputPin(state.settings.data_pin);
    }
}

pub fn recreateGpio() void {
    stopKeyerThread();
    virtual_dot = false;
    virtual_dash = false;
    initGpio();
}

// ════════════════════════════════════════════════════════════════════════════
//  IAMBIC KEYER
// ════════════════════════════════════════════════════════════════════════════

const KEYER_IDLE = "IDLE";
const KEYER_DOT = "SENDING_DOT";
const KEYER_DASH = "SENDING_DASH";
const KEYER_GAP = "INTER_ELEMENT_GAP";

pub var keyer_state_label: []const u8 = KEYER_IDLE;
var keyer_stop: std.Thread.ResetEvent = .{};
var keyer_thread: ?std.Thread = null;

// Virtual paddle state — driven by /key_press_dual in the browser
pub var virtual_dot: bool = false;
pub var virtual_dash: bool = false;

fn isDotPressed() bool {
    if (virtual_dot) return true;
    if (!gpio.use_pigpio or state.pi_handle < 0) return false;
    return gpio.readPin(@intCast(state.settings.dot_pin)) orelse false;
}

fn isDashPressed() bool {
    if (virtual_dash) return true;
    if (!gpio.use_pigpio or state.pi_handle < 0) return false;
    return gpio.readPin(@intCast(state.settings.dash_pin)) orelse false;
}

fn keyerEmit(sym: u8) void {
    if (std.mem.eql(u8, state.mode, "speed")) {
        state.appendStr(&state.speed_morse_buffer, &.{sym});
    } else {
        state.appendStr(&state.current_morse_buffer, &.{sym});
    }
}

fn keyerFinalizeLetter() void {
    if (std.mem.eql(u8, state.mode, "speed")) {
        if (state.speed_morse_buffer.len > 0) {
            state.appendStr(&state.speed_morse_output, state.speed_morse_buffer);
            state.appendStr(&state.speed_morse_output, " ");
            state.setStr(&state.speed_morse_buffer, "");
        }
    } else {
        if (state.current_morse_buffer.len > 0) {
            const char = morse.morseToChar(state.current_morse_buffer);
            state.appendStr(&state.send_output, &.{char});
            state.setStr(&state.current_morse_buffer, "");
            if (state.settings.kb_enabled and std.mem.eql(u8, state.settings.kb_mode, "letters")) {
                _ = keyboard.sendKey(char);
                state.appendStr(&state.kb_output, &.{char});
            }
        }
    }
}

fn keyerFinalizeWord() void {
    if (std.mem.eql(u8, state.mode, "speed")) {
        if (state.speed_morse_output.len > 0 and !std.mem.endsWith(u8, state.speed_morse_output, "/")) {
            // Trim trailing spaces, add " / "
            state.appendStr(&state.speed_morse_output, "/ ");
        }
    } else {
        if (state.send_output.len > 0 and !std.mem.endsWith(u8, state.send_output, " ")) {
            state.appendStr(&state.send_output, " ");
            if (state.settings.kb_enabled and std.mem.eql(u8, state.settings.kb_mode, "letters")) {
                _ = keyboard.sendKey(' ');
                state.appendStr(&state.kb_output, " ");
            }
        }
    }
}

fn iambicKeyerWorker() void {
    var dot_memory: bool = false;
    var dash_memory: bool = false;
    var last_sym: enum { none, dot, dash } = .none;

    while (!keyer_stop.isSet()) {
        const du = getDotUnitNs();
        const dot_p = isDotPressed();
        const dash_p = isDashPressed();

        if (!dot_p and !dash_p and !dot_memory and !dash_memory) {
            keyer_state_label = KEYER_IDLE;
            state.button_active = false;
            std.time.sleep(1 * std.time.ns_per_ms);
            continue;
        }

        state.button_active = true;

        // Decide next element
        var sym: enum { dot, dash } = undefined;
        if (dot_memory and !dash_p) {
            sym = .dot;
            dot_memory = false;
        } else if (dash_memory and !dot_p) {
            sym = .dash;
            dash_memory = false;
        } else if (dot_p and dash_p) {
            sym = if (last_sym == .dot) .dash else .dot;
        } else if (dot_p) {
            sym = .dot;
        } else {
            sym = .dash;
        }
        last_sym = sym;

        // Send element
        if (sym == .dot) {
            keyer_state_label = KEYER_DOT;
            keyerEmit('.');
            playTone(@intCast(state.settings.dot_freq), null);
            if (state.settings.kb_enabled and std.mem.eql(u8, state.settings.kb_mode, "custom")) {
                _ = keyboard.sendCustomKey(state.settings.kb_dot_key);
            }
            const end = std.time.nanoTimestamp() + @as(i128, du);
            var opp = false;
            while (std.time.nanoTimestamp() < end and !keyer_stop.isSet()) {
                if (isDashPressed()) opp = true;
                std.time.sleep(1 * std.time.ns_per_ms);
            }
            stopTone();
            if (opp) dash_memory = true;
        } else {
            keyer_state_label = KEYER_DASH;
            keyerEmit('-');
            playTone(@intCast(state.settings.dash_freq), null);
            if (state.settings.kb_enabled and std.mem.eql(u8, state.settings.kb_mode, "custom")) {
                _ = keyboard.sendCustomKey(state.settings.kb_dash_key);
            }
            const end = std.time.nanoTimestamp() + @as(i128, du * 3);
            var opp = false;
            while (std.time.nanoTimestamp() < end and !keyer_stop.isSet()) {
                if (isDotPressed()) opp = true;
                std.time.sleep(1 * std.time.ns_per_ms);
            }
            stopTone();
            if (opp) dot_memory = true;
        }

        // Inter-element gap
        keyer_state_label = KEYER_GAP;
        {
            const end = std.time.nanoTimestamp() + @as(i128, du);
            while (std.time.nanoTimestamp() < end and !keyer_stop.isSet()) {
                if (isDotPressed()) dot_memory = true;
                if (isDashPressed()) dash_memory = true;
                std.time.sleep(1 * std.time.ns_per_ms);
            }
        }

        // Letter / word gap
        if (!isDotPressed() and !isDashPressed() and !dot_memory and !dash_memory) {
            keyer_state_label = KEYER_IDLE;
            const letter_remain = getLetterGapNs() -| du;
            const t0 = std.time.nanoTimestamp();
            var broken = false;
            while (std.time.nanoTimestamp() - t0 < @as(i128, letter_remain) and !keyer_stop.isSet()) {
                if (isDotPressed() or isDashPressed()) {
                    broken = true;
                    break;
                }
                std.time.sleep(1 * std.time.ns_per_ms);
            }
            if (!broken) {
                keyerFinalizeLetter();
                const word_extra = getWordExtraNs();
                const t1 = std.time.nanoTimestamp();
                var broken2 = false;
                while (std.time.nanoTimestamp() - t1 < @as(i128, word_extra) and !keyer_stop.isSet()) {
                    if (isDotPressed() or isDashPressed()) {
                        broken2 = true;
                        break;
                    }
                    std.time.sleep(1 * std.time.ns_per_ms);
                }
                if (!broken2) keyerFinalizeWord();
            }
        }
    }
}

fn startKeyerThread() void {
    keyer_stop.reset();
    keyer_thread = std.Thread.spawn(.{}, iambicKeyerWorker, .{}) catch return;
}

fn stopKeyerThread() void {
    keyer_stop.set();
    if (keyer_thread) |t| {
        t.join();
        keyer_thread = null;
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  SEND MODE (single key — straight key)
// ════════════════════════════════════════════════════════════════════════════

pub var send_buffer: std.ArrayList(u8) = std.ArrayList(u8).init(state.gpa);
var send_active: bool = false;
var send_press_time: i64 = 0;
var send_gap_timer: ?std.Thread = null;

pub fn sendButtonPressed() void {
    send_active = true;
    send_press_time = std.time.milliTimestamp();
    state.button_active = true;
    playTone(@intCast(state.settings.dot_freq), null);
}

pub fn sendButtonReleased() void {
    send_active = false;
    state.button_active = false;
    stopTone();
    const duration_ms = std.time.milliTimestamp() - send_press_time;
    const dot_unit_ms: i64 = @intCast(getDotUnitNs() / std.time.ns_per_ms);
    const symbol: u8 = if (duration_ms < dot_unit_ms * 2) '.' else '-';
    send_buffer.append(symbol) catch {};
    state.setStr(&state.current_morse_buffer, send_buffer.items);

    if (state.settings.kb_enabled and std.mem.eql(u8, state.settings.kb_mode, "custom")) {
        const key = if (symbol == '.') state.settings.kb_dot_key else state.settings.kb_dash_key;
        _ = keyboard.sendCustomKey(key);
    }

    // Finalize letter after letter gap
    send_gap_timer = std.Thread.spawn(.{}, sendGapWorker, .{}) catch null;
}

fn sendGapWorker() void {
    std.time.sleep(getLetterGapNs());
    if (!send_active and send_buffer.items.len > 0) {
        const char = morse.morseToChar(send_buffer.items);
        state.appendStr(&state.send_output, &.{char});
        state.setStr(&state.current_morse_buffer, "");
        send_buffer.clearRetainingCapacity();
        if (state.settings.kb_enabled and std.mem.eql(u8, state.settings.kb_mode, "letters")) {
            _ = keyboard.sendKey(char);
            state.appendStr(&state.kb_output, &.{char});
        }
        // Wait for word gap
        std.time.sleep(getWordExtraNs());
        if (!send_active) {
            if (state.send_output.len > 0 and !std.mem.endsWith(u8, state.send_output, " ")) {
                state.appendStr(&state.send_output, " ");
                if (state.settings.kb_enabled and std.mem.eql(u8, state.settings.kb_mode, "letters")) {
                    _ = keyboard.sendKey(' ');
                    state.appendStr(&state.kb_output, " ");
                }
            }
        }
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  SPEED MODE
// ════════════════════════════════════════════════════════════════════════════

pub var speed_buffer: std.ArrayList(u8) = std.ArrayList(u8).init(state.gpa);
pub var speed_active: bool = false;
var speed_press_time: i64 = 0;
var speed_gap_timer: ?std.Thread = null;

pub fn speedButtonPressed() void {
    speed_active = true;
    speed_press_time = std.time.milliTimestamp();
    state.button_active = true;
    playTone(@intCast(state.settings.dot_freq), null);
}

pub fn speedButtonReleased() void {
    speed_active = false;
    state.button_active = false;
    stopTone();
    const duration_ms = std.time.milliTimestamp() - speed_press_time;
    const dot_unit_ms: i64 = @intCast(getDotUnitNs() / std.time.ns_per_ms);
    const symbol: u8 = if (duration_ms < dot_unit_ms * 2) '.' else '-';
    speed_buffer.append(symbol) catch {};
    state.setStr(&state.speed_morse_buffer, speed_buffer.items);

    speed_gap_timer = std.Thread.spawn(.{}, speedGapWorker, .{}) catch null;
}

fn speedGapWorker() void {
    std.time.sleep(getLetterGapNs());
    if (!speed_active and speed_buffer.items.len > 0) {
        const code = state.gpa.dupe(u8, speed_buffer.items) catch return;
        defer state.gpa.free(code);
        state.appendStr(&state.speed_morse_output, code);
        state.appendStr(&state.speed_morse_output, " ");
        state.setStr(&state.speed_morse_buffer, "");
        speed_buffer.clearRetainingCapacity();

        // Wait for word gap
        std.time.sleep(getWordExtraNs());
        if (!speed_active and state.speed_morse_output.len > 0 and
            !std.mem.endsWith(u8, state.speed_morse_output, "/"))
        {
            state.appendStr(&state.speed_morse_output, "/ ");
        }
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  NETWORK KEY MODE
// ════════════════════════════════════════════════════════════════════════════

pub var net_morse_buffer: std.ArrayList(u8) = std.ArrayList(u8).init(state.gpa);
var net_morse_active: bool = false;
var net_morse_press_time: i64 = 0;
var net_gap_timer: ?std.Thread = null;

pub fn netKeyPressed() void {
    net_morse_active = true;
    net_morse_press_time = std.time.milliTimestamp();
    state.button_active = true;
    playTone(@intCast(state.settings.dot_freq), null);
}

pub fn netKeyReleased() void {
    net_morse_active = false;
    state.button_active = false;
    stopTone();
    const duration_ms = std.time.milliTimestamp() - net_morse_press_time;
    const dot_unit_ms: i64 = @intCast(getDotUnitNs() / std.time.ns_per_ms);
    const symbol: u8 = if (duration_ms < dot_unit_ms * 2) '.' else '-';
    net_morse_buffer.append(symbol) catch {};
    state.setStr(&state.net_morse_buffer_str, net_morse_buffer.items);

    net_gap_timer = std.Thread.spawn(.{}, netGapWorker, .{}) catch null;
}

fn netGapWorker() void {
    std.time.sleep(getLetterGapNs());
    if (!net_morse_active and net_morse_buffer.items.len > 0) {
        const char = morse.morseToChar(net_morse_buffer.items);
        state.appendStr(&state.net_morse_output_str, &.{char});
        state.setStr(&state.net_morse_buffer_str, "");
        net_morse_buffer.clearRetainingCapacity();

        std.time.sleep(getWordExtraNs());
        if (!net_morse_active and state.net_morse_output_str.len > 0 and
            !std.mem.endsWith(u8, state.net_morse_output_str, " "))
        {
            state.appendStr(&state.net_morse_output_str, " ");
        }
    }
}
