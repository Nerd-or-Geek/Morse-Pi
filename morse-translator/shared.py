# -*- coding: utf-8 -*-
"""Shared state, settings, and hardware imports used across all modules.

This module is imported first by every other module, so it must NOT import
any of the sibling project modules (morse, keyboard, gpio_monitor, sound)
to avoid circular-dependency issues.
"""

import time
import threading
import json
import os

# ── GPIO library imports ──────────────────────────────────────────────────────
GPIO_ERROR = None
GPIO_AVAILABLE = False
try:
    from gpiozero import Button, PWMOutputDevice, InputDevice, OutputDevice
    GPIO_AVAILABLE = True
except Exception as _ge:
    GPIO_ERROR = str(_ge)

# Provide stub classes so other modules can reference the types without
# guarding every single access when gpiozero is unavailable.
if not GPIO_AVAILABLE:
    class _Stub:
        """Placeholder that does nothing – avoids NameError on non-Pi hosts."""
        def __init__(self, *a, **kw): pass
        def __bool__(self): return False
        def close(self): pass
    Button = _Stub
    PWMOutputDevice = _Stub
    InputDevice = _Stub
    OutputDevice = _Stub

# ── pigpio (optional, for dual-pin push-pull speaker) ─────────────────────────
_pigpio = None
_pigpio_mod = None
try:
    import pigpio as _pigpio_mod
    _pigpio = _pigpio_mod.pi()
    if not _pigpio.connected:
        _pigpio = None
except Exception:
    pass

# ── Settings ──────────────────────────────────────────────────────────────────
SETTINGS_FILE = "settings.json"
DEFAULT_SETTINGS = {
    "speaker_pin": 18,
    "speaker_pin2": None,
    "speaker_gnd_mode": "3v3",
    "output_type": "speaker",
    "pin_mode": "single",
    "data_pin": 17,
    "dot_pin": 22,
    "dash_pin": 27,
    "ground_pin": None,
    "grounded_pins": [],
    "use_external_switch": False,
    "dot_freq": 700,
    "dash_freq": 500,
    "volume": 0.75,
    "wpm_target": 20,
    "theme": "dark",
    "difficulty": "easy",
    "quiz_categories": ["words"],
    "practice_chars": "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    "farnsworth_enabled": False,
    "farnsworth_letter_mult": 2.0,
    "farnsworth_word_mult": 2.0,
    "device_name": "Morse Pi",
    "kb_enabled": False,
    "kb_mode": "letters",
    "kb_dot_key": "z",
    "kb_dash_key": "x",
}


def load_settings():
    if os.path.exists(SETTINGS_FILE):
        try:
            with open(SETTINGS_FILE, "r") as f:
                saved = json.load(f)
            merged = DEFAULT_SETTINGS.copy()
            merged.update(saved)
            return merged
        except Exception:
            pass
    return DEFAULT_SETTINGS.copy()


def save_settings_to_file(s):
    with open(SETTINGS_FILE, "w") as f:
        json.dump(s, f, indent=2)


settings = load_settings()

# ── Statistics ────────────────────────────────────────────────────────────────
STATS_FILE = "stats.json"


def load_stats():
    default = {
        "total_attempts": 0, "correct": 0,
        "streak": 0, "best_streak": 0,
        "total_chars": 0, "sessions": [],
    }
    if os.path.exists(STATS_FILE):
        try:
            with open(STATS_FILE, "r") as f:
                saved = json.load(f)
            merged = default.copy()
            merged.update(saved)
            return merged
        except Exception:
            pass
    return default


def save_stats_to_file():
    try:
        with open(STATS_FILE, "w") as f:
            json.dump(state["stats"], f, indent=2)
    except Exception:
        pass


# ── Shared runtime state ─────────────────────────────────────────────────────
state = {
    "mode": "send",
    "cheat_sheet": False,
    "current_phrase": "",
    "decode_result": "",
    "decode_correct_answer": "",
    "speed_phrase": "",
    "speed_result": "",
    "speed_morse_buffer": "",
    "speed_morse_output": "",
    "send_output": "",
    "encode_output": "",
    "encode_input": "",
    "stats": load_stats(),
    "button_active": False,
    "current_morse_buffer": "",
    "net_inbox": [],
    "net_morse_buffer": "",
    "net_morse_output": "",
    "net_key_mode": False,
    "kb_output": "",
}

pin_states = {}   # {bcm: bool} — live state updated by poll thread + callbacks
lock = threading.Lock()

# ── GPIO device globals (set by sound.init_gpio) ─────────────────────────────
beeper = None            # PWMOutputDevice for single-pin speaker mode
led_out2 = None          # OutputDevice for speaker_pin2 in LED mode (no-pigpio fallback)
data_btn = None
dot_btn = None
dash_btn = None
ground_out = None        # OutputDevice held LOW to act as a GND pin
grounded_outputs = []    # list of OutputDevices for grounded_pins
_wave_id = None          # pigpio wave ID for dual-pin speaker mode
_spk_pins = (None, None) # (pin1, pin2) tuple for dual-pin mode tracking

gpio_error_log = []      # list of error strings, newest at end
