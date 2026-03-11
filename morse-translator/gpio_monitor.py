# -*- coding: utf-8 -*-
"""GPIO pin monitoring — reads every BCM pin plus fixed power rails.

Constantly polls pin state in a background thread and exposes
``get_all_pin_states()`` for the diagnostic page and the status API.

Depends on: shared (settings, pin_states, GPIO_AVAILABLE, gpio_error_log,
            Button / InputDevice types, and the button globals
            dot_btn / dash_btn / data_btn set by sound.init_gpio).
"""

import time
import threading

import shared

# ── BCM GPIO pins on a Pi 40-pin header ──────────────────────────────────────
ALL_BCM_PINS = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,
                14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27]

# Physical-pin → fixed function for the non-GPIO pins on the 40-pin header.
# The frontend already draws these, but this dict is also included in the poll
# response so any client can render a complete board map.
BOARD_POWER_PINS = {
    1:  "3.3V",
    2:  "5V",
    4:  "5V",
    6:  "GND",
    9:  "GND",
    14: "GND",
    17: "3.3V",
    20: "GND",
    25: "GND",
    27: "ID_SD",
    28: "ID_SC",
    30: "GND",
    34: "GND",
    39: "GND",
}

# ── Diagnostic readers ────────────────────────────────────────────────────────
_diag_readers = {}   # {bcm: InputDevice | None} for non-managed pins


def _managed_bcm_set():
    """Return the set of BCM pins currently owned by active gpiozero devices."""
    s = set()
    sp  = shared.settings.get("speaker_pin")
    sp2 = shared.settings.get("speaker_pin2")
    gp  = shared.settings.get("ground_pin")
    grounded = shared.settings.get("grounded_pins", [])
    if sp  is not None: s.add(int(sp))
    if sp2 is not None: s.add(int(sp2))
    if gp  is not None: s.add(int(gp))
    for pin in grounded:
        if pin is not None:
            s.add(int(pin))
    if shared.settings.get("pin_mode") == "dual":
        dp = shared.settings.get("dot_pin")
        da = shared.settings.get("dash_pin")
        if dp is not None: s.add(int(dp))
        if da is not None: s.add(int(da))
    else:
        dp = shared.settings.get("data_pin")
        if dp is not None: s.add(int(dp))
    return s


def init_diag_readers():
    """Open InputDevice for every BCM pin not managed by gpiozero."""
    global _diag_readers
    if not shared.GPIO_AVAILABLE:
        return
    managed = _managed_bcm_set()
    # Close stale readers that are now managed
    for bcm in list(_diag_readers.keys()):
        if bcm in managed:
            dev = _diag_readers.pop(bcm)
            if dev:
                try:
                    dev.close()
                except Exception:
                    pass
    # Open readers for unmanaged pins
    for bcm in ALL_BCM_PINS:
        if bcm in managed:
            continue
        if bcm not in _diag_readers:
            try:
                _diag_readers[bcm] = shared.InputDevice(bcm, pull_up=True)
            except Exception as e:
                msg = f"BCM {bcm}: {e}"
                shared.gpio_error_log.append(msg)
                _diag_readers[bcm] = None


def get_all_pin_states():
    """Return ``{bcm_str: {active, role}}`` for all BCM 2-27."""
    if not shared.GPIO_AVAILABLE:
        return {}
    pm  = shared.settings.get("pin_mode", "single")
    sp  = shared.settings.get("speaker_pin")
    sp2 = shared.settings.get("speaker_pin2")
    dp  = shared.settings.get("data_pin")
    dop = shared.settings.get("dot_pin")
    dap = shared.settings.get("dash_pin")
    gp  = shared.settings.get("ground_pin")
    grounded = shared.settings.get("grounded_pins", [])
    result = {}
    for bcm in ALL_BCM_PINS:
        if bcm == sp:
            result[str(bcm)] = {"active": None, "role": "sp_led_pos"}
        elif bcm == sp2:
            result[str(bcm)] = {"active": None, "role": "sp_led_neg"}
        elif bcm == gp or bcm in grounded:
            result[str(bcm)] = {"active": None, "role": "ground"}
        elif pm == "dual" and bcm == dop:
            result[str(bcm)] = {"active": shared.dot_btn.is_pressed if shared.dot_btn else None, "role": "dot"}
        elif pm == "dual" and bcm == dap:
            result[str(bcm)] = {"active": shared.dash_btn.is_pressed if shared.dash_btn else None, "role": "dash"}
        elif pm != "dual" and bcm == dp:
            result[str(bcm)] = {"active": shared.data_btn.is_pressed if shared.data_btn else None, "role": "data"}
        else:
            dev = _diag_readers.get(bcm)
            if dev is not None:
                try:
                    result[str(bcm)] = {"active": bool(dev.is_active), "role": "unused"}
                except Exception:
                    result[str(bcm)] = {"active": None, "role": "unused"}
            else:
                result[str(bcm)] = {"active": None, "role": "unused"}
    return result


def get_power_pins():
    """Return the fixed power-rail mapping for the 40-pin header."""
    return dict(BOARD_POWER_PINS)


# ── Background poll thread ───────────────────────────────────────────────────

def _pin_poll_worker():
    """Update ``shared.pin_states`` every 50 ms from Button.is_pressed."""
    while True:
        try:
            pm = shared.settings.get("pin_mode", "single")
            if pm == "dual":
                dp = shared.settings.get("dot_pin")
                da = shared.settings.get("dash_pin")
                if shared.dot_btn  and dp is not None:
                    shared.pin_states[int(dp)]  = shared.dot_btn.is_pressed
                if shared.dash_btn and da is not None:
                    shared.pin_states[int(da)]  = shared.dash_btn.is_pressed
            else:
                dp = shared.settings.get("data_pin")
                if shared.data_btn and dp is not None:
                    shared.pin_states[int(dp)]  = shared.data_btn.is_pressed
        except Exception:
            pass
        time.sleep(0.05)


# Start the poll thread as soon as this module is imported
if shared.GPIO_AVAILABLE:
    threading.Thread(target=_pin_poll_worker, daemon=True, name="pin_poll").start()
