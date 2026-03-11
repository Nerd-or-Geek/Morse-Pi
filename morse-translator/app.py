# -*- coding: utf-8 -*-
"""Flask frontend — all HTTP routes, peer-to-peer networking, and startup.

This is the main entry-point.  It imports the four specialist modules
(gpio_monitor, sound, morse, keyboard) plus the shared state layer.
"""

import time
import threading
import json
import os
import subprocess
import socket
import uuid as _uuid_mod
import urllib.request as _urllib_request

from flask import Flask, render_template, request, jsonify

# ── Project modules ───────────────────────────────────────────────────────────
import shared
import morse
import keyboard
import gpio_monitor
import sound

# ══════════════════════════════════════════════════════════════════════════════
#  FLASK APP
# ══════════════════════════════════════════════════════════════════════════════
app = Flask(__name__)
app.jinja_env.auto_reload = True

_old_get_source = app.jinja_env.loader.get_source
def _tolerant_get_source(environment, template):
    contents, filename, uptodate = _old_get_source(environment, template)
    contents = contents.encode('utf-8', errors='replace').decode('utf-8')
    return contents, filename, uptodate
app.jinja_env.loader.get_source = _tolerant_get_source


# ══════════════════════════════════════════════════════════════════════════════
#  PEER-TO-PEER NETWORKING
# ══════════════════════════════════════════════════════════════════════════════
BEACON_PORT = 5001
DEVICE_UUID = str(_uuid_mod.uuid4())
peers       = {}
peers_lock  = threading.Lock()

_cached_local_ip      = None
_cached_local_ip_time = 0


def _get_local_ip():
    """Return the machine's primary LAN IP (cached 10 s)."""
    global _cached_local_ip, _cached_local_ip_time
    now = time.time()
    if _cached_local_ip and now - _cached_local_ip_time < 10:
        return _cached_local_ip
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(2)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        _cached_local_ip = ip
        _cached_local_ip_time = now
        return ip
    except Exception:
        return _cached_local_ip or "127.0.0.1"


def _beacon_sender():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    while True:
        try:
            pkt = json.dumps({
                "type": "morse_pi_beacon",
                "uuid": DEVICE_UUID,
                "name": shared.settings.get("device_name", "Morse Pi"),
                "ip":   _get_local_ip(),
                "port": 5000,
            }).encode()
            sock.sendto(pkt, ("255.255.255.255", BEACON_PORT))
        except Exception:
            pass
        time.sleep(3)


def _beacon_listener():
    while True:
        sock = None
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            except AttributeError:
                pass
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            sock.bind(("", BEACON_PORT))
            sock.settimeout(2.0)
        except Exception as e:
            print(f"[net] beacon bind failed: {e}, retrying in 5 s")
            if sock:
                try: sock.close()
                except: pass
            time.sleep(5)
            continue
        while True:
            try:
                data, addr = sock.recvfrom(2048)
                pkt = json.loads(data.decode())
                if pkt.get("type") != "morse_pi_beacon":
                    continue
                uid = pkt.get("uuid")
                if not uid or uid == DEVICE_UUID:
                    continue
                with peers_lock:
                    peers[uid] = {
                        "name":      pkt.get("name", "Unknown"),
                        "ip":        pkt.get("ip", addr[0]),
                        "port":      int(pkt.get("port", 5000)),
                        "last_seen": time.time(),
                    }
            except socket.timeout:
                pass
            except OSError:
                break
            except Exception:
                pass
            now = time.time()
            with peers_lock:
                expired = [u for u, p in list(peers.items()) if now - p["last_seen"] > 15]
                for u in expired:
                    del peers[u]
        try: sock.close()
        except: pass


# ══════════════════════════════════════════════════════════════════════════════
#  ROUTES — core pages
# ══════════════════════════════════════════════════════════════════════════════

@app.route("/")
def index():
    return render_template("index.html",
                           state=shared.state,
                           settings=shared.settings,
                           morse_code=morse.MORSE_CODE)


@app.route("/status")
def status():
    return jsonify({
        **shared.state,
        "gpio_available":    shared.GPIO_AVAILABLE,
        "pin_states":        shared.pin_states,
        "keyer_state":       sound.keyer_state_label,
        "kb_enabled":        shared.settings.get("kb_enabled", False),
        "kb_mode":           shared.settings.get("kb_mode", "letters"),
        "kb_dot_key":        shared.settings.get("kb_dot_key", "z"),
        "kb_dash_key":       shared.settings.get("kb_dash_key", "x"),
        "usb_hid_available": keyboard.USB_HID_AVAILABLE,
    })


