# -*- coding: utf-8 -*-
import time
import threading
import json
import random
import os
import socket
import struct
import uuid as _uuid_mod
import urllib.request as _urllib_request
from flask import Flask, render_template, request, jsonify

# Try importing GPIO - gracefully degrade if not available
GPIO_ERROR = None
try:
    from gpiozero import Button, PWMOutputDevice, InputDevice, OutputDevice
    GPIO_AVAILABLE = True
except Exception as _ge:
    GPIO_AVAILABLE = False
    GPIO_ERROR = str(_ge)

# --- Morse Code Mapping ---
MORSE_CODE = {
    'A': '.-', 'B': '-...', 'C': '-.-.', 'D': '-..', 'E': '.',
    'F': '..-.', 'G': '--.', 'H': '....', 'I': '..', 'J': '.---',
    'K': '-.-', 'L': '.-..', 'M': '--', 'N': '-.', 'O': '---',
    'P': '.--.', 'Q': '--.-', 'R': '.-.', 'S': '...', 'T': '-',
    'U': '..-', 'V': '...-', 'W': '.--', 'X': '-..-', 'Y': '-.--',
    'Z': '--..',
    '0': '-----', '1': '.----', '2': '..---', '3': '...--', '4': '....-',
    '5': '.....', '6': '-....', '7': '--...', '8': '---..', '9': '----.',
    '.': '.-.-.-', ',': '--..--', '?': '..--..', "'": '.----.',
    '!': '-.-.--', '/': '-..-.', '(': '-.--.', ')': '-.--.-',
    '&': '.-...', ':': '---...', ';': '-.-.-.', '=': '-...-',
    '+': '.-.-.', '-': '-....-', '_': '..--.-', '"': '.-..-.',
    '$': '...-..-', '@': '.--.-.', ' ': '/'
}

SETTINGS_FILE = "settings.json"
DEFAULT_SETTINGS = {
    "speaker_pin": 18,
    "output_type": "speaker",  # "speaker" or "led"
    "pin_mode": "single",
    "data_pin": 17,
    "dot_pin": 22,
    "dash_pin": 27,
    "ground_pin": None,
    "grounded_pins": [],  # list of BCM pins set as ground outputs
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
    # USB HID Keyboard settings
    "kb_enabled": False,
    "kb_mode": "letters",  # "letters" or "custom"
    "kb_dot_key": "z",
    "kb_dash_key": "x"
}

def load_settings():
    if os.path.exists(SETTINGS_FILE):
        try:
            with open(SETTINGS_FILE, "r") as f:
                saved = json.load(f)
            # Merge with defaults for any new keys
            merged = DEFAULT_SETTINGS.copy()
            merged.update(saved)
            return merged
        except Exception:
            pass
    return DEFAULT_SETTINGS.copy()

def save_settings_to_file(s):
    with open(SETTINGS_FILE, "w") as f:
        json.dump(s, f, indent=2)

STATS_FILE = "stats.json"

