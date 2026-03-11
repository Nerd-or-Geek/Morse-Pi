// ============================================================================
//  Morse-Pi — GPIO monitoring via pigpiod_if2 C library.
//
//  Reads every BCM pin plus fixed power rails.  Polls pin state in a
//  background thread for the diagnostic page and the status API.
// ============================================================================
const std = @import("std");
const build_options = @import("build_options");
const state = @import("state.zig");

// ── pigpio C bindings (only when compiled with -Dgpio=true) ──────────────────

pub const use_pigpio = build_options.use_pigpio;

pub const PI_INPUT: c_uint = 0;
pub const PI_OUTPUT: c_uint = 1;
pub const PI_PUD_OFF: c_uint = 0;
pub const PI_PUD_DOWN: c_uint = 1;
pub const PI_PUD_UP: c_uint = 2;

pub const GpioPulse = extern struct {
    gpioOn: u32,
    gpioOff: u32,
    usDelay: u32,
};

// Extern declarations from pigpiod_if2.h (resolved at link time)
pub extern fn pigpio_start(addrStr: ?[*:0]const u8, portStr: ?[*:0]const u8) callconv(.C) c_int;
pub extern fn pigpio_stop(pi: c_int) callconv(.C) void;
pub extern fn set_mode(pi: c_int, gpio: c_uint, mode: c_uint) callconv(.C) c_int;
pub extern fn gpio_read(pi: c_int, gpio: c_uint) callconv(.C) c_int;
pub extern fn gpio_write(pi: c_int, gpio: c_uint, level: c_uint) callconv(.C) c_int;
pub extern fn set_pull_up_down(pi: c_int, gpio: c_uint, pud: c_uint) callconv(.C) c_int;
pub extern fn set_PWM_frequency(pi: c_int, gpio: c_uint, frequency: c_uint) callconv(.C) c_int;
pub extern fn set_PWM_dutycycle(pi: c_int, gpio: c_uint, dutycycle: c_uint) callconv(.C) c_int;
pub extern fn hardware_PWM(pi: c_int, gpio: c_uint, freq: c_uint, duty: u32) callconv(.C) c_int;
pub extern fn wave_clear(pi: c_int) callconv(.C) c_int;
pub extern fn wave_add_generic(pi: c_int, numPulses: c_uint, pulses: [*]GpioPulse) callconv(.C) c_int;
pub extern fn wave_create(pi: c_int) callconv(.C) c_int;
pub extern fn wave_send_repeat(pi: c_int, wave_id: c_uint) callconv(.C) c_int;
pub extern fn wave_tx_stop(pi: c_int) callconv(.C) c_int;
pub extern fn wave_delete(pi: c_int, wave_id: c_uint) callconv(.C) c_int;

// ── BCM pins on a Pi 40-pin header ──────────────────────────────────────────

pub const ALL_BCM_PINS = [_]u5{
    2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13,
    14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
    26, 27,
};

/// Physical pin → fixed function for non-GPIO pins on the 40-pin header.
pub const PowerPin = struct { phys: u8, label: []const u8 };
pub const BOARD_POWER_PINS = [_]PowerPin{
    .{ .phys = 1, .label = "3.3V" },
    .{ .phys = 2, .label = "5V" },
    .{ .phys = 4, .label = "5V" },
    .{ .phys = 6, .label = "GND" },
    .{ .phys = 9, .label = "GND" },
    .{ .phys = 14, .label = "GND" },
    .{ .phys = 17, .label = "3.3V" },
    .{ .phys = 20, .label = "GND" },
    .{ .phys = 25, .label = "GND" },
    .{ .phys = 27, .label = "ID_SD" },
    .{ .phys = 28, .label = "ID_SC" },
    .{ .phys = 30, .label = "GND" },
    .{ .phys = 34, .label = "GND" },
    .{ .phys = 39, .label = "GND" },
};

// ── Initialisation ───────────────────────────────────────────────────────────

pub fn init() void {
    if (!use_pigpio) return;
    const pi = pigpio_start(null, null);
    if (pi < 0) {
        state.gpio_available = false;
        state.gpio_error = "pigpiod not running or connection failed";
        return;
    }
    state.pi_handle = pi;
    state.gpio_available = true;

    // Set up input pins with pull-up for button reading
    for (ALL_BCM_PINS) |bcm| {
        if (!isManagedPin(bcm)) {
            _ = set_mode(pi, bcm, PI_INPUT);
            _ = set_pull_up_down(pi, bcm, PI_PUD_UP);
        }
    }
}

pub fn deinit() void {
    if (use_pigpio and state.pi_handle >= 0) {
        pigpio_stop(state.pi_handle);
        state.pi_handle = -1;
    }
}

fn isManagedPin(bcm: u5) bool {
    const s = &state.settings;
    if (s.speaker_pin == @as(i32, bcm)) return true;
    if (s.speaker_pin2) |sp2| if (sp2 == @as(i32, bcm)) return true;
    if (s.ground_pin) |gp| if (gp == @as(i32, bcm)) return true;
    for (s.grounded_pins) |gp| if (gp == @as(i32, bcm)) return true;
    if (std.mem.eql(u8, s.pin_mode, "dual")) {
        if (s.dot_pin == @as(i32, bcm)) return true;
        if (s.dash_pin == @as(i32, bcm)) return true;
    } else {
        if (s.data_pin == @as(i32, bcm)) return true;
    }
    return false;
}