@app.route("/diag")
def diag():
    return render_template("diag.html",
                           settings=shared.settings,
                           gpio_available=shared.GPIO_AVAILABLE)


# ══════════════════════════════════════════════════════════════════════════════
#  ROUTES — GPIO diagnostics
# ══════════════════════════════════════════════════════════════════════════════

@app.route("/gpio_poll")
def gpio_poll():
    return jsonify({
        "gpio_available":  shared.GPIO_AVAILABLE,
        "gpio_error":      shared.GPIO_ERROR,
        "pin_mode":        shared.settings.get("pin_mode", "single"),
        "output_type":     shared.settings.get("output_type", "speaker"),
        "data_pin":        shared.settings.get("data_pin"),
        "dot_pin":         shared.settings.get("dot_pin"),
        "dash_pin":        shared.settings.get("dash_pin"),
        "speaker_pin":     shared.settings.get("speaker_pin"),
        "speaker_pin2":    shared.settings.get("speaker_pin2"),
        "speaker_gnd_mode": shared.settings.get("speaker_gnd_mode", "3v3"),
        "ground_pin":      shared.settings.get("ground_pin"),
        "grounded_pins":   shared.settings.get("grounded_pins", []),
        "states":          gpio_monitor.get_all_pin_states(),
        "power_pins":      gpio_monitor.get_power_pins(),
        "errors":          shared.gpio_error_log[-20:],
        "timestamp":       time.time(),
    })


@app.route("/gpio_reinit", methods=["POST"])
def gpio_reinit():
    shared.gpio_error_log.clear()
    if shared.GPIO_ERROR:
        shared.gpio_error_log.append(f"Import error: {shared.GPIO_ERROR}")
    else:
        sound.recreate_gpio()
    return jsonify({"ok": True, "errors": shared.gpio_error_log})


# ══════════════════════════════════════════════════════════════════════════════
#  ROUTES — mode switching, encode, decode, speed
# ══════════════════════════════════════════════════════════════════════════════

@app.route("/set_mode", methods=["POST"])
def set_mode():
    mode = request.json.get("mode")
    if mode in ["send", "encode", "decode", "speed", "settings", "stats", "network"]:
        shared.state["mode"] = mode
        if mode == "decode":
            phrase = morse.random_phrase(shared.settings.get("difficulty", "medium"))
            shared.state["current_phrase"] = phrase
            shared.state["decode_result"] = ""
        elif mode == "speed":
            shared.state["speed_phrase"] = morse.random_phrase(shared.settings.get("difficulty", "medium"))
            shared.state["speed_result"] = ""
            shared.state["speed_morse_buffer"] = ""
            shared.state["speed_morse_output"] = ""
            sound.recreate_gpio()
        elif mode == "send":
            sound.recreate_gpio()
    return jsonify(shared.state)


@app.route("/encode", methods=["POST"])
def encode():
    text = request.json.get("text", "")
    shared.state["encode_input"] = text
    shared.state["encode_output"] = morse.morse_encode(text)
    return jsonify({"morse": shared.state["encode_output"]})


@app.route("/play", methods=["POST"])
def play():
    text = shared.state.get("encode_input", "")
    threading.Thread(target=lambda: sound._play_morse_string(text), daemon=True).start()
    return jsonify({"status": "playing"})


@app.route("/play_phrase", methods=["POST"])
def play_phrase():
    text = shared.state.get("current_phrase", "")
    threading.Thread(target=lambda: sound._play_morse_string(text), daemon=True).start()
    return jsonify({"status": "playing"})


@app.route("/wpm_test", methods=["POST"])
def wpm_test():
    threading.Thread(target=lambda: sound._play_morse_string("PARIS"), daemon=True).start()
    return jsonify({"status": "playing", "wpm": shared.settings.get("wpm_target", 20)})


# ══════════════════════════════════════════════════════════════════════════════
#  ROUTES — settings
# ══════════════════════════════════════════════════════════════════════════════