def load_stats():
    """Load statistics from disk, merging with defaults for forward compatibility."""
    default = {
        "total_attempts": 0, "correct": 0,
        "streak": 0, "best_streak": 0,
        "total_chars": 0, "sessions": []
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
    """Persist current statistics to disk."""
    try:
        with open(STATS_FILE, "w") as f:
            json.dump(state["stats"], f, indent=2)
    except Exception:
        pass

settings = load_settings()

# ── Peer-to-peer network ──────────────────────────────────────────────────────
BEACON_PORT  = 5001  # UDP broadcast port shared by all instances
DEVICE_UUID  = str(_uuid_mod.uuid4())  # unique ID for this process run
peers        = {}    # {uuid: {name, ip, port, last_seen}}
peers_lock   = threading.Lock()

def _get_local_ip():
    """Return the machine's primary LAN IP (best-effort)."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"

def _beacon_sender():
    """Broadcast a JSON presence packet every 3 s so peers can discover us."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    while True:
        try:
            pkt = json.dumps({
                "type": "morse_pi_beacon",
                "uuid": DEVICE_UUID,
                "name": settings.get("device_name", "Morse Pi"),
                "ip":   _get_local_ip(),
                "port": 5000,
            }).encode()
            sock.sendto(pkt, ("255.255.255.255", BEACON_PORT))
        except Exception:
            pass
        time.sleep(3)

def _beacon_listener():
    """Listen for broadcast beacons and maintain the peers table."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except AttributeError:
        pass  # Windows lacks SO_REUSEPORT — not needed
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        sock.bind(("", BEACON_PORT))
    except Exception as e:
        print(f"[net] beacon bind failed: {e}")
        return
    sock.settimeout(2.0)
    while True:
        try:
            data, addr = sock.recvfrom(2048)
            pkt = json.loads(data.decode())
            if pkt.get("type") != "morse_pi_beacon":
                continue
            uid = pkt.get("uuid")
            if not uid or uid == DEVICE_UUID:
                continue  # ignore our own beacon
            with peers_lock:
                peers[uid] = {
                    "name":      pkt.get("name", "Unknown"),
                    "ip":        pkt.get("ip",   addr[0]),
                    "port":      int(pkt.get("port", 5000)),
                    "last_seen": time.time(),
                }
        except socket.timeout:
            pass
        except Exception:
            pass
        # Expire peers not seen for 15 s
        now = time.time()
        with peers_lock:
            expired = [u for u, p in list(peers.items()) if now - p["last_seen"] > 15]
            for u in expired:
                del peers[u]

# --- App ---
app = Flask(__name__)
lock = threading.Lock()
app.jinja_env.auto_reload = True
old_get_source = app.jinja_env.loader.get_source
def tolerant_get_source(environment, template):
    contents, filename, uptodate = old_get_source(environment, template)
    # Replace invalid bytes
    contents = contents.encode('utf-8', errors='replace').decode('utf-8')
    return contents, filename, uptodate
app.jinja_env.loader.get_source = tolerant_get_source

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
    "net_inbox": [],      # list of received Morse messages
    "net_morse_buffer": "",    # buffer for key-based network sending
    "net_morse_output": "",    # decoded text from key input for network
    "net_key_mode": False,     # True when using key to compose network message
    "kb_output": "",           # buffer showing what keyboard mode has typed
}

pin_states = {}  # {bcm: bool} live state updated by poll thread + callbacks

# --- Diagnostic GPIO helpers ---
ALL_BCM_PINS = [2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27]
_diag_readers  = {}   # {bcm: InputDevice | None} for non-managed pins
gpio_error_log = []   # list of error strings, newest at end

def _managed_bcm_set():
    """Return the set of BCM pins currently owned by active Button/PWMOutput/OutputDevice."""
    s = set()
    sp = settings.get("speaker_pin")
    gp = settings.get("ground_pin")
    grounded = settings.get("grounded_pins", [])
    if sp is not None: s.add(int(sp))
    if gp is not None: s.add(int(gp))
    for pin in grounded:
        if pin is not None: s.add(int(pin))
    if settings.get("pin_mode") == "dual":
        dp = settings.get("dot_pin");  da = settings.get("dash_pin")
        if dp  is not None: s.add(int(dp))
        if da  is not None: s.add(int(da))
    else:
        dp = settings.get("data_pin")
        if dp is not None: s.add(int(dp))
    return s

def init_diag_readers():
    """Open InputDevice for every BCM pin not managed by Button/PWMOutput."""
    global _diag_readers
    if not GPIO_AVAILABLE:
        return
    managed = _managed_bcm_set()
    # Close any stale readers that are now managed (would conflict)
    for bcm in list(_diag_readers.keys()):
        if bcm in managed:
            dev = _diag_readers.pop(bcm)
            if dev:
                try: dev.close()
                except: pass
    # Open readers for unmanaged pins
    for bcm in ALL_BCM_PINS:
        if bcm in managed:
            continue
        if bcm not in _diag_readers:
            try:
                _diag_readers[bcm] = InputDevice(bcm, pull_up=True)
            except Exception as e:
                msg = f"BCM {bcm}: {e}"
                gpio_error_log.append(msg)
                _diag_readers[bcm] = None

def get_all_pin_states():
    """Return {bcm_str: {active: bool|None, role: str}} for all BCM 2-27."""
    if not GPIO_AVAILABLE:
        return {}
    pm = settings.get("pin_mode", "single")
    sp = settings.get("speaker_pin")
    dp = settings.get("data_pin")
    dop = settings.get("dot_pin")
    dap = settings.get("dash_pin")
    gp  = settings.get("ground_pin")
    grounded = settings.get("grounded_pins", [])
    result = {}
    for bcm in ALL_BCM_PINS:
        if bcm == sp:
            result[str(bcm)] = {"active": None, "role": "speaker"}
        elif bcm == gp or bcm in grounded:
            result[str(bcm)] = {"active": None, "role": "ground"}
        elif pm == "dual" and bcm == dop:
            result[str(bcm)] = {"active": dot_btn.is_pressed  if dot_btn  else None, "role": "dot"}
        elif pm == "dual" and bcm == dap:
            result[str(bcm)] = {"active": dash_btn.is_pressed if dash_btn else None, "role": "dash"}
        elif pm != "dual" and bcm == dp:
            result[str(bcm)] = {"active": data_btn.is_pressed if data_btn else None, "role": "data"}
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

def _pin_poll_worker():
    """Background thread: update pin_states every 50 ms from Button.is_pressed."""
    while True:
        try:
            pm = settings.get("pin_mode", "single")
            if pm == "dual":
                dp  = settings.get("dot_pin");  da = settings.get("dash_pin")
                if dot_btn  and dp  is not None: pin_states[int(dp)]  = dot_btn.is_pressed
                if dash_btn and da  is not None: pin_states[int(da)]  = dash_btn.is_pressed
            else:
                dp = settings.get("data_pin")
                if data_btn and dp is not None:  pin_states[int(dp)]  = data_btn.is_pressed
        except Exception:
            pass
        time.sleep(0.05)

if GPIO_AVAILABLE:
    threading.Thread(target=_pin_poll_worker, daemon=True).start()

# --- GPIO Setup ---
beeper     = None
data_btn   = None
dot_btn    = None
dash_btn   = None
ground_out = None  # OutputDevice held LOW to act as a GND pin
grounded_outputs = []  # List of OutputDevices for grounded_pins

# ── USB HID Keyboard ─────────────────────────────────────────────────────────
USB_HID_DEVICE = "/dev/hidg0"
USB_HID_AVAILABLE = False

# USB HID keyboard scan codes (lowercase letters, numbers, common symbols)
HID_KEYCODES = {
    'a': 0x04, 'b': 0x05, 'c': 0x06, 'd': 0x07, 'e': 0x08, 'f': 0x09,
    'g': 0x0a, 'h': 0x0b, 'i': 0x0c, 'j': 0x0d, 'k': 0x0e, 'l': 0x0f,
    'm': 0x10, 'n': 0x11, 'o': 0x12, 'p': 0x13, 'q': 0x14, 'r': 0x15,
    's': 0x16, 't': 0x17, 'u': 0x18, 'v': 0x19, 'w': 0x1a, 'x': 0x1b,
    'y': 0x1c, 'z': 0x1d,
    '1': 0x1e, '2': 0x1f, '3': 0x20, '4': 0x21, '5': 0x22,
    '6': 0x23, '7': 0x24, '8': 0x25, '9': 0x26, '0': 0x27,
    ' ': 0x2c,  # space
    '.': 0x37, ',': 0x36, '/': 0x38, '-': 0x2d, '=': 0x2e,
    '?': 0x38,  # ? is shift+/
    "'": 0x34, '"': 0x34,  # quotes
}

# Check if USB HID device exists
def _check_usb_hid():
    global USB_HID_AVAILABLE
    USB_HID_AVAILABLE = os.path.exists(USB_HID_DEVICE)
    return USB_HID_AVAILABLE

def _hid_send_key(char):
    """Send a single character as a USB HID keystroke."""
    if not settings.get("kb_enabled", False):
        return False
    if not _check_usb_hid():
        return False
    
    char_lower = char.lower()
    keycode = HID_KEYCODES.get(char_lower)
    if keycode is None:
        return False
    
    # Determine if shift is needed (uppercase letter or special chars)
    modifier = 0x00
    if char.isupper() or char in '?!"':
        modifier = 0x02  # Left Shift
    
    try:
        # HID report: modifier, reserved, keycode1-6
        report = bytes([modifier, 0x00, keycode, 0x00, 0x00, 0x00, 0x00, 0x00])
        release = bytes([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        
        with open(USB_HID_DEVICE, 'rb+') as fd:
            fd.write(report)
            fd.flush()
            time.sleep(0.02)  # Brief delay between press and release
            fd.write(release)
            fd.flush()
        return True
    except Exception as e:
        print(f"USB HID error: {e}")
        return False

def _hid_send_string(text):
    """Send a string as USB HID keystrokes."""
    for char in text:
        _hid_send_key(char)
        time.sleep(0.01)

def _hid_send_custom_key(key_char):
    """Send a custom key (for paddle-to-key mapping in custom mode)."""
    if not settings.get("kb_enabled", False):
        return False
    
    # Handle special key names
    if key_char.lower() == 'space' or key_char == ' ':
        return _hid_send_key(' ')
    
    return _hid_send_key(key_char)

# Check USB HID availability at startup
_check_usb_hid()

# ── Iambic Keyer ─────────────────────────────────────────────────────────────
_KEYER_IDLE = 'IDLE'
_KEYER_DOT  = 'SENDING_DOT'
_KEYER_DASH = 'SENDING_DASH'
_KEYER_GAP  = 'INTER_ELEMENT_GAP'

keyer_state_label = _KEYER_IDLE
_keyer_stop       = threading.Event()
_keyer_thread_ref = None   # type: threading.Thread | None

# Virtual paddle state – driven by the /key_press_dual browser route so
# keyboard / on-screen button events go through the same keyer logic as
# physical GPIO paddles.
_virtual_dot  = False
_virtual_dash = False
_virtual_dot_timer  = None   # auto-release watchdog to prevent stuck keys
_virtual_dash_timer = None


def _auto_release_virtual_key(sym):
    """Safety net: auto-release a virtual key if the browser never sent a keyup.
    Prevents Z/X from getting stuck pressed due to network race conditions."""
    global _virtual_dot, _virtual_dash
    if sym == 'dot':
        _virtual_dot = False
    elif sym == 'dash':
        _virtual_dash = False


def _get_dot_unit():
    """Dot element duration in seconds: 1200 ms / WPM."""
    wpm = max(5, int(settings.get('wpm_target', 20)))
    return 1.2 / wpm


def _get_letter_gap_secs():
    """Letter gap in seconds.  Standard = 3 dot units.
    Farnsworth mode multiplies it so learners get extra time between characters."""
    du = _get_dot_unit()
    if settings.get('farnsworth_enabled'):
        mult = max(1.0, float(settings.get('farnsworth_letter_mult', 2.0)))
        return du * 3 * mult
    return du * 3


def _get_word_extra_secs():
    """Extra gap beyond the letter gap at word boundaries.
    Standard = 4 dot units (total word gap = 3+4 = 7 units).
    Farnsworth mode multiplies this extra portion."""
    du = _get_dot_unit()
    if settings.get('farnsworth_enabled'):
        mult = max(1.0, float(settings.get('farnsworth_word_mult', 2.0)))
        return du * 4 * mult
    return du * 4


def _keyer_emit(sym):
    """Append '.' or '-' into the buffer for the currently active mode."""
    mode = state.get('mode', 'send')
    if mode == 'speed':
        speed_buffer.append(sym)
        state['speed_morse_buffer'] = ''.join(speed_buffer)
    else:
        send_buffer.append(sym)
        state['current_morse_buffer'] = ''.join(send_buffer)


def _keyer_do_finalize_letter():
    """Decode the accumulated buffer and commit the character to output."""
    mode = state.get('mode', 'send')
    if mode == 'speed':
        if speed_buffer:
            code = ''.join(speed_buffer)
            state['speed_morse_output'] += code + ' '
            state['speed_morse_buffer']  = ''
            speed_buffer.clear()
    else:
        if send_buffer:
            code = ''.join(send_buffer)
            rev  = {v: k for k, v in MORSE_CODE.items()}
            char = rev.get(code, '?')
            state['send_output']          += char
            state['current_morse_buffer']  = ''
            send_buffer.clear()
            
            # USB HID Keyboard: send character if enabled in letters mode
            if settings.get("kb_enabled", False) and settings.get("kb_mode", "letters") == "letters":
                _hid_send_key(char)
                state['kb_output'] = (state.get('kb_output', '') + char)[-100:]  # Keep last 100 chars


def _keyer_do_finalize_word():
    """Append a word separator to the active mode output."""
    mode = state.get('mode', 'send')
    if mode == 'speed':
        out = state['speed_morse_output']
        if out and not out.rstrip().endswith('/'):
            state['speed_morse_output'] = out.rstrip() + ' / '
    else:
        out = state['send_output']
        if out and not out.endswith(' '):
            state['send_output'] += ' '
            
            # USB HID Keyboard: send space if enabled in letters mode
            if settings.get("kb_enabled", False) and settings.get("kb_mode", "letters") == "letters":
                _hid_send_key(' ')
                state['kb_output'] = (state.get('kb_output', '') + ' ')[-100:]


def _iambic_keyer_worker():
    """
    Electronic iambic keyer – Type A state machine.

    Runs in a dedicated daemon thread; polls Button.is_pressed at ~1 ms so
    it never blocks the Flask web-server threads.  Supports:

      * Continuous dots while dot paddle held.
      * Continuous dashes while dash paddle held.
      * Squeeze (both held): alternates dot/dash starting from whichever
        was NOT sent last.
      * Paddle memory: if the opposite paddle is pressed during an element,
        that element is queued as the next one to send.

    Timing (all derived from WPM setting):
      dot   = 1 unit = 1200 ms / WPM
      dash  = 3 units
      inter-element gap = 1 unit
      letter gap        = 3 units  (1 inter-element + 2 more)
      word gap          = 7 units  (3 letter + 4 more)
    """
    global keyer_state_label
    dot_memory  = False   # dash paddle pressed during a dot – queue dash next
    dash_memory = False   # dot  paddle pressed during a dash – queue dot next
    last_sym    = None    # 'dot' | 'dash' – governs squeeze alternation

    while not _keyer_stop.is_set():
        du     = _get_dot_unit()
        dot_p  = bool((dot_btn  and dot_btn.is_pressed)  or _virtual_dot)
        dash_p = bool((dash_btn and dash_btn.is_pressed) or _virtual_dash)

        # ── IDLE ──────────────────────────────────────────────────────────────
        if not dot_p and not dash_p and not dot_memory and not dash_memory:
            keyer_state_label      = _KEYER_IDLE
            state['button_active'] = False
            time.sleep(0.001)
            continue

        state['button_active'] = True

        # ── Decide next element ────────────────────────────────────────────────
        if dot_memory and not dash_p:
            sym        = 'dot'
            dot_memory = False
        elif dash_memory and not dot_p:
            sym         = 'dash'
            dash_memory = False
        elif dot_p and dash_p:
            # Squeeze: alternate from whatever was sent last
            sym = 'dash' if last_sym == 'dot' else 'dot'
        elif dot_p:
            sym = 'dot'
        else:
            sym = 'dash'

        last_sym = sym

        # ── SEND DOT ──────────────────────────────────────────────────────────
        if sym == 'dot':
            keyer_state_label = _KEYER_DOT
            _keyer_emit('.')
            pin_states[settings.get('dot_pin', 22)] = True
            play_tone(settings['dot_freq'])
            
            # USB HID Keyboard: send custom dot key immediately in custom mode
            if settings.get("kb_enabled", False) and settings.get("kb_mode") == "custom":
                key_char = settings.get("kb_dot_key", "z")
                if _hid_send_custom_key(key_char):
                    display_char = ' ' if key_char == 'space' else key_char
                    state['kb_output'] = (state.get('kb_output', '') + display_char)[-100:]
            
            end = time.time() + du
            opp = False
            while time.time() < end and not _keyer_stop.is_set():
                if (dash_btn and dash_btn.is_pressed) or _virtual_dash:
                    opp = True
                time.sleep(0.001)
            stop_tone()
            pin_states[settings.get('dot_pin', 22)] = False
            if opp:
                dash_memory = True

        # ── SEND DASH ─────────────────────────────────────────────────────────
        else:
            keyer_state_label = _KEYER_DASH
            _keyer_emit('-')
            pin_states[settings.get('dash_pin', 27)] = True
            play_tone(settings['dash_freq'])
            
            # USB HID Keyboard: send custom dash key immediately in custom mode
            if settings.get("kb_enabled", False) and settings.get("kb_mode") == "custom":
                key_char = settings.get("kb_dash_key", "x")
                if _hid_send_custom_key(key_char):
                    display_char = ' ' if key_char == 'space' else key_char
                    state['kb_output'] = (state.get('kb_output', '') + display_char)[-100:]
            
            end = time.time() + du * 3
            opp = False
            while time.time() < end and not _keyer_stop.is_set():
                if (dot_btn and dot_btn.is_pressed) or _virtual_dot:
                    opp = True
                time.sleep(0.001)
            stop_tone()
            pin_states[settings.get('dash_pin', 27)] = False
            if opp:
                dot_memory = True

        # ── INTER-ELEMENT GAP (1 dot unit) ────────────────────────────────────
        keyer_state_label = _KEYER_GAP
        end = time.time() + du
        while time.time() < end and not _keyer_stop.is_set():
            if (dot_btn  and dot_btn.is_pressed)  or _virtual_dot:  dot_memory  = True
            if (dash_btn and dash_btn.is_pressed) or _virtual_dash: dash_memory = True
            time.sleep(0.001)

        # ── Letter / word gap ─────────────────────────────────────────────────
        dot_p  = bool((dot_btn  and dot_btn.is_pressed)  or _virtual_dot)
        dash_p = bool((dash_btn and dash_btn.is_pressed) or _virtual_dash)
        if not dot_p and not dash_p and not dot_memory and not dash_memory:
            keyer_state_label = _KEYER_IDLE
            # After the 1-unit inter-element gap, wait the remainder of the
            # Farnsworth-aware letter gap (standard = 2 more units, but
            # Farnsworth multiplier stretches this proportionally).
            letter_remain = max(0.0, _get_letter_gap_secs() - du)
            t0 = time.time()
            while time.time() - t0 < letter_remain and not _keyer_stop.is_set():
                if (dot_btn  and dot_btn.is_pressed) or _virtual_dot or \
                   (dash_btn and dash_btn.is_pressed) or _virtual_dash:
                    break
                time.sleep(0.001)
            else:
                _keyer_do_finalize_letter()
                # Extra gap beyond the letter gap for word boundaries.
                # Farnsworth multiplier applies here too.
                word_extra = _get_word_extra_secs()
                t0 = time.time()
                while time.time() - t0 < word_extra and not _keyer_stop.is_set():
                    if (dot_btn  and dot_btn.is_pressed) or _virtual_dot or \
                       (dash_btn and dash_btn.is_pressed) or _virtual_dash:
                        break
                    time.sleep(0.001)
                else:
                    _keyer_do_finalize_word()


def _start_keyer_thread():
    """Start a fresh iambic keyer thread (stops any running one first)."""
    global _keyer_thread_ref
    _keyer_stop.clear()
    _keyer_thread_ref = threading.Thread(
        target=_iambic_keyer_worker, name='iambic_keyer', daemon=True
    )
    _keyer_thread_ref.start()


def _stop_keyer_thread():
    """Signal the keyer thread to stop and wait up to 0.5 s."""
    _keyer_stop.set()
    if _keyer_thread_ref and _keyer_thread_ref.is_alive():
        _keyer_thread_ref.join(timeout=0.5)


def init_gpio():
    global beeper, data_btn, dot_btn, dash_btn, ground_out, grounded_outputs
    if not GPIO_AVAILABLE:
        return
    try:
        for dev in [beeper, data_btn, dot_btn, dash_btn, ground_out]:
            if dev:
                try: dev.close()
                except: pass
        # Close any existing grounded outputs
        for dev in grounded_outputs:
            if dev:
                try: dev.close()
                except: pass
        grounded_outputs = []
        
        beeper = PWMOutputDevice(
            settings["speaker_pin"],
            frequency=max(1, int(settings["dot_freq"])),
            initial_value=0
        )
        # Ground output pin (legacy single pin): drive LOW so paddle common wire works on a GPIO pin
        gp = settings.get("ground_pin")
        if gp is not None:
            ground_out = OutputDevice(gp, initial_value=False)
        else:
            ground_out = None
        
        # Handle grounded_pins array - each pin is driven LOW as a ground source
        grounded = settings.get("grounded_pins", [])
        for pin in grounded:
            if pin is not None:
                try:
                    gnd_dev = OutputDevice(int(pin), initial_value=False)
                    grounded_outputs.append(gnd_dev)
                except Exception as e:
                    msg = f"ground pin {pin}: {e}"
                    gpio_error_log.append(msg)
        
        if settings.get("pin_mode") == "dual":
            # 5 ms hardware debounce; keyer thread polls is_pressed directly
            dot_btn  = Button(settings["dot_pin"],  pull_up=True, bounce_time=0.005)
            dash_btn = Button(settings["dash_pin"], pull_up=True, bounce_time=0.005)
            _start_keyer_thread()
        else:
            if state["mode"] == "speed":
                data_btn = Button(settings["data_pin"], pull_up=True, bounce_time=0.05)
                data_btn.when_pressed  = speed_button_pressed
                data_btn.when_released = speed_button_released
            else:
                data_btn = Button(settings["data_pin"], pull_up=True, bounce_time=0.05)
                data_btn.when_pressed  = send_button_pressed
                data_btn.when_released = send_button_released
    except Exception as e:
        msg = f"init_gpio: {e}"
        print(msg)
        gpio_error_log.append(msg)

def recreate_gpio():
    global _virtual_dot, _virtual_dash
    _stop_keyer_thread()          # halt any running iambic keyer
    _virtual_dot = _virtual_dash = False  # reset browser-simulated paddles
    init_gpio()
    init_diag_readers()

def play_tone(freq, duration=None, duty=None):
    if beeper:
        with lock:
            try:
                vol = float(duty) if duty is not None else settings["volume"]
                output_type = settings.get("output_type", "speaker")
                
                if output_type == "led":
                    # LED mode: just turn on (high) for the duration
                    beeper.frequency = 1000  # doesn't matter for LED
                    beeper.value = 1.0  # full on
                else:
                    # Speaker mode: use PWM with frequency for audio
                    # Clamp volume to usable PWM range; very low duty cycles
                    # produce no audible tone on Pi hardware, and 1.0 is a flat
                    # DC level (no oscillation = silence on piezo/speaker).
                    vol = max(0.01, min(0.95, vol))
                    beeper.frequency = max(100, min(4000, int(freq)))
                    beeper.value = vol
                
                if duration:
                    time.sleep(duration)
                    beeper.value = 0
            except Exception:
                pass

def stop_tone():
    if beeper:
        try:
            beeper.value = 0
        except Exception:
            pass

def _play_morse_string(text):
    """Play plaintext as Morse code using proper WPM-based timing.

    Timing (all derived from WPM):
      dot   = 1 unit
      dash  = 3 units
      inter-element gap = 1 unit
      letter gap = 3 units
      word gap   = 7 units
    """
    du = _get_dot_unit()
    chars = text.upper()
    for i, char in enumerate(chars):
        if char == ' ':
            # Word boundary: letter gap already elapsed, add Farnsworth-aware extra
            time.sleep(_get_word_extra_secs())
            continue
        code = MORSE_CODE.get(char)
        if not code or code == '/':
            continue
        for j, sym in enumerate(code):
            if sym == '.':
                play_tone(settings["dot_freq"], du)
            elif sym == '-':
                play_tone(settings["dash_freq"], du * 3)
            # Inter-element gap (1 unit) between symbols within a character
            if j < len(code) - 1:
                time.sleep(du)
        # Letter gap after each character (Farnsworth-aware)
        if i < len(chars) - 1:
            time.sleep(_get_letter_gap_secs())
    stop_tone()

# --- Send Mode Logic ---
send_buffer = []
send_active = False
send_press_time = 0
send_gap_timer = None
send_force_timer = None

def send_button_pressed():
    global send_active, send_press_time, send_gap_timer, send_force_timer
    send_active = True
    send_press_time = time.time()
    state["button_active"] = True
    pin_states[settings.get("data_pin", 17)] = True
    if send_gap_timer:
        send_gap_timer.cancel()
    if send_force_timer:
        send_force_timer.cancel()
    play_tone(settings["dot_freq"], duty=settings["volume"])

def send_button_released():
    global send_active, send_buffer, send_gap_timer, send_force_timer
    send_active = False
    state["button_active"] = False
    pin_states[settings.get("data_pin", 17)] = False
    stop_tone()
    duration = time.time() - send_press_time
    # Straight-key threshold: press shorter than 2 dot units → dot, else dash.
    # dot unit = 1200 ms / WPM keeps timing consistent with iambic mode.
    symbol = '.' if duration < _get_dot_unit() * 2 else '-'
    send_buffer.append(symbol)
    state["current_morse_buffer"] = ''.join(send_buffer)
    
    # USB HID Keyboard: send custom key immediately in custom mode (single-pin)
    if settings.get("kb_enabled", False) and settings.get("kb_mode") == "custom":
        key_char = settings.get("kb_dot_key" if symbol == '.' else "kb_dash_key", "z")
        if _hid_send_custom_key(key_char):
            display_char = ' ' if key_char == 'space' else key_char
            state['kb_output'] = (state.get('kb_output', '') + display_char)[-100:]
    
    # Cancel previous timer, start new letter-gap timer (Farnsworth-aware)
    if send_gap_timer:
        send_gap_timer.cancel()
    send_gap_timer = threading.Timer(_get_letter_gap_secs(), finalize_letter)
    send_gap_timer.start()
    # Start force finalize timer (a little beyond the letter gap)
    if send_force_timer:
        send_force_timer.cancel()
    send_force_timer = threading.Timer(_get_letter_gap_secs() + _get_dot_unit() * 2, force_finalize_letter)
    send_force_timer.start()

def finalize_letter():
    global send_buffer, send_gap_timer, send_force_timer
    if not send_active and send_buffer:
        code = ''.join(send_buffer)
        rev = {v: k for k, v in MORSE_CODE.items()}
        char = rev.get(code, '?')
        state["send_output"] += char
        state["current_morse_buffer"] = ""
        send_buffer.clear()
        
        # USB HID Keyboard: send decoded letter in letters mode (single-pin)
        if settings.get("kb_enabled", False) and settings.get("kb_mode", "letters") == "letters":
            _hid_send_key(char)
            state['kb_output'] = (state.get('kb_output', '') + char)[-100:]
        
        # Start word gap timer (Farnsworth-aware)
        send_gap_timer = threading.Timer(_get_word_extra_secs(), finalize_word)
        send_gap_timer.start()
        # Update force timer
        if send_force_timer:
            send_force_timer.cancel()
        send_force_timer = threading.Timer(_get_word_extra_secs() + _get_dot_unit() * 2, force_finalize_word)
        send_force_timer.start()

def finalize_word():
    global send_buffer
    if not send_active:
        if state["send_output"] and not state["send_output"].endswith(' '):
            state["send_output"] += ' '
            
            # USB HID Keyboard: send space in letters mode (single-pin)
            if settings.get("kb_enabled", False) and settings.get("kb_mode", "letters") == "letters":
                _hid_send_key(' ')
                state['kb_output'] = (state.get('kb_output', '') + ' ')[-100:]

def force_finalize_letter():
    finalize_letter()

def force_finalize_word():
    finalize_word()

# --- Speed Mode Logic ---
speed_buffer = []
speed_active = False
speed_press_time = 0
speed_gap_timer = None
speed_force_timer = None

def speed_button_pressed():
    global speed_active, speed_press_time, speed_gap_timer, speed_force_timer
    speed_active = True
    speed_press_time = time.time()
    state["button_active"] = True
    pin_states[settings.get("data_pin", 17)] = True
    if speed_gap_timer:
        speed_gap_timer.cancel()
    if speed_force_timer:
        speed_force_timer.cancel()
    play_tone(settings["dot_freq"], duty=settings["volume"])

def speed_button_released():
    global speed_active, speed_buffer, speed_gap_timer, speed_force_timer
    speed_active = False
    state["button_active"] = False
    pin_states[settings.get("data_pin", 17)] = False
    stop_tone()
    duration = time.time() - speed_press_time
    # Same WPM-derived threshold as send mode.
    symbol = '.' if duration < _get_dot_unit() * 2 else '-'
    speed_buffer.append(symbol)
    state["speed_morse_buffer"] = ''.join(speed_buffer)
    if speed_gap_timer:
        speed_gap_timer.cancel()
    speed_gap_timer = threading.Timer(_get_letter_gap_secs(), speed_finalize_letter)
    speed_gap_timer.start()
    if speed_force_timer:
        speed_force_timer.cancel()
    speed_force_timer = threading.Timer(_get_letter_gap_secs() + _get_dot_unit() * 2, speed_force_finalize_letter)
    speed_force_timer.start()

def speed_finalize_letter():
    global speed_buffer, speed_gap_timer, speed_force_timer
    if not speed_active and speed_buffer:
        code = ''.join(speed_buffer)
        state["speed_morse_output"] += code + ' '
        state["speed_morse_buffer"] = ""
        speed_buffer.clear()
        # Start word gap timer (Farnsworth-aware)
        speed_gap_timer = threading.Timer(_get_word_extra_secs(), speed_finalize_word)
        speed_gap_timer.start()
        if speed_force_timer:
            speed_force_timer.cancel()
        speed_force_timer = threading.Timer(_get_word_extra_secs() + _get_dot_unit() * 2, speed_force_finalize_word)
        speed_force_timer.start()

def speed_finalize_word():
    global speed_buffer
    if not speed_active:
        if state["speed_morse_output"] and not state["speed_morse_output"].endswith('/'):
            state["speed_morse_output"] += '/ '

def speed_force_finalize_letter():
    speed_finalize_letter()

def speed_force_finalize_word():
    speed_finalize_word()

# --- Dual-Pin Paddle Callbacks ---
# NOTE: In iambic (dual) mode the _iambic_keyer_worker thread handles all
# element generation by polling Button.is_pressed directly.  These stubs are
# kept only so that any legacy references do not raise NameError; they are
# never attached as gpiozero callbacks.
def dual_dot_pressed():  pass
def dual_dot_released(): pass
def dual_dash_pressed(): pass
def dual_dash_released(): pass

# --- Load Words ---
def load_words():
    if os.path.exists("words.json"):
        with open("words.json", "r") as f:
            return json.load(f)
    # Fallback built-in word lists
    return {
        "article": ["the", "a", "an"],
        "adjective": ["quick", "slow", "bright", "dark", "swift"],
        "noun": ["fox", "dog", "cat", "bird", "tree"],
        "verb": ["jumps", "runs", "flies", "sits", "leaps"],
        "adverb": ["quickly", "slowly", "boldly"],
        "preposition": ["over", "under", "through", "past"]
    }

words = load_words()

def random_phrase(difficulty="medium"):
    parts = []
    if difficulty == "easy":
        candidates = words.get("nouns", []) + words.get("verbs", [])
        if candidates:
            return random.choice(candidates).upper()
        return "TEST".upper()
    elif difficulty == "medium":
        for cat in ["adjectives", "nouns"]:
            if cat in words and words[cat]:
                parts.append(random.choice(words[cat]))
    else: # hard
        for cat in ["articles", "adjectives", "nouns", "verbs", "adverbs"]:
            if cat in words and words[cat]:
                parts.append(random.choice(words[cat]))
    if not parts:
        return "THE QUICK FOX"
    return ' '.join(parts).upper()

def morse_encode(text):
    return ' '.join(MORSE_CODE.get(c.upper(), '') for c in text if c.upper() in MORSE_CODE or c == ' ')

def morse_decode(morse):
    rev = {v: k for k, v in MORSE_CODE.items()}
    return ''.join(rev.get(code, '?') for code in morse.split())

# --- Routes ---
@app.route("/")
def index():
    return render_template("index.html", state=state, settings=settings, morse_code=MORSE_CODE)

@app.route("/status")
def status():
    return jsonify({
        **state,
        "gpio_available": GPIO_AVAILABLE,
        "pin_states": pin_states,
        "keyer_state": keyer_state_label,
        "kb_enabled": settings.get("kb_enabled", False),
        "kb_mode": settings.get("kb_mode", "letters"),
        "kb_dot_key": settings.get("kb_dot_key", "z"),
        "kb_dash_key": settings.get("kb_dash_key", "x"),
        "usb_hid_available": USB_HID_AVAILABLE,
    })

@app.route("/diag")
def diag():
    return render_template("diag.html", settings=settings, gpio_available=GPIO_AVAILABLE)

@app.route("/gpio_poll")
def gpio_poll():
    return jsonify({
        "gpio_available": GPIO_AVAILABLE,
        "gpio_error":     GPIO_ERROR,
        "pin_mode":       settings.get("pin_mode", "single"),
        "output_type":    settings.get("output_type", "speaker"),
        "data_pin":       settings.get("data_pin"),
        "dot_pin":        settings.get("dot_pin"),
        "dash_pin":       settings.get("dash_pin"),
        "speaker_pin":    settings.get("speaker_pin"),
        "ground_pin":     settings.get("ground_pin"),
        "grounded_pins":  settings.get("grounded_pins", []),
        "states":         get_all_pin_states(),
        "errors":         gpio_error_log[-20:],
        "timestamp":      time.time()
    })

@app.route("/gpio_reinit", methods=["POST"])
def gpio_reinit():
    gpio_error_log.clear()
    if GPIO_ERROR:
        gpio_error_log.append(f"Import error: {GPIO_ERROR}")
    else:
        recreate_gpio()
    return jsonify({"ok": True, "errors": gpio_error_log})

@app.route("/set_mode", methods=["POST"])
def set_mode():
    mode = request.json.get("mode")
    if mode in ["send", "encode", "decode", "speed", "settings", "stats", "network"]:
        state["mode"] = mode
        if mode == "decode":
            phrase = random_phrase(settings.get("difficulty", "medium"))
            state["current_phrase"] = phrase
            state["decode_result"] = ""
        elif mode == "speed":
            state["speed_phrase"] = random_phrase(settings.get("difficulty", "medium"))
            state["speed_result"] = ""
            state["speed_morse_buffer"] = ""
            state["speed_morse_output"] = ""
            recreate_gpio()
        elif mode == "send":
            recreate_gpio()
    return jsonify(state)

@app.route("/encode", methods=["POST"])
def encode():
    text = request.json.get("text", "")
    state["encode_input"] = text
    state["encode_output"] = morse_encode(text)
    return jsonify({"morse": state["encode_output"]})

@app.route("/play", methods=["POST"])
def play():
    text = state.get("encode_input", "")
    def _play():
        _play_morse_string(text)
    threading.Thread(target=_play, daemon=True).start()
    return jsonify({"status": "playing"})

@app.route("/play_phrase", methods=["POST"])
def play_phrase():
    """Play the current decode quiz phrase as audio hint."""
    text = state.get("current_phrase", "")
    def _play():
        _play_morse_string(text)
    threading.Thread(target=_play, daemon=True).start()
    return jsonify({"status": "playing"})

@app.route("/wpm_test", methods=["POST"])
def wpm_test():
    """Play the word PARIS at current WPM so the user can verify speed."""
    def _play():
        _play_morse_string("PARIS")
    threading.Thread(target=_play, daemon=True).start()
    return jsonify({"status": "playing", "wpm": settings.get("wpm_target", 20)})

@app.route("/save_settings", methods=["POST"])
def save_settings_route():
    data = request.json or {}
    COERCE_INT          = {"speaker_pin", "data_pin", "dot_pin", "dash_pin", "dot_freq", "dash_freq", "wpm_target"}
    COERCE_NULLABLE_INT = {"ground_pin"}
    COERCE_FLOAT = {"volume", "farnsworth_letter_mult", "farnsworth_word_mult"}
    COERCE_BOOL  = {"use_external_switch", "farnsworth_enabled", "kb_enabled"}
    
    # If no data provided, just return current settings (no-op)
    if not data:
        return jsonify(settings)
    
    for k, v in data.items():
        if k in COERCE_NULLABLE_INT:
            settings[k] = int(v) if v is not None else None
        elif k in COERCE_INT:
            try: settings[k] = int(v)
            except: pass
        elif k in COERCE_FLOAT:
            try: settings[k] = float(v)
            except: pass
        elif k in COERCE_BOOL:
            settings[k] = bool(v) if not isinstance(v, bool) else v
        elif isinstance(DEFAULT_SETTINGS.get(k), int):
            try: settings[k] = int(v)
            except: settings[k] = v
        elif isinstance(DEFAULT_SETTINGS.get(k), float):
            try: settings[k] = float(v)
            except: settings[k] = v
        else:
            settings[k] = v
    save_settings_to_file(settings)
    recreate_gpio()
    return jsonify(settings)

@app.route("/preview_tone", methods=["POST"])
def preview_tone():
    freq = int(request.json.get("freq", settings["dot_freq"]))
    duration = float(request.json.get("duration", _get_dot_unit()))
    duty = float(request.json.get("duty", settings["volume"]))
    def _preview():
        play_tone(freq, duration, duty)
        stop_tone()
    threading.Thread(target=_preview, daemon=True).start()
    return jsonify({"status": "previewed"})

@app.route("/decode_submit", methods=["POST"])
def decode_submit():
    answer = request.json.get("answer", "").strip().upper()
    correct_phrase = state["current_phrase"].strip().upper()
    correct = answer == correct_phrase
    state["stats"]["total_attempts"] += 1
    if correct:
        state["stats"]["correct"] += 1
        state["stats"]["streak"] += 1
        if state["stats"]["streak"] > state["stats"]["best_streak"]:
            state["stats"]["best_streak"] = state["stats"]["streak"]
        result = "correct"
    else:
        state["stats"]["streak"] = 0
        result = "wrong"
    state["decode_result"] = result
    state["decode_correct_answer"] = correct_phrase
    save_stats_to_file()
    return jsonify({
        "result": result,
        "correct_answer": correct_phrase,
        "stats": state["stats"]
    })

@app.route("/submit_test", methods=["POST"])
def submit_test():
    # Now we ignore the json "input" field — use server-side buffer instead
    input_morse = state["speed_morse_output"].strip()
    elapsed = request.json.get("elapsed", 1)
    if not input_morse:
        state["speed_result"] = "no_input"
        return jsonify({"result": "no_input"})
    decoded = morse_decode(input_morse).strip().upper()
    expected = state["speed_phrase"].strip().upper()

    # Character-by-character accuracy comparison
    char_results = []
    max_len = max(len(expected), len(decoded))
    correct_count = 0
    for i in range(max_len):
        exp_c = expected[i] if i < len(expected) else ''
        got_c = decoded[i] if i < len(decoded) else ''
        is_match = (exp_c == got_c and exp_c != '')
        if is_match:
            correct_count += 1
        char_results.append({"expected": exp_c, "got": got_c, "correct": is_match})
    accuracy = round((correct_count / len(expected)) * 100) if expected else 0
    perfect = (decoded == expected)

    chars_typed = len(input_morse.replace(' ', '').replace('/', ''))
    wpm = round((chars_typed / 5) / (elapsed / 60), 1) if elapsed > 0 else 0
    state["stats"]["total_attempts"] += 1
    if perfect:
        state["stats"]["correct"] += 1
        state["stats"]["streak"] += 1
        if state["stats"]["streak"] > state["stats"]["best_streak"]:
            state["stats"]["best_streak"] = state["stats"]["streak"]
    else:
        state["stats"]["streak"] = 0
    save_stats_to_file()
    result_data = {
        "result": "correct" if perfect else "wrong",
        "decoded": decoded,
        "expected": expected,
        "accuracy": accuracy,
        "char_results": char_results,
        "wpm": wpm,
        "stats": state["stats"]
    }
    # Optional: clear after submit
    state["speed_morse_output"] = ""
    state["speed_morse_buffer"] = ""
    return jsonify(result_data)

@app.route("/clear", methods=["POST"])
def clear():
    state["send_output"] = ""
    state["encode_output"] = ""
    state["encode_input"] = ""
    state["current_morse_buffer"] = ""
    send_buffer.clear()
    state["speed_morse_buffer"] = ""
    state["speed_morse_output"] = ""
    return jsonify(state)

@app.route("/toggle_cheat_sheet", methods=["POST"])
def toggle_cheat_sheet():
    state["cheat_sheet"] = not state["cheat_sheet"]
    return jsonify({"cheat_sheet": state["cheat_sheet"]})

@app.route("/get_settings")
def get_settings():
    return jsonify(settings)

# ── Network / peer-to-peer routes ─────────────────────────────────────────────

@app.route("/peers")
def get_peers():
    """Return this device's identity and the current peer list."""
    with peers_lock:
        now = time.time()
        return jsonify({
            "self": {
                "uuid": DEVICE_UUID,
                "name": settings.get("device_name", "Morse Pi"),
                "ip":   _get_local_ip(),
                "port": 5000,
            },
            "peers": [
                {
                    "uuid":          uid,
                    "name":          p["name"],
                    "ip":            p["ip"],
                    "port":          p["port"],
                    "last_seen_ago": round(now - p["last_seen"], 1),
                }
                for uid, p in peers.items()
            ],
        })

@app.route("/net_status")
def net_status():
    """Return peers + inbox — polled by the NETWORK tab UI."""
    with peers_lock:
        now = time.time()
        peer_list = [
            {
                "uuid":          uid,
                "name":          p["name"],
                "ip":            p["ip"],
                "port":          p["port"],
                "last_seen_ago": round(now - p["last_seen"], 1),
            }
            for uid, p in peers.items()
        ]
    return jsonify({
        "self": {
            "uuid": DEVICE_UUID,
            "name": settings.get("device_name", "Morse Pi"),
            "ip":   _get_local_ip(),
            "port": 5000,
        },
        "peers":  peer_list,
        "inbox":  list(reversed(state["net_inbox"])),  # newest first
    })

@app.route("/receive_morse", methods=["POST"])
def receive_morse():
    """Accept an incoming Morse transmission from another Pi on the LAN."""
    data        = request.json or {}
    sender_name = data.get("sender_name", "Unknown")
    text        = (data.get("text") or "").strip().upper()
    morse       = (data.get("morse") or "").strip()
    if not text and not morse:
        return jsonify({"ok": False, "error": "no content"})
    if text and not morse:
        morse = morse_encode(text)
    msg = {
        "sender": sender_name,
        "text":   text,
        "morse":  morse,
        "ts":     time.time(),
    }
    state["net_inbox"].append(msg)
    if len(state["net_inbox"]) > 30:
        state["net_inbox"].pop(0)
    # Play through speaker in background
    if text:
        threading.Thread(target=lambda: _play_morse_string(text), daemon=True).start()
    return jsonify({"ok": True, "received": text})

@app.route("/send_to_peer", methods=["POST"])
def send_to_peer():
    """Send plaintext Morse to another Pi's /receive_morse endpoint over HTTP."""
    data = request.json or {}
    ip   = data.get("ip", "")
    port = int(data.get("port", 5000))
    text = (data.get("text") or "").strip().upper()
    if not ip or not text:
        return jsonify({"ok": False, "error": "missing ip or text"})
    payload = json.dumps({
        "sender_name": settings.get("device_name", "Morse Pi"),
        "text":        text,
        "morse":       morse_encode(text),
    }).encode()
    try:
        url = f"http://{ip}:{port}/receive_morse"
        req = _urllib_request.Request(
            url, data=payload,
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        with _urllib_request.urlopen(req, timeout=5) as resp:
            result = json.loads(resp.read())
        return jsonify({"ok": True, "result": result})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)})

