// ============================================================================
//  Morse-Pi — USB HID keyboard support via /dev/hidg0.
// ============================================================================
const std = @import("std");
const state = @import("state.zig");

pub const USB_HID_DEVICE = "/dev/hidg0";

pub var usb_hid_available: bool = false;
var hid_check_time: i64 = 0;

/// HID keycodes for US keyboard layout.
const KeyEntry = struct { char: u8, keycode: u8 };
const HID_KEYCODES = [_]KeyEntry{
    .{ .char = 'a', .keycode = 0x04 }, .{ .char = 'b', .keycode = 0x05 },
    .{ .char = 'c', .keycode = 0x06 }, .{ .char = 'd', .keycode = 0x07 },
    .{ .char = 'e', .keycode = 0x08 }, .{ .char = 'f', .keycode = 0x09 },
    .{ .char = 'g', .keycode = 0x0a }, .{ .char = 'h', .keycode = 0x0b },
    .{ .char = 'i', .keycode = 0x0c }, .{ .char = 'j', .keycode = 0x0d },
    .{ .char = 'k', .keycode = 0x0e }, .{ .char = 'l', .keycode = 0x0f },
    .{ .char = 'm', .keycode = 0x10 }, .{ .char = 'n', .keycode = 0x11 },
    .{ .char = 'o', .keycode = 0x12 }, .{ .char = 'p', .keycode = 0x13 },
    .{ .char = 'q', .keycode = 0x14 }, .{ .char = 'r', .keycode = 0x15 },
    .{ .char = 's', .keycode = 0x16 }, .{ .char = 't', .keycode = 0x17 },
    .{ .char = 'u', .keycode = 0x18 }, .{ .char = 'v', .keycode = 0x19 },
    .{ .char = 'w', .keycode = 0x1a }, .{ .char = 'x', .keycode = 0x1b },
    .{ .char = 'y', .keycode = 0x1c }, .{ .char = 'z', .keycode = 0x1d },
    .{ .char = '1', .keycode = 0x1e }, .{ .char = '2', .keycode = 0x1f },
    .{ .char = '3', .keycode = 0x20 }, .{ .char = '4', .keycode = 0x21 },
    .{ .char = '5', .keycode = 0x22 }, .{ .char = '6', .keycode = 0x23 },
    .{ .char = '7', .keycode = 0x24 }, .{ .char = '8', .keycode = 0x25 },
    .{ .char = '9', .keycode = 0x26 }, .{ .char = '0', .keycode = 0x27 },
    .{ .char = ' ', .keycode = 0x2c }, .{ .char = '.', .keycode = 0x37 },
    .{ .char = ',', .keycode = 0x36 }, .{ .char = '/', .keycode = 0x38 },
    .{ .char = '-', .keycode = 0x2d }, .{ .char = '=', .keycode = 0x2e },
    .{ .char = '?', .keycode = 0x38 }, .{ .char = '\'', .keycode = 0x34 },
    .{ .char = '"', .keycode = 0x34 },
};

fn getKeycode(c: u8) ?u8 {
    const lower = std.ascii.toLower(c);
    for (HID_KEYCODES) |e| {
        if (e.char == lower) return e.keycode;
    }
    return null;
}

/// Check if /dev/hidg0 exists (cached 5 seconds).
pub fn checkUsbHid() bool {
    const now = std.time.milliTimestamp();
    if (now - hid_check_time < 5000) return usb_hid_available;
    hid_check_time = now;
    usb_hid_available = blk: {
        const f = std.fs.openFileAbsolute(USB_HID_DEVICE, .{}) catch break :blk false;
        f.close();
        break :blk true;
    };
    return usb_hid_available;
}

/// Send a single character as a USB HID keystroke.
pub fn sendKey(char: u8) bool {
    if (!state.settings.kb_enabled) return false;
    if (!checkUsbHid()) return false;

    const keycode = getKeycode(char) orelse return false;
    const modifier: u8 = if (std.ascii.isUpper(char) or char == '?' or char == '!' or char == '"') 0x02 else 0x00;

    const report = [8]u8{ modifier, 0x00, keycode, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const release = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };

    const file = std.fs.openFileAbsolute(USB_HID_DEVICE, .{ .mode = .read_write }) catch return false;
    defer file.close();

    file.writeAll(&report) catch return false;
    std.time.sleep(20 * std.time.ns_per_ms);
    file.writeAll(&release) catch return false;
    return true;
}

/// Send a full string as USB HID keystrokes.
pub fn sendString(text: []const u8) void {
    for (text) |c| {
        _ = sendKey(c);
        std.time.sleep(10 * std.time.ns_per_ms);
    }
}

/// Send a custom key (for paddle-to-key mapping in custom mode).
pub fn sendCustomKey(key_char: []const u8) bool {
    if (!state.settings.kb_enabled) return false;
    if (std.mem.eql(u8, key_char, "space") or (key_char.len == 1 and key_char[0] == ' ')) {
        return sendKey(' ');
    }
    if (key_char.len == 1) return sendKey(key_char[0]);
    return false;
}