@app.route("/save_settings", methods=["POST"])
def save_settings_route():
    data = request.json or {}
    COERCE_INT          = {"speaker_pin", "data_pin", "dot_pin", "dash_pin", "dot_freq", "dash_freq", "wpm_target"}
    COERCE_NULLABLE_INT = {"ground_pin", "speaker_pin2"}
    COERCE_FLOAT        = {"volume", "farnsworth_letter_mult", "farnsworth_word_mult"}
    COERCE_BOOL         = {"use_external_switch", "farnsworth_enabled", "kb_enabled"}
    if not data:
        return jsonify(shared.settings)
    for k, v in data.items():
        if k in COERCE_NULLABLE_INT:
            shared.settings[k] = int(v) if v is not None else None
        elif k in COERCE_INT:
            try: shared.settings[k] = int(v)
            except: pass
        elif k in COERCE_FLOAT:
            try: shared.settings[k] = float(v)
            except: pass
        elif k in COERCE_BOOL:
            shared.settings[k] = bool(v) if not isinstance(v, bool) else v
        elif isinstance(shared.DEFAULT_SETTINGS.get(k), int):
            try: shared.settings[k] = int(v)
            except: shared.settings[k] = v
        elif isinstance(shared.DEFAULT_SETTINGS.get(k), float):
            try: shared.settings[k] = float(v)
            except: shared.settings[k] = v
        else:
            shared.settings[k] = v
    shared.save_settings_to_file(shared.settings)
    sound.recreate_gpio()
    return jsonify(shared.settings)


@app.route("/preview_tone", methods=["POST"])
def preview_tone():
    freq     = int(request.json.get("freq", shared.settings["dot_freq"]))
    duration = float(request.json.get("duration", sound._get_dot_unit()))
    duty     = float(request.json.get("duty", shared.settings["volume"]))
    def _preview():
        sound.play_tone(freq, duration, duty)
        sound.stop_tone()
    threading.Thread(target=_preview, daemon=True).start()
    return jsonify({"status": "previewed"})


@app.route("/get_settings")
def get_settings():
    return jsonify(shared.settings)


# ══════════════════════════════════════════════════════════════════════════════
#  ROUTES — decode / speed quiz
# ══════════════════════════════════════════════════════════════════════════════

@app.route("/decode_submit", methods=["POST"])
def decode_submit():
    answer = request.json.get("answer", "").strip().upper()
    correct_phrase = shared.state["current_phrase"].strip().upper()
    correct = answer == correct_phrase
    shared.state["stats"]["total_attempts"] += 1
    if correct:
        shared.state["stats"]["correct"] += 1
        shared.state["stats"]["streak"] += 1
        if shared.state["stats"]["streak"] > shared.state["stats"]["best_streak"]:
            shared.state["stats"]["best_streak"] = shared.state["stats"]["streak"]
        result = "correct"
    else:
        shared.state["stats"]["streak"] = 0
        result = "wrong"
    shared.state["decode_result"] = result
    shared.state["decode_correct_answer"] = correct_phrase
    shared.save_stats_to_file()
    return jsonify({"result": result, "correct_answer": correct_phrase, "stats": shared.state["stats"]})


@app.route("/submit_test", methods=["POST"])
def submit_test():
    input_morse = shared.state["speed_morse_output"].strip()
    elapsed = request.json.get("elapsed", 1)
    if not input_morse:
        shared.state["speed_result"] = "no_input"
        return jsonify({"result": "no_input"})
    decoded  = morse.morse_decode(input_morse).strip().upper()
    expected = shared.state["speed_phrase"].strip().upper()
    char_results  = []
    max_len       = max(len(expected), len(decoded))
    correct_count = 0
    for i in range(max_len):
        exp_c = expected[i] if i < len(expected) else ''
        got_c = decoded[i] if i < len(decoded) else ''
        is_match = (exp_c == got_c and exp_c != '')
        if is_match:
            correct_count += 1
        char_results.append({"expected": exp_c, "got": got_c, "correct": is_match})
    accuracy = round((correct_count / len(expected)) * 100) if expected else 0
    perfect  = decoded == expected
    chars_typed = len(input_morse.replace(' ', '').replace('/', ''))
    wpm = round((chars_typed / 5) / (elapsed / 60), 1) if elapsed > 0 else 0
    shared.state["stats"]["total_attempts"] += 1
    if perfect:
        shared.state["stats"]["correct"] += 1
        shared.state["stats"]["streak"] += 1
        if shared.state["stats"]["streak"] > shared.state["stats"]["best_streak"]:
            shared.state["stats"]["best_streak"] = shared.state["stats"]["streak"]
    else:
        shared.state["stats"]["streak"] = 0
    shared.save_stats_to_file()
    result_data = {
        "result": "correct" if perfect else "wrong",
        "decoded": decoded, "expected": expected,
        "accuracy": accuracy, "char_results": char_results,
        "wpm": wpm, "stats": shared.state["stats"],
    }
    shared.state["speed_morse_output"] = ""
    shared.state["speed_morse_buffer"] = ""
    return jsonify(result_data)


