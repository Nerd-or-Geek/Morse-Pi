import time
import threading
import json
import random
import os
from flask import Flask, render_template, request, jsonify

# Try importing GPIO - gracefully degrade if not available
try:
    from gpiozero import Button, PWMOutputDevice
    GPIO_AVAILABLE = True
except Exception:
    GPIO_AVAILABLE = False

# --- Morse Code Mapping ---
MORSE_CODE = {
    'A': '.-',    'B': '-...',  'C': '-.-.',  'D': '-..',   'E': '.',
    'F': '..-.',  'G': '--.',   'H': '....',  'I': '..',    'J': '.---',
    'K': '-.-',   'L': '.-..',  'M': '--',    'N': '-.',    'O': '---',
    'P': '.--.',  'Q': '--.-',  'R': '.-.',   'S': '...',   'T': '-',
    'U': '..-',   'V': '...-',  'W': '.--',   'X': '-..-',  'Y': '-.--',
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
    "builtin_button_pin": 17,
    "external_switch_pin_a": 22,
    "external_switch_pin_b": 27,
    "use_external_switch": False,
    "dot_freq": 700,
    "dash_freq": 500,
    "volume": 0.5,
    "dot_max": 0.25,
    "letter_gap": 0.5,
    "word_gap": 1.5,
    "wpm_target": 20,
    "theme": "dark",
    "difficulty": "medium",
    "quiz_categories": ["words"],
    "practice_chars": "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
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

settings = load_settings()

# --- App ---
app = Flask(__name__)
lock = threading.Lock()

state = {
    "mode": "send",
    "cheat_sheet": False,
    "current_phrase": "",
    "decode_result": "",
    "speed_phrase": "",
    "speed_result": "",
    "send_output": "",
    "encode_output": "",
    "encode_input": "",
    "stats": {
        "total_attempts": 0,
        "correct": 0,
        "streak": 0,
        "best_streak": 0,
        "total_chars": 0,
        "sessions": []
    },
    "button_active": False,
    "current_morse_buffer": ""
}

# --- GPIO Setup ---
beeper = None
builtin_btn = None
external_btn = None

def init_gpio():
    global beeper, builtin_btn, external_btn
    if not GPIO_AVAILABLE:
        return
    try:
        beeper = PWMOutputDevice(settings["speaker_pin"], frequency=settings["dot_freq"], initial_value=0)
        builtin_btn = Button(settings["builtin_button_pin"], pull_up=True, bounce_time=0.05)
        builtin_btn.when_pressed = send_button_pressed
        builtin_btn.when_released = send_button_released

        if settings.get("use_external_switch"):
            # External switch wired across two pins - one as output (ground), one as input
            try:
                external_btn = Button(settings["external_switch_pin_a"], pull_up=True, bounce_time=0.05)
                external_btn.when_pressed = send_button_pressed
                external_btn.when_released = send_button_released
            except Exception as e:
                print(f"External switch init failed: {e}")
    except Exception as e:
        print(f"GPIO init failed: {e}")

def recreate_gpio():
    global beeper, builtin_btn, external_btn
    if not GPIO_AVAILABLE:
        return
    try:
        if beeper:
            beeper.close()
        if builtin_btn:
            builtin_btn.close()
        if external_btn:
            external_btn.close()
    except Exception:
        pass
    init_gpio()

def play_tone(freq, duration=None, duty=None):
    if beeper:
        with lock:
            try:
                beeper.frequency = max(1, int(freq))
                beeper.value = float(duty) if duty is not None else settings["volume"]
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

# --- Send Mode Logic ---
send_buffer = []
send_active = False
send_press_time = 0
send_gap_timer = None

def send_button_pressed():
    global send_active, send_press_time, send_gap_timer
    send_active = True
    send_press_time = time.time()
    state["button_active"] = True
    if send_gap_timer:
        send_gap_timer.cancel()
    play_tone(settings["dot_freq"], duty=settings["volume"])

def send_button_released():
    global send_active, send_buffer, send_gap_timer
    send_active = False
    state["button_active"] = False
    stop_tone()
    duration = time.time() - send_press_time
    symbol = '.' if duration < settings["dot_max"] else '-'
    send_buffer.append(symbol)
    state["current_morse_buffer"] = ''.join(send_buffer)

    # Cancel previous timer, start new letter-gap timer
    if send_gap_timer:
        send_gap_timer.cancel()
    send_gap_timer = threading.Timer(settings["letter_gap"], finalize_letter)
    send_gap_timer.start()

def finalize_letter():
    global send_buffer, send_gap_timer
    if not send_active and send_buffer:
        code = ''.join(send_buffer)
        rev = {v: k for k, v in MORSE_CODE.items()}
        char = rev.get(code, '?')
        state["send_output"] = (state["send_output"] + char).strip()
        state["current_morse_buffer"] = ""
        send_buffer.clear()
        # Start word gap timer
        send_gap_timer = threading.Timer(settings["word_gap"] - settings["letter_gap"], finalize_word)
        send_gap_timer.start()

def finalize_word():
    global send_buffer
    if not send_active:
        if state["send_output"] and not state["send_output"].endswith(' '):
            state["send_output"] += ' '

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
        # Single common word
        all_words = words.get("noun", ["cat"]) + words.get("verb", ["runs"])
        return random.choice(all_words).upper()
    elif difficulty == "medium":
        for part in ["adjective", "noun"]:
            if part in words and words[part]:
                parts.append(random.choice(words[part]))
    else:  # hard
        for part in ["article", "adjective", "noun", "verb", "adverb"]:
            if part in words and words[part]:
                parts.append(random.choice(words[part]))
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
    return jsonify(state)

@app.route("/set_mode", methods=["POST"])
def set_mode():
    mode = request.json.get("mode")
    if mode in ["send", "encode", "decode", "speed", "settings", "stats"]:
        state["mode"] = mode
        if mode == "decode":
            phrase = random_phrase(settings.get("difficulty", "medium"))
            state["current_phrase"] = phrase
            state["decode_result"] = ""
        elif mode == "speed":
            state["speed_phrase"] = random_phrase(settings.get("difficulty", "medium"))
            state["speed_result"] = ""
    return jsonify(state)

@app.route("/encode", methods=["POST"])
def encode():
    text = request.json.get("text", "")
    state["encode_input"] = text
    state["encode_output"] = morse_encode(text)
    return jsonify({"morse": state["encode_output"]})

@app.route("/play", methods=["POST"])
def play():
    morse = state["encode_output"]
    def _play():
        for symbol in morse:
            if symbol == '.':
                play_tone(settings["dot_freq"], settings["dot_max"])
                time.sleep(settings["dot_max"] * 0.5)
            elif symbol == '-':
                play_tone(settings["dash_freq"], settings["dot_max"] * 3)
                time.sleep(settings["dot_max"] * 0.5)
            elif symbol == ' ':
                time.sleep(settings["letter_gap"])
            elif symbol == '/':
                time.sleep(settings["word_gap"])
        stop_tone()
    threading.Thread(target=_play, daemon=True).start()
    return jsonify({"status": "playing"})

@app.route("/play_phrase", methods=["POST"])
def play_phrase():
    """Play the current decode quiz phrase as audio hint."""
    morse = morse_encode(state["current_phrase"])
    def _play():
        for symbol in morse:
            if symbol == '.':
                play_tone(settings["dot_freq"], settings["dot_max"])
                time.sleep(settings["dot_max"] * 0.3)
            elif symbol == '-':
                play_tone(settings["dash_freq"], settings["dot_max"] * 3)
                time.sleep(settings["dot_max"] * 0.3)
            elif symbol == ' ':
                time.sleep(settings["letter_gap"])
            elif symbol == '/':
                time.sleep(settings["word_gap"])
        stop_tone()
    threading.Thread(target=_play, daemon=True).start()
    return jsonify({"status": "playing"})

@app.route("/save_settings", methods=["POST"])
def save_settings_route():
    data = request.json
    for k, v in data.items():
        if k in settings:
            # Type coercion
            if isinstance(DEFAULT_SETTINGS.get(k), bool):
                settings[k] = bool(v) if not isinstance(v, bool) else v
            elif isinstance(DEFAULT_SETTINGS.get(k), int):
                settings[k] = int(v)
            elif isinstance(DEFAULT_SETTINGS.get(k), float):
                settings[k] = float(v)
            else:
                settings[k] = v
    save_settings_to_file(settings)
    recreate_gpio()
    return jsonify(settings)

@app.route("/preview_tone", methods=["POST"])
def preview_tone():
    freq = int(request.json.get("freq", settings["dot_freq"]))
    duration = float(request.json.get("duration", settings["dot_max"]))
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
    return jsonify({
        "result": result,
        "correct_answer": correct_phrase,
        "stats": state["stats"]
    })

@app.route("/submit_test", methods=["POST"])
def submit_test():
    input_morse = request.json.get("input", "").strip()
    start_time = request.json.get("start_time", 0)
    elapsed = request.json.get("elapsed", 1)

    if not input_morse:
        state["speed_result"] = "no_input"
        return jsonify({"result": "no_input"})

    decoded = morse_decode(input_morse).strip().upper()
    expected = state["speed_phrase"].strip().upper()
    correct = decoded == expected

    chars_typed = len(input_morse.replace(' ', '').replace('/', ''))
    wpm = round((chars_typed / 5) / (elapsed / 60), 1) if elapsed > 0 else 0

    state["stats"]["total_attempts"] += 1
    if correct:
        state["stats"]["correct"] += 1
        state["stats"]["streak"] += 1
        if state["stats"]["streak"] > state["stats"]["best_streak"]:
            state["stats"]["best_streak"] = state["stats"]["streak"]
    else:
        state["stats"]["streak"] = 0

    result_data = {
        "result": "correct" if correct else "wrong",
        "decoded": decoded,
        "expected": expected,
        "wpm": wpm,
        "stats": state["stats"]
    }
    return jsonify(result_data)

@app.route("/clear", methods=["POST"])
def clear():
    state["send_output"] = ""
    state["encode_output"] = ""
    state["encode_input"] = ""
    state["current_morse_buffer"] = ""
    send_buffer.clear()
    return jsonify(state)

@app.route("/toggle_cheat_sheet", methods=["POST"])
def toggle_cheat_sheet():
    state["cheat_sheet"] = not state["cheat_sheet"]
    return jsonify({"cheat_sheet": state["cheat_sheet"]})

@app.route("/get_settings")
def get_settings():
    return jsonify(settings)

@app.route("/key_press", methods=["POST"])
def key_press():
    """Simulate button press/release from keyboard (spacebar) in browser."""
    pressed = request.json.get("pressed", False)
    if pressed:
        send_button_pressed()
    else:
        send_button_released()
    return jsonify({"ok": True})

@app.route("/reset_stats", methods=["POST"])
def reset_stats():
    state["stats"] = {
        "total_attempts": 0, "correct": 0,
        "streak": 0, "best_streak": 0,
        "total_chars": 0, "sessions": []
    }
    return jsonify(state["stats"])

init_gpio()

if __name__ == "__main__":
    print("=== Morse Trainer Starting ===")
    print(f"  GPIO available: {GPIO_AVAILABLE}")
    print(f"  Beeper:         {'OK' if beeper else 'NOT INITIALIZED'}")
    print(f"  Built-in btn:   {'OK' if builtin_btn else 'NOT INITIALIZED'}")
    print(f"  External btn:   {'OK' if external_btn else 'NOT INITIALIZED'}")
    print(f"  Settings file:  {SETTINGS_FILE}")
    print(f"  Listening on:   http://0.0.0.0:5000")
    print("==============================")
    app.run(host="0.0.0.0", port=5000, debug=False, use_reloader=False)