@app.route("/clear_inbox", methods=["POST"])
def clear_inbox():
    state["net_inbox"].clear()
    return jsonify({"ok": True})

@app.route("/assign_gpio", methods=["POST"])
def assign_gpio():
    """Assign a GPIO pin role from the diagnostic page.
    
    Roles: speaker_pin, data_pin, dot_pin, dash_pin, ground (add to grounded_pins), clear
    Constraints:
    - dot_pin and dash_pin cannot be the same
    - dot_pin, dash_pin, data_pin cannot be grounded
    - speaker_pin cannot be grounded
    """
    data = request.json or {}
    bcm = data.get("bcm")
    role = data.get("role")  # Various formats accepted: dot/dot_pin, dash/dash_pin, etc.
    
    if bcm is None or role is None:
        return jsonify({"ok": False, "error": "missing bcm or role"})
    
    bcm = int(bcm)
    
    # Normalize role names (accept both short and long forms)
    role_map = {
        "dot": "dot_pin",
        "dash": "dash_pin",
        "straight": "data_pin",
        "data": "data_pin",
        "speaker": "speaker_pin",
        "led": "speaker_pin",
    }
    role = role_map.get(role, role)
    
    # Get protected pins (keys can't be grounded)
    key_pins = set()
    if settings.get("pin_mode") == "dual":
        if settings.get("dot_pin") is not None:
            key_pins.add(int(settings.get("dot_pin")))
        if settings.get("dash_pin") is not None:
            key_pins.add(int(settings.get("dash_pin")))
    else:
        if settings.get("data_pin") is not None:
            key_pins.add(int(settings.get("data_pin")))
    
    if role == "ground":
        # Cannot ground key pins or speaker pin
        if bcm in key_pins:
            return jsonify({"ok": False, "error": "Cannot ground a key pin"})
        if bcm == settings.get("speaker_pin"):
            return jsonify({"ok": False, "error": "Cannot ground the speaker pin"})
        # Clear any existing role for this pin
        for k in ["speaker_pin", "data_pin", "dot_pin", "dash_pin"]:
            if settings.get(k) == bcm:
                settings[k] = None
        # Add to grounded_pins if not already there
        grounded = settings.get("grounded_pins", [])
        if bcm not in grounded:
            grounded.append(bcm)
            settings["grounded_pins"] = grounded
    elif role == "clear":
        # Remove all assignments for this pin
        for k in ["speaker_pin", "data_pin", "dot_pin", "dash_pin", "ground_pin"]:
            if settings.get(k) == bcm:
                settings[k] = None
        grounded = settings.get("grounded_pins", [])
        if bcm in grounded:
            grounded.remove(bcm)
            settings["grounded_pins"] = grounded
    elif role == "speaker_pin":
        # Cannot set a key pin as speaker
        if bcm in key_pins:
            return jsonify({"ok": False, "error": "This pin is used as a key"})
        # Remove from grounded if present
        grounded = settings.get("grounded_pins", [])
        if bcm in grounded:
            grounded.remove(bcm)
            settings["grounded_pins"] = grounded
        # Clear any existing speaker assignment
        settings["speaker_pin"] = bcm
    elif role in ["data_pin", "dot_pin", "dash_pin"]:
        # Cannot set a grounded pin as a key
        grounded = settings.get("grounded_pins", [])
        if bcm in grounded:
            return jsonify({"ok": False, "error": "Cannot use a grounded pin as a key"})
        # For dot/dash, ensure they're not the same
        if role == "dot_pin":
            if bcm == settings.get("dash_pin"):
                return jsonify({"ok": False, "error": "Dot and dash pins cannot be the same"})
        elif role == "dash_pin":
            if bcm == settings.get("dot_pin"):
                return jsonify({"ok": False, "error": "Dot and dash pins cannot be the same"})
        # Clear other key assignments for this pin
        for k in ["speaker_pin", "data_pin", "dot_pin", "dash_pin", "ground_pin"]:
            if settings.get(k) == bcm:
                settings[k] = None
        settings[role] = bcm
    else:
        return jsonify({"ok": False, "error": f"Unknown role: {role}"})
    
    save_settings_to_file(settings)
    recreate_gpio()
    return jsonify({"ok": True, "settings": settings})