# ══════════════════════════════════════════════════════════════════════════════
#  ROUTES — clear / cheat sheet / misc
# ══════════════════════════════════════════════════════════════════════════════

@app.route("/clear", methods=["POST"])
def clear():
    shared.state["send_output"] = ""
    shared.state["encode_output"] = ""
    shared.state["encode_input"] = ""
    shared.state["current_morse_buffer"] = ""
    sound.send_buffer.clear()
    shared.state["speed_morse_buffer"] = ""
    shared.state["speed_morse_output"] = ""
    return jsonify(shared.state)


@app.route("/toggle_cheat_sheet", methods=["POST"])
def toggle_cheat_sheet():
    shared.state["cheat_sheet"] = not shared.state["cheat_sheet"]
    return jsonify({"cheat_sheet": shared.state["cheat_sheet"]})


# ══════════════════════════════════════════════════════════════════════════════
#  ROUTES — network / peer-to-peer
# ══════════════════════════════════════════════════════════════════════════════

@app.route("/peers")
def get_peers():
    with peers_lock:
        now = time.time()
        return jsonify({
            "self": {
                "uuid": DEVICE_UUID,
                "name": shared.settings.get("device_name", "Morse Pi"),
                "ip":   _get_local_ip(),
                "port": 5000,
            },
            "peers": [
                {"uuid": uid, "name": p["name"], "ip": p["ip"],
                 "port": p["port"], "last_seen_ago": round(now - p["last_seen"], 1)}
                for uid, p in peers.items()
            ],
        })


@app.route("/net_status")
def net_status():
    with peers_lock:
        now = time.time()
        peer_list = [
            {"uuid": uid, "name": p["name"], "ip": p["ip"],
             "port": p["port"], "last_seen_ago": round(now - p["last_seen"], 1)}
            for uid, p in peers.items()
        ]
    return jsonify({
        "self":  {"uuid": DEVICE_UUID, "name": shared.settings.get("device_name", "Morse Pi"),
                  "ip": _get_local_ip(), "port": 5000},
        "peers": peer_list,
        "inbox": list(reversed(shared.state["net_inbox"])),
    })


@app.route("/receive_morse", methods=["POST"])
def receive_morse():
    data        = request.json or {}
    sender_name = data.get("sender_name", "Unknown")
    text        = (data.get("text") or "").strip().upper()
    morse_str   = (data.get("morse") or "").strip()
    if not text and not morse_str:
        return jsonify({"ok": False, "error": "no content"})
    if text and not morse_str:
        morse_str = morse.morse_encode(text)
    msg = {"sender": sender_name, "text": text, "morse": morse_str, "ts": time.time()}
    shared.state["net_inbox"].append(msg)
    if len(shared.state["net_inbox"]) > 30:
        shared.state["net_inbox"].pop(0)
    if text:
        threading.Thread(target=lambda: sound._play_morse_string(text), daemon=True).start()
    return jsonify({"ok": True, "received": text})


@app.route("/send_to_peer", methods=["POST"])
def send_to_peer():
    data = request.json or {}
    ip   = data.get("ip", "")
    port = int(data.get("port", 5000))
    text = (data.get("text") or "").strip().upper()
    if not ip or not text:
        return jsonify({"ok": False, "error": "missing ip or text"})
    payload = json.dumps({
        "sender_name": shared.settings.get("device_name", "Morse Pi"),
        "text": text, "morse": morse.morse_encode(text),
    }).encode()
    url = f"http://{ip}:{port}/receive_morse"
    last_err = None
    for attempt in range(3):
        try:
            req = _urllib_request.Request(url, data=payload,
                                         headers={"Content-Type": "application/json"}, method="POST")
            with _urllib_request.urlopen(req, timeout=5) as resp:
                result = json.loads(resp.read())
            return jsonify({"ok": True, "result": result})
        except Exception as e:
            last_err = str(e)
            if attempt < 2:
                time.sleep(0.3 * (attempt + 1))
    return jsonify({"ok": False, "error": last_err})


