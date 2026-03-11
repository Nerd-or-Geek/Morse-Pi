# -*- coding: utf-8 -*-
"""USB HID keyboard support — send keystrokes via /dev/hidg0.

Depends on: shared (settings, state)
"""

import os
import time

import shared

# ── Constants ─────────────────────────────────────────────────────────────────
USB_HID_DEVICE = "/dev/hidg0"
USB_HID_AVAILABLE = False

HID_KEYCODES = {
    'a': 0x04, 'b': 0x05, 'c': 0x06, 'd': 0x07, 'e': 0x08, 'f': 0x09,
    'g': 0x0a, 'h': 0x0b, 'i': 0x0c, 'j': 0x0d, 'k': 0x0e, 'l': 0x0f,
    'm': 0x10, 'n': 0x11, 'o': 0x12, 'p': 0x13, 'q': 0x14, 'r': 0x15,
    's': 0x16, 't': 0x17, 'u': 0x18, 'v': 0x19, 'w': 0x1a, 'x': 0x1b,
    'y': 0x1c, 'z': 0x1d,
    '1': 0x1e, '2': 0x1f, '3': 0x20, '4': 0x21, '5': 0x22,
    '6': 0x23, '7': 0x24, '8': 0x25, '9': 0x26, '0': 0x27,
    ' ': 0x2c,
    '.': 0x37, ',': 0x36, '/': 0x38, '-': 0x2d, '=': 0x2e,
    '?': 0x38,
    "'": 0x34, '"': 0x34,
}

# ── Availability check (cached for 5 s) ──────────────────────────────────────
_hid_check_time = 0


def _check_usb_hid():
    """Return True if /dev/hidg0 exists (cached for 5 s)."""
    global USB_HID_AVAILABLE, _hid_check_time
    now = time.time()
    if now - _hid_check_time < 5:
        return USB_HID_AVAILABLE
    USB_HID_AVAILABLE = os.path.exists(USB_HID_DEVICE)
    _hid_check_time = now
    return USB_HID_AVAILABLE


# ── Send helpers ──────────────────────────────────────────────────────────────

def _hid_send_key(char):
    """Send a single character as a USB HID keystroke."""
    if not shared.settings.get("kb_enabled", False):
        return False
    if not _check_usb_hid():
        return False

    char_lower = char.lower()
    keycode = HID_KEYCODES.get(char_lower)
    if keycode is None:
        return False

    modifier = 0x00
    if char.isupper() or char in '?!"':
        modifier = 0x02  # Left Shift

    try:
        report  = bytes([modifier, 0x00, keycode, 0x00, 0x00, 0x00, 0x00, 0x00])
        release = bytes([0x00] * 8)
        with open(USB_HID_DEVICE, 'rb+') as fd:
            fd.write(report)
            fd.flush()
            time.sleep(0.02)
            fd.write(release)
            fd.flush()
        return True
    except Exception as e:
        print(f"USB HID error: {e}")
        return False


def _hid_send_string(text):
    """Send a full string as USB HID keystrokes."""
    for char in text:
        _hid_send_key(char)
        time.sleep(0.01)


def _hid_send_custom_key(key_char):
    """Send a custom key (for paddle-to-key mapping in custom mode)."""
    if not shared.settings.get("kb_enabled", False):
        return False
    if key_char.lower() == 'space' or key_char == ' ':
        return _hid_send_key(' ')
    return _hid_send_key(key_char)


# Probe once at import time
_check_usb_hid()