# ── Network key-based morse sending ────────────────────────────────────────────
net_morse_buffer = []
net_morse_active = False
net_morse_press_time = 0
net_morse_gap_timer = None

def net_key_pressed():
    global net_morse_active, net_morse_press_time, net_morse_gap_timer
    net_morse_active = True
    net_morse_press_time = time.time()
    state["button_active"] = True
    if net_morse_gap_timer:
        net_morse_gap_timer.cancel()
    play_tone(settings["dot_freq"], duty=settings["volume"])

def net_key_released():
    global net_morse_active, net_morse_buffer, net_morse_gap_timer
    net_morse_active = False
    state["button_active"] = False
    stop_tone()
    duration = time.time() - net_morse_press_time
    symbol = '.' if duration < _get_dot_unit() * 2 else '-'
    net_morse_buffer.append(symbol)
    state["net_morse_buffer"] = ''.join(net_morse_buffer)
    if net_morse_gap_timer:
        net_morse_gap_timer.cancel()
    net_morse_gap_timer = threading.Timer(_get_letter_gap_secs(), net_finalize_letter)
    net_morse_gap_timer.start()

def net_finalize_letter():
    global net_morse_buffer, net_morse_gap_timer
    if not net_morse_active and net_morse_buffer:
        code = ''.join(net_morse_buffer)
        rev = {v: k for k, v in MORSE_CODE.items()}
        char = rev.get(code, '?')
        state["net_morse_output"] += char
        state["net_morse_buffer"] = ""
        net_morse_buffer.clear()
        net_morse_gap_timer = threading.Timer(_get_word_extra_secs(), net_finalize_word)
        net_morse_gap_timer.start()