@app.route("/clear_inbox", methods=["POST"])
def clear_inbox():
    shared.state["net_inbox"].clear()
    return jsonify({"ok": True})


# ══════════════════════════════════════════════════════════════════════════════
#  ROUTES — GPIO assignment (diagnostic page)
# ══════════════════════════════════════════════════════════════════════════════

@app.route("/assign_gpio", methods=["POST"])
def assign_gpio():
    data = request.json or {}
    bcm  = data.get("bcm")
    role = data.get("role")
    if bcm is None or role is None:
        return jsonify({"ok": False, "error": "missing bcm or role"})
    bcm = int(bcm)
    role_map = {
        "dot": "dot_pin", "dash": "dash_pin",
        "straight": "data_pin", "data": "data_pin",
        "speaker": "speaker_pin", "led": "speaker_pin",
        "speaker2": "speaker_pin2",
    }
    role = role_map.get(role, role)
    key_pins = set()
    if shared.settings.get("pin_mode") == "dual":
        if shared.settings.get("dot_pin")  is not None: key_pins.add(int(shared.settings["dot_pin"]))
        if shared.settings.get("dash_pin") is not None: key_pins.add(int(shared.settings["dash_pin"]))
    else:
        if shared.settings.get("data_pin") is not None: key_pins.add(int(shared.settings["data_pin"]))

    if role == "ground":
        if bcm in key_pins:
            return jsonify({"ok": False, "error": "Cannot ground a key pin"})
        if bcm == shared.settings.get("speaker_pin") or bcm == shared.settings.get("speaker_pin2"):
            return jsonify({"ok": False, "error": "Cannot ground the speaker pin"})
        for k in ["speaker_pin", "speaker_pin2", "data_pin", "dot_pin", "dash_pin"]:
            if shared.settings.get(k) == bcm:
                shared.settings[k] = None
        grounded = shared.settings.get("grounded_pins", [])
        if bcm not in grounded:
            grounded.append(bcm)
            shared.settings["grounded_pins"] = grounded
    elif role == "clear":
        for k in ["speaker_pin", "speaker_pin2", "data_pin", "dot_pin", "dash_pin", "ground_pin"]:
            if shared.settings.get(k) == bcm:
                shared.settings[k] = None
        grounded = shared.settings.get("grounded_pins", [])
        if bcm in grounded:
            grounded.remove(bcm)
            shared.settings["grounded_pins"] = grounded
    elif role == "speaker_pin":
        if bcm in key_pins:
            return jsonify({"ok": False, "error": "This pin is used as a key"})
        grounded = shared.settings.get("grounded_pins", [])
        if bcm in grounded:
            grounded.remove(bcm); shared.settings["grounded_pins"] = grounded
        shared.settings["speaker_pin"] = bcm
    elif role == "speaker_pin2":
        if bcm in key_pins:
            return jsonify({"ok": False, "error": "This pin is used as a key"})
        grounded = shared.settings.get("grounded_pins", [])
        if bcm in grounded:
            grounded.remove(bcm); shared.settings["grounded_pins"] = grounded
        if bcm == shared.settings.get("speaker_pin"):
            return jsonify({"ok": False, "error": "Pin 2 cannot be the same as Pin 1"})
        shared.settings["speaker_pin2"] = bcm
    elif role in ["data_pin", "dot_pin", "dash_pin"]:
        grounded = shared.settings.get("grounded_pins", [])
        if bcm in grounded:
            return jsonify({"ok": False, "error": "Cannot use a grounded pin as a key"})
        if role == "dot_pin" and bcm == shared.settings.get("dash_pin"):
            return jsonify({"ok": False, "error": "Dot and dash pins cannot be the same"})
        if role == "dash_pin" and bcm == shared.settings.get("dot_pin"):
            return jsonify({"ok": False, "error": "Dot and dash pins cannot be the same"})
        for k in ["speaker_pin", "speaker_pin2", "data_pin", "dot_pin", "dash_pin", "ground_pin"]:
            if shared.settings.get(k) == bcm:
                shared.settings[k] = None
        shared.settings[role] = bcm
    else:
        return jsonify({"ok": False, "error": f"Unknown role: {role}"})

    shared.save_settings_to_file(shared.settings)
    sound.recreate_gpio()
    return jsonify({"ok": True, "settings": shared.settings})