/// Read a single GPIO pin.
pub fn readPin(bcm: u5) ?bool {
    if (!use_pigpio or state.pi_handle < 0) return null;
    const val = gpio_read(state.pi_handle, bcm);
    if (val < 0) return null;
    return val == 1;
}

// ── Pin state JSON ───────────────────────────────────────────────────────────

/// Write pin states as JSON object: {"bcm": {"active":bool|null,"role":"..."}, ...}
pub fn writePinStatesJson(w: anytype) !void {
    const s = &state.settings;
    const pm = s.pin_mode;
    try w.writeAll("{");
    var first = true;
    for (ALL_BCM_PINS) |bcm| {
        if (!first) try w.writeAll(",");
        first = false;
        try std.fmt.format(w, "\"{}\":{{", .{bcm});
        const bcm_i32: i32 = @intCast(bcm);

        if (bcm_i32 == s.speaker_pin) {
            try w.writeAll("\"active\":null,\"role\":\"sp_led_pos\"");
        } else if (s.speaker_pin2 != null and bcm_i32 == s.speaker_pin2.?) {
            try w.writeAll("\"active\":null,\"role\":\"sp_led_neg\"");
        } else if ((s.ground_pin != null and bcm_i32 == s.ground_pin.?) or isGrounded(s, bcm_i32)) {
            try w.writeAll("\"active\":null,\"role\":\"ground\"");
        } else if (std.mem.eql(u8, pm, "dual") and bcm_i32 == s.dot_pin) {
            const active = readPin(bcm);
            if (active) |a| {
                try std.fmt.format(w, "\"active\":{s},\"role\":\"dot\"", .{if (a) "true" else "false"});
            } else {
                try w.writeAll("\"active\":null,\"role\":\"dot\"");
            }
        } else if (std.mem.eql(u8, pm, "dual") and bcm_i32 == s.dash_pin) {
            const active = readPin(bcm);
            if (active) |a| {
                try std.fmt.format(w, "\"active\":{s},\"role\":\"dash\"", .{if (a) "true" else "false"});
            } else {
                try w.writeAll("\"active\":null,\"role\":\"dash\"");
            }
        } else if (!std.mem.eql(u8, pm, "dual") and bcm_i32 == s.data_pin) {
            const active = readPin(bcm);
            if (active) |a| {
                try std.fmt.format(w, "\"active\":{s},\"role\":\"data\"", .{if (a) "true" else "false"});
            } else {
                try w.writeAll("\"active\":null,\"role\":\"data\"");
            }
        } else {
            const active = readPin(bcm);
            if (active) |a| {
                try std.fmt.format(w, "\"active\":{s},\"role\":\"unused\"", .{if (a) "true" else "false"});
            } else {
                try w.writeAll("\"active\":null,\"role\":\"unused\"");
            }
        }
        try w.writeAll("}");
    }
    try w.writeAll("}");
}

fn isGrounded(s: *const state.Settings, bcm: i32) bool {
    for (s.grounded_pins) |gp| if (gp == bcm) return true;
    return false;
}

/// Write power pins as JSON: {"1":"3.3V","2":"5V",...}
pub fn writePowerPinsJson(w: anytype) !void {
    try w.writeAll("{");
    for (BOARD_POWER_PINS, 0..) |pp, i| {
        if (i > 0) try w.writeAll(",");
        try std.fmt.format(w, "\"{}\":\"{s}\"", .{ pp.phys, pp.label });
    }
    try w.writeAll("}");
}

// ── Background poll thread ───────────────────────────────────────────────────

pub fn startPollThread() void {
    if (!use_pigpio) return;
    const thread = std.Thread.spawn(.{}, pinPollWorker, .{}) catch return;
    thread.detach();
}

fn pinPollWorker() void {
    while (true) {
        if (state.pi_handle >= 0) {
            const s = &state.settings;
            if (std.mem.eql(u8, s.pin_mode, "dual")) {
                if (readPin(@intCast(s.dot_pin))) |v| state.pin_states[@intCast(s.dot_pin)] = v;
                if (readPin(@intCast(s.dash_pin))) |v| state.pin_states[@intCast(s.dash_pin)] = v;
            } else {
                if (readPin(@intCast(s.data_pin))) |v| state.pin_states[@intCast(s.data_pin)] = v;
            }
        }
        std.time.sleep(50 * std.time.ns_per_ms);
    }
}

// ── GPIO setup for sound/output pins ─────────────────────────────────────────

pub fn setupOutputPin(pin: i32) void {
    if (!use_pigpio or state.pi_handle < 0) return;
    _ = set_mode(state.pi_handle, @intCast(pin), PI_OUTPUT);
    _ = gpio_write(state.pi_handle, @intCast(pin), 0);
}

pub fn setupInputPin(pin: i32) void {
    if (!use_pigpio or state.pi_handle < 0) return;
    _ = set_mode(state.pi_handle, @intCast(pin), PI_INPUT);
    _ = set_pull_up_down(state.pi_handle, @intCast(pin), PI_PUD_UP);
}

pub fn writePin(pin: i32, level: u1) void {
    if (!use_pigpio or state.pi_handle < 0) return;
    _ = gpio_write(state.pi_handle, @intCast(pin), level);
}