def net_finalize_word():
    if not net_morse_active:
        if state["net_morse_output"] and not state["net_morse_output"].endswith(' '):
            state["net_morse_output"] += ' '

@app.route("/net_key_mode", methods=["POST"])
def net_key_mode():
    """Toggle network key input mode on/off."""
    data = request.json or {}
    enabled = data.get("enabled", False)
    state["net_key_mode"] = enabled
    if not enabled:
        # Clear buffers when disabling
        state["net_morse_buffer"] = ""
        state["net_morse_output"] = ""
        net_morse_buffer.clear()
    return jsonify({"ok": True, "net_key_mode": state["net_key_mode"]})

@app.route("/net_key_press", methods=["POST"])
def net_key_press():
    """Handle key press/release for network morse composition."""
    pressed = request.json.get("pressed", False)
    if pressed:
        net_key_pressed()
    else:
        net_key_released()
    return jsonify({"ok": True})

@app.route("/net_clear_morse", methods=["POST"])
def net_clear_morse():
    """Clear the network morse buffer."""
    state["net_morse_buffer"] = ""
    state["net_morse_output"] = ""
    net_morse_buffer.clear()
    return jsonify({"ok": True})

@app.route("/net_send_morse", methods=["POST"])
def net_send_morse():
    """Send the composed morse message to a peer."""
    data = request.json or {}
    ip = data.get("ip", "")
    port = int(data.get("port", 5000))
    text = state.get("net_morse_output", "").strip().upper()
    morse = morse_encode(text) if text else ""
    
    if not ip or not text:
        return jsonify({"ok": False, "error": "missing ip or no message composed"})
    
    payload = json.dumps({
        "sender_name": settings.get("device_name", "Morse Pi"),
        "text": text,
        "morse": morse,
    }).encode()
    
    try:
        url = f"http://{ip}:{port}/receive_morse"
        req = _urllib_request.Request(
            url, data=payload,
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        with _urllib_request.urlopen(req, timeout=5) as resp:
            result = json.loads(resp.read())
        # Clear buffer after successful send
        state["net_morse_buffer"] = ""
        state["net_morse_output"] = ""
        net_morse_buffer.clear()
        return jsonify({"ok": True, "result": result, "sent_text": text})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)})