# ══════════════════════════════════════════════════════════════════════════════
#  ROUTES — network key-based morse
# ══════════════════════════════════════════════════════════════════════════════

@app.route("/net_key_mode", methods=["POST"])
def net_key_mode():
    data = request.json or {}
    enabled = data.get("enabled", False)
    shared.state["net_key_mode"] = enabled
    if not enabled:
        shared.state["net_morse_buffer"] = ""
        shared.state["net_morse_output"] = ""
        sound.net_morse_buffer.clear()
    return jsonify({"ok": True, "net_key_mode": shared.state["net_key_mode"]})


@app.route("/net_key_press", methods=["POST"])
def net_key_press():
    pressed = request.json.get("pressed", False)
    if pressed:
        sound.net_key_pressed()
    else:
        sound.net_key_released()
    return jsonify({"ok": True})


@app.route("/net_clear_morse", methods=["POST"])
def net_clear_morse():
    shared.state["net_morse_buffer"] = ""
    shared.state["net_morse_output"] = ""
    sound.net_morse_buffer.clear()
    return jsonify({"ok": True})


@app.route("/net_send_morse", methods=["POST"])
def net_send_morse():
    data = request.json or {}
    ip   = data.get("ip", "")
    port = int(data.get("port", 5000))
    text = shared.state.get("net_morse_output", "").strip().upper()
    morse_str = morse.morse_encode(text) if text else ""
    if not ip or not text:
        return jsonify({"ok": False, "error": "missing ip or no message composed"})
    payload = json.dumps({
        "sender_name": shared.settings.get("device_name", "Morse Pi"),
        "text": text, "morse": morse_str,
    }).encode()
    url = f"http://{ip}:{port}/receive_morse"
    last_err = None
    for attempt in range(3):
        try:
            req = _urllib_request.Request(url, data=payload,
                                         headers={"Content-Type": "application/json"}, method="POST")
            with _urllib_request.urlopen(req, timeout=5) as resp:
                result = json.loads(resp.read())
            shared.state["net_morse_buffer"] = ""
            shared.state["net_morse_output"] = ""
            sound.net_morse_buffer.clear()
            return jsonify({"ok": True, "result": result, "sent_text": text})
        except Exception as e:
            last_err = str(e)
            if attempt < 2:
                time.sleep(0.3 * (attempt + 1))
    return jsonify({"ok": False, "error": last_err})


# ══════════════════════════════════════════════════════════════════════════════
#  ROUTES — USB HID keyboard
# ══════════════════════════════════════════════════════════════════════════════

@app.route("/kb_status")
def kb_status():
    keyboard._check_usb_hid()
    return jsonify({
        "kb_enabled":        shared.settings.get("kb_enabled", False),
        "kb_mode":           shared.settings.get("kb_mode", "letters"),
        "kb_dot_key":        shared.settings.get("kb_dot_key", "z"),
        "kb_dash_key":       shared.settings.get("kb_dash_key", "x"),
        "kb_output":         shared.state.get("kb_output", ""),
        "usb_hid_available": keyboard.USB_HID_AVAILABLE,
    })


@app.route("/kb_enable", methods=["POST"])
def kb_enable():
    data    = request.json or {}
    enabled = data.get("enabled", False)
    keyboard._check_usb_hid()
    shared.settings["kb_enabled"] = bool(enabled)
    shared.save_settings_to_file(shared.settings)
    warning = None
    if enabled and not keyboard.USB_HID_AVAILABLE:
        warning = ("Keyboard enabled but /dev/hidg0 not found. "
                   "Keystrokes won't send until HID device is available. Try rebooting the Pi.")
    return jsonify({"ok": True, "kb_enabled": shared.settings["kb_enabled"],
                    "usb_hid_available": keyboard.USB_HID_AVAILABLE, "warning": warning})


