// ============================================================================
//  Morse-Pi — USB HID keyboard support via /dev/hidg0.
// ============================================================================
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::thread;
use std::time::Duration;

pub const USB_HID_DEVICE: &str = "/dev/hidg0";

pub static USB_HID_AVAILABLE: AtomicBool = AtomicBool::new(false);
static HID_CHECK_TIME: AtomicI64 = AtomicI64::new(0);

/// HID keycodes for US keyboard layout.
static HID_KEYCODES: &[(char, u8)] = &[
    ('a', 0x04), ('b', 0x05), ('c', 0x06), ('d', 0x07),
    ('e', 0x08), ('f', 0x09), ('g', 0x0a), ('h', 0x0b),
    ('i', 0x0c), ('j', 0x0d), ('k', 0x0e), ('l', 0x0f),
    ('m', 0x10), ('n', 0x11), ('o', 0x12), ('p', 0x13),
    ('q', 0x14), ('r', 0x15), ('s', 0x16), ('t', 0x17),
    ('u', 0x18), ('v', 0x19), ('w', 0x1a), ('x', 0x1b),
    ('y', 0x1c), ('z', 0x1d),
    ('1', 0x1e), ('2', 0x1f), ('3', 0x20), ('4', 0x21),
    ('5', 0x22), ('6', 0x23), ('7', 0x24), ('8', 0x25),
    ('9', 0x26), ('0', 0x27),
    (' ', 0x2c), ('.', 0x37), (',', 0x36), ('/', 0x38),
    ('-', 0x2d), ('=', 0x2e), ('?', 0x38), ('\'', 0x34),
    ('"', 0x34),
];

fn get_keycode(c: char) -> Option<u8> {
    let lower = c.to_ascii_lowercase();
    HID_KEYCODES.iter().find(|(ch, _)| *ch == lower).map(|(_, kc)| *kc)
}

/// Check if /dev/hidg0 exists (cached 5 seconds).
pub fn check_usb_hid() -> bool {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    let last = HID_CHECK_TIME.load(Ordering::Relaxed);
    if now - last < 5000 {
        return USB_HID_AVAILABLE.load(Ordering::Relaxed);
    }
    HID_CHECK_TIME.store(now, Ordering::Relaxed);
    let available = fs::metadata(USB_HID_DEVICE).is_ok();
    USB_HID_AVAILABLE.store(available, Ordering::Relaxed);
    available
}

/// Send a single character as a USB HID keystroke.
pub fn send_key(ch: char, kb_enabled: bool) -> bool {
    if !kb_enabled { return false; }
    if !check_usb_hid() { return false; }

    let keycode = match get_keycode(ch) {
        Some(kc) => kc,
        None => return false,
    };
    let modifier: u8 = if ch.is_ascii_uppercase() || ch == '?' || ch == '!' || ch == '"' {
        0x02
    } else {
        0x00
    };

    let report = [modifier, 0x00, keycode, 0x00, 0x00, 0x00, 0x00, 0x00];
    let release = [0u8; 8];

    let mut file = match OpenOptions::new().write(true).open(USB_HID_DEVICE) {
        Ok(f) => f,
        Err(_) => return false,
    };

    if file.write_all(&report).is_err() { return false; }
    thread::sleep(Duration::from_millis(20));
    if file.write_all(&release).is_err() { return false; }
    true
}

/// Send a full string as USB HID keystrokes.
#[allow(dead_code)]
pub fn send_string(text: &str, kb_enabled: bool) {
    for c in text.chars() {
        send_key(c, kb_enabled);
        thread::sleep(Duration::from_millis(10));
    }
}

/// Send a custom key (for paddle-to-key mapping in custom mode).
pub fn send_custom_key(key_char: &str, kb_enabled: bool) -> bool {
    if !kb_enabled { return false; }
    if key_char == "space" || key_char == " " {
        return send_key(' ', kb_enabled);
    }
    if key_char.len() == 1 {
        return send_key(key_char.chars().next().unwrap(), kb_enabled);
    }
    false
}