# ── USB HID Keyboard routes ────────────────────────────────────────────────────

@app.route("/kb_status")
def kb_status():
    """Return keyboard status for polling."""
    _check_usb_hid()  # Refresh availability check
    return jsonify({
        "kb_enabled": settings.get("kb_enabled", False),
        "kb_mode": settings.get("kb_mode", "letters"),
        "kb_dot_key": settings.get("kb_dot_key", "z"),
        "kb_dash_key": settings.get("kb_dash_key", "x"),
        "kb_output": state.get("kb_output", ""),
        "usb_hid_available": USB_HID_AVAILABLE,
    })

@app.route("/kb_enable", methods=["POST"])
def kb_enable():
    """Enable or disable USB HID keyboard mode."""
    data = request.json or {}
    enabled = data.get("enabled", False)
    
    # Check if USB HID is available before enabling
    if enabled and not _check_usb_hid():
        return jsonify({
            "ok": False, 
            "error": "USB HID device not available. Enable USB gadget mode on the Pi.",
            "usb_hid_available": False
        })
    
    settings["kb_enabled"] = bool(enabled)
    save_settings_to_file(settings)
    return jsonify({
        "ok": True,
        "kb_enabled": settings["kb_enabled"],
        "usb_hid_available": USB_HID_AVAILABLE
    })