@app.route("/kb_hid_setup", methods=["POST"])
def kb_hid_setup():
    HID_SCRIPT  = "/usr/local/bin/morse-pi-hid-setup.sh"
    HID_SERVICE = "morse-pi-hid"
    if keyboard._check_usb_hid():
        return jsonify({"ok": True, "usb_hid_available": True, "message": "HID device already available."})
    try:
        subprocess.run(["sudo", "systemctl", "start", HID_SERVICE], capture_output=True, timeout=10)
    except Exception:
        pass
    if keyboard._check_usb_hid():
        return jsonify({"ok": True, "usb_hid_available": True, "message": "HID gadget activated via service."})
    if os.path.exists(HID_SCRIPT):
        try:
            result = subprocess.run(["sudo", HID_SCRIPT], capture_output=True, text=True, timeout=10)
            keyboard._check_usb_hid()
            if keyboard.USB_HID_AVAILABLE:
                return jsonify({"ok": True, "usb_hid_available": True, "message": "HID gadget activated via setup script."})
            else:
                return jsonify({"ok": True, "usb_hid_available": False,
                                "message": f"Setup script ran but /dev/hidg0 not found. You may need to reboot. "
                                            f"Script output: {result.stderr or result.stdout}"})
        except subprocess.TimeoutExpired:
            return jsonify({"ok": False, "error": "HID setup script timed out."})
        except Exception as e:
            return jsonify({"ok": False, "error": f"Failed to run HID setup: {e}"})
    try:
        subprocess.run(["sudo", "modprobe", "libcomposite"], capture_output=True, timeout=5)
        subprocess.run(["sudo", "modprobe", "dwc2"], capture_output=True, timeout=5)
        subprocess.run(["sudo", "systemctl", "start", HID_SERVICE], capture_output=True, timeout=10)
    except Exception:
        pass
    keyboard._check_usb_hid()
    if keyboard.USB_HID_AVAILABLE:
        return jsonify({"ok": True, "usb_hid_available": True, "message": "HID gadget activated after loading modules."})
    return jsonify({"ok": False, "usb_hid_available": False,
                    "error": "Could not activate HID gadget. Ensure install.sh was run as root, then reboot the Pi."})


@app.route("/kb_mode", methods=["POST"])
def kb_mode():
    data = request.json or {}
    mode = data.get("mode", "letters")
    if mode not in ["letters", "custom"]:
        return jsonify({"ok": False, "error": "Invalid mode. Use 'letters' or 'custom'."})
    shared.settings["kb_mode"] = mode
    shared.save_settings_to_file(shared.settings)
    return jsonify({"ok": True, "kb_mode": shared.settings["kb_mode"]})


@app.route("/kb_set_keys", methods=["POST"])
def kb_set_keys():
    data     = request.json or {}
    dot_key  = data.get("dot_key")
    dash_key = data.get("dash_key")
    if dot_key is not None:
        if len(dot_key) == 1 and dot_key.lower() in keyboard.HID_KEYCODES:
            shared.settings["kb_dot_key"] = dot_key.lower()
        elif dot_key.lower() == 'space':
            shared.settings["kb_dot_key"] = 'space'
        else:
            return jsonify({"ok": False, "error": f"Invalid dot key: {dot_key}"})
    if dash_key is not None:
        if len(dash_key) == 1 and dash_key.lower() in keyboard.HID_KEYCODES:
            shared.settings["kb_dash_key"] = dash_key.lower()
        elif dash_key.lower() == 'space':
            shared.settings["kb_dash_key"] = 'space'
        else:
            return jsonify({"ok": False, "error": f"Invalid dash key: {dash_key}"})
    shared.save_settings_to_file(shared.settings)
    return jsonify({"ok": True, "kb_dot_key": shared.settings["kb_dot_key"],
                    "kb_dash_key": shared.settings["kb_dash_key"]})


@app.route("/kb_clear", methods=["POST"])
def kb_clear():
    shared.state["kb_output"] = ""
    return jsonify({"ok": True, "kb_output": ""})