@app.route("/kb_mode", methods=["POST"])
def kb_mode():
    """Set keyboard mode (letters or custom)."""
    data = request.json or {}
    mode = data.get("mode", "letters")
    if mode not in ["letters", "custom"]:
        return jsonify({"ok": False, "error": "Invalid mode. Use 'letters' or 'custom'."})
    
    settings["kb_mode"] = mode
    save_settings_to_file(settings)
    return jsonify({
        "ok": True,
        "kb_mode": settings["kb_mode"]
    })

@app.route("/kb_set_keys", methods=["POST"])
def kb_set_keys():
    """Set custom dot and dash keys for custom keyboard mode."""
    data = request.json or {}
    dot_key = data.get("dot_key")
    dash_key = data.get("dash_key")
    
    if dot_key is not None:
        # Validate key - must be a single character or special key name
        if len(dot_key) == 1 and dot_key.lower() in HID_KEYCODES:
            settings["kb_dot_key"] = dot_key.lower()
        elif dot_key.lower() == 'space':
            settings["kb_dot_key"] = 'space'
        else:
            return jsonify({"ok": False, "error": f"Invalid dot key: {dot_key}"})
    
    if dash_key is not None:
        if len(dash_key) == 1 and dash_key.lower() in HID_KEYCODES:
            settings["kb_dash_key"] = dash_key.lower()
        elif dash_key.lower() == 'space':
            settings["kb_dash_key"] = 'space'
        else:
            return jsonify({"ok": False, "error": f"Invalid dash key: {dash_key}"})
    
    save_settings_to_file(settings)
    return jsonify({
        "ok": True,
        "kb_dot_key": settings["kb_dot_key"],
        "kb_dash_key": settings["kb_dash_key"]
    })

@app.route("/kb_clear", methods=["POST"])
def kb_clear():
    """Clear the keyboard output buffer."""
    state["kb_output"] = ""
    return jsonify({"ok": True, "kb_output": ""})

@app.route("/kb_send_custom", methods=["POST"])
def kb_send_custom():
    """Send a custom key when in custom keyboard mode (for paddle-to-key mapping)."""
    if not settings.get("kb_enabled", False):
        return jsonify({"ok": False, "error": "Keyboard not enabled"})
    if settings.get("kb_mode") != "custom":
        return jsonify({"ok": False, "error": "Not in custom mode"})
    
    data = request.json or {}
    key_type = data.get("type")  # "dot" or "dash"
    
    if key_type == "dot":
        key_char = settings.get("kb_dot_key", "z")
    elif key_type == "dash":
        key_char = settings.get("kb_dash_key", "x")
    else:
        return jsonify({"ok": False, "error": "Invalid key type. Use 'dot' or 'dash'."})
    
    success = _hid_send_custom_key(key_char)
    if success:
        # Track in kb_output
        display_char = ' ' if key_char == 'space' else key_char
        state["kb_output"] = (state.get("kb_output", "") + display_char)[-100:]
    
    return jsonify({
        "ok": success,
        "key_sent": key_char,
        "kb_output": state.get("kb_output", "")
    })

@app.route("/key_press", methods=["POST"])
def key_press():
    """Simulate button press/release from keyboard (spacebar) in browser."""
    pressed = request.json.get("pressed", False)
    if state["mode"] == "speed":
        if pressed:
            speed_button_pressed()
        else:
            speed_button_released()
    else:
        if pressed:
            send_button_pressed()
        else:
            send_button_released()
    return jsonify({"ok": True})

@app.route("/key_press_dual", methods=["POST"])
def key_press_dual():
    """Simulate dual-paddle dot/dash from browser keyboard (Z/X) or on-screen buttons.

    In iambic mode the virtual paddle state is fed directly into the keyer
    thread so keyboard squeezing, memory, and timing all work identically to
    physical GPIO paddles.

    A server-side watchdog timer (3 s) auto-releases the virtual key if the
    browser never sends a keyup — this fixes the rare race condition where a
    fast tap causes keyup to arrive before keydown is processed.
    """
    global _virtual_dot, _virtual_dash, _virtual_dot_timer, _virtual_dash_timer
    data    = request.json
    sym     = data.get("sym")           # 'dot' or 'dash'
    pressed = data.get("pressed", False)
    if sym == "dot":
        if _virtual_dot_timer:
            _virtual_dot_timer.cancel()
            _virtual_dot_timer = None
        _virtual_dot = bool(pressed)
        if pressed:
            _virtual_dot_timer = threading.Timer(3.0, lambda: _auto_release_virtual_key('dot'))
            _virtual_dot_timer.start()
    elif sym == "dash":
        if _virtual_dash_timer:
            _virtual_dash_timer.cancel()
            _virtual_dash_timer = None
        _virtual_dash = bool(pressed)
        if pressed:
            _virtual_dash_timer = threading.Timer(3.0, lambda: _auto_release_virtual_key('dash'))
            _virtual_dash_timer.start()
    return jsonify({"ok": True})

@app.route("/reset_stats", methods=["POST"])
def reset_stats():
    state["stats"] = {
        "total_attempts": 0, "correct": 0,
        "streak": 0, "best_streak": 0,
        "total_chars": 0, "sessions": []
    }
    save_stats_to_file()
    return jsonify(state["stats"])

@app.route("/clear_speed", methods=["POST"])
def clear_speed():
    global speed_buffer, speed_active, speed_gap_timer
    state["speed_morse_buffer"] = ""
    state["speed_morse_output"] = ""
    speed_buffer.clear()
    speed_active = False
    if speed_gap_timer:
        speed_gap_timer.cancel()
        speed_gap_timer = None
    return jsonify(state)

recreate_gpio()
init_diag_readers()

# ── Start peer-discovery threads ──────────────────────────────────────────────
threading.Thread(target=_beacon_sender,   daemon=True, name="beacon_sender").start()
threading.Thread(target=_beacon_listener, daemon=True, name="beacon_listener").start()

if __name__ == "__main__":
    print("=== Morse Trainer Starting ===")
    print(f" GPIO available:   {GPIO_AVAILABLE}")
    print(f" Pin mode:         {settings.get('pin_mode','single')}")
    print(f" Beeper:           {'OK' if beeper else 'NOT INITIALIZED'}")
    print(f" Data btn:         {'OK' if data_btn else 'NOT INITIALIZED'}")
    print(f" Dot/Dash btns:    {('OK' if dot_btn else 'NO')}/{('OK' if dash_btn else 'NO')}")
    print(f" Settings file:    {SETTINGS_FILE}")
    print(f" Listening on:     http://0.0.0.0:5000")
    print("==============================")
    app.run(host="0.0.0.0", port=5000, debug=True, use_reloader=False)