@app.route("/kb_send_custom", methods=["POST"])
def kb_send_custom():
    if not shared.settings.get("kb_enabled", False):
        return jsonify({"ok": False, "error": "Keyboard not enabled"})
    if shared.settings.get("kb_mode") != "custom":
        return jsonify({"ok": False, "error": "Not in custom mode"})
    data     = request.json or {}
    key_type = data.get("type")
    if key_type == "dot":
        key_char = shared.settings.get("kb_dot_key", "z")
    elif key_type == "dash":
        key_char = shared.settings.get("kb_dash_key", "x")
    else:
        return jsonify({"ok": False, "error": "Invalid key type. Use 'dot' or 'dash'."})
    success = keyboard._hid_send_custom_key(key_char)
    if success:
        dc = ' ' if key_char == 'space' else key_char
        shared.state["kb_output"] = (shared.state.get("kb_output", "") + dc)[-100:]
    return jsonify({"ok": success, "key_sent": key_char, "kb_output": shared.state.get("kb_output", "")})


# ══════════════════════════════════════════════════════════════════════════════
#  ROUTES — key press simulation (browser keyboard / on-screen buttons)
# ══════════════════════════════════════════════════════════════════════════════

@app.route("/key_press", methods=["POST"])
def key_press():
    pressed = request.json.get("pressed", False)
    if shared.state["mode"] == "speed":
        (sound.speed_button_pressed if pressed else sound.speed_button_released)()
    else:
        (sound.send_button_pressed if pressed else sound.send_button_released)()
    return jsonify({"ok": True})


@app.route("/key_press_dual", methods=["POST"])
def key_press_dual():
    data    = request.json
    sym     = data.get("sym")
    pressed = data.get("pressed", False)
    if sym == "dot":
        if sound._virtual_dot_timer:
            sound._virtual_dot_timer.cancel(); sound._virtual_dot_timer = None
        sound._virtual_dot = bool(pressed)
        if pressed:
            sound._virtual_dot_timer = threading.Timer(3.0, lambda: sound._auto_release_virtual_key('dot'))
            sound._virtual_dot_timer.start()
    elif sym == "dash":
        if sound._virtual_dash_timer:
            sound._virtual_dash_timer.cancel(); sound._virtual_dash_timer = None
        sound._virtual_dash = bool(pressed)
        if pressed:
            sound._virtual_dash_timer = threading.Timer(3.0, lambda: sound._auto_release_virtual_key('dash'))
            sound._virtual_dash_timer.start()
    return jsonify({"ok": True})


@app.route("/reset_stats", methods=["POST"])
def reset_stats():
    shared.state["stats"] = {
        "total_attempts": 0, "correct": 0,
        "streak": 0, "best_streak": 0,
        "total_chars": 0, "sessions": [],
    }
    shared.save_stats_to_file()
    return jsonify(shared.state["stats"])


@app.route("/clear_speed", methods=["POST"])
def clear_speed():
    shared.state["speed_morse_buffer"] = ""
    shared.state["speed_morse_output"] = ""
    sound.speed_buffer.clear()
    sound.speed_active = False
    if sound.speed_gap_timer:
        sound.speed_gap_timer.cancel()
        sound.speed_gap_timer = None
    return jsonify(shared.state)


# ══════════════════════════════════════════════════════════════════════════════
#  STARTUP
# ══════════════════════════════════════════════════════════════════════════════
sound.recreate_gpio()
gpio_monitor.init_diag_readers()

threading.Thread(target=_beacon_sender,   daemon=True, name="beacon_sender").start()
threading.Thread(target=_beacon_listener, daemon=True, name="beacon_listener").start()

if __name__ == "__main__":
    print("=== Morse Trainer Starting ===")
    print(f" GPIO available:   {shared.GPIO_AVAILABLE}")
    print(f" Pin mode:         {shared.settings.get('pin_mode', 'single')}")
    print(f" Beeper:           {'OK' if shared.beeper else 'NOT INITIALIZED'}")
    print(f" Data btn:         {'OK' if shared.data_btn else 'NOT INITIALIZED'}")
    print(f" Dot/Dash btns:    {('OK' if shared.dot_btn else 'NO')}/{('OK' if shared.dash_btn else 'NO')}")
    print(f" USB HID:          {'AVAILABLE' if keyboard.USB_HID_AVAILABLE else 'NOT AVAILABLE'}")
    print(f" Settings file:    {shared.SETTINGS_FILE}")
    print(f" Listening on:     http://0.0.0.0:5000")
    print("==============================")
    app.run(host="0.0.0.0", port=5000, debug=False, threaded=True, use_reloader=False)
