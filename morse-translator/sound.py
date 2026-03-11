# -*- coding: utf-8 -*-
"""Sound output, GPIO hardware initialisation, iambic keyer, and all
send / speed / network-key mode logic.

Depends on: shared, morse, keyboard, gpio_monitor
"""

import time
import threading

import shared
import morse
import keyboard
import gpio_monitor

# ══════════════════════════════════════════════════════════════════════════════
#  TIMING HELPERS
# ══════════════════════════════════════════════════════════════════════════════

def _get_dot_unit():
    """Dot element duration in seconds: 1200 ms / WPM."""
    wpm = max(5, int(shared.settings.get('wpm_target', 20)))
    return 1.2 / wpm


def _get_letter_gap_secs():
    """Letter gap (standard = 3 dot units, Farnsworth-aware)."""
    du = _get_dot_unit()
    if shared.settings.get('farnsworth_enabled'):
        mult = max(1.0, float(shared.settings.get('farnsworth_letter_mult', 2.0)))
        return du * 3 * mult
    return du * 3


def _get_word_extra_secs():
    """Extra gap beyond the letter gap at word boundaries (standard = 4 units)."""
    du = _get_dot_unit()
    if shared.settings.get('farnsworth_enabled'):
        mult = max(1.0, float(shared.settings.get('farnsworth_word_mult', 2.0)))
        return du * 4 * mult
    return du * 4


# ══════════════════════════════════════════════════════════════════════════════
#  LOW-LEVEL TONE / WAVE HELPERS
# ══════════════════════════════════════════════════════════════════════════════

def _stop_wave():
    """Stop any active pigpio waveform and set both speaker pins LOW."""
    if shared._pigpio and shared._wave_id is not None:
        try:
            shared._pigpio.wave_tx_stop()
            shared._pigpio.wave_delete(shared._wave_id)
        except Exception:
            pass
        shared._wave_id = None
    if shared._pigpio and shared._spk_pins[0] is not None:
        try:
            shared._pigpio.write(shared._spk_pins[0], 0)
        except Exception:
            pass
    if shared._pigpio and shared._spk_pins[1] is not None:
        try:
            shared._pigpio.write(shared._spk_pins[1], 0)
        except Exception:
            pass


def _start_wave(freq):
    """Start an anti-phase square wave on both speaker pins via pigpio."""
    _stop_wave()
    if not shared._pigpio or shared._spk_pins[0] is None or shared._spk_pins[1] is None:
        return False
    freq = max(100, min(4000, int(freq)))
    half_period_us = max(1, 500000 // freq)
    p1 = shared._spk_pins[0]
    p2 = shared._spk_pins[1]
    mask1 = 1 << p1
    mask2 = 1 << p2
    try:
        shared._pigpio.set_mode(p1, shared._pigpio_mod.OUTPUT)
        shared._pigpio.set_mode(p2, shared._pigpio_mod.OUTPUT)
        shared._pigpio.wave_clear()
        shared._pigpio.wave_add_generic([
            shared._pigpio_mod.pulse(mask1, mask2, half_period_us),
            shared._pigpio_mod.pulse(mask2, mask1, half_period_us),
        ])
        wid = shared._pigpio.wave_create()
        if wid >= 0:
            shared._wave_id = wid
            shared._pigpio.wave_send_repeat(wid)
            return True
        else:
            shared._wave_id = None
            return False
    except Exception as e:
        shared.gpio_error_log.append(f"_start_wave: {e}")
        shared._wave_id = None
        return False


# ══════════════════════════════════════════════════════════════════════════════
#  PUBLIC TONE API
# ══════════════════════════════════════════════════════════════════════════════

def play_tone(freq, duration=None, duty=None):
    """Play a tone.  Dual-pin pigpio wave or single-pin gpiozero PWM."""
    _dual = shared._spk_pins[1] is not None and shared._pigpio
    if not _dual and not shared.beeper:
        return
    gnd_mode = shared.settings.get("speaker_gnd_mode", "3v3")
    with shared.lock:
        try:
            output_type = shared.settings.get("output_type", "speaker")
            if _dual:
                if output_type == "led":
                    _stop_wave()
                    shared._pigpio.write(shared._spk_pins[0], 1)
                    shared._pigpio.write(shared._spk_pins[1], 0)
                else:
                    _start_wave(freq)
                if duration:
                    time.sleep(duration)
                    if output_type == "led":
                        shared._pigpio.write(shared._spk_pins[0], 0)
                        shared._pigpio.write(shared._spk_pins[1], 0)
                    else:
                        _stop_wave()
            else:
                vol = float(duty) if duty is not None else shared.settings["volume"]
                if output_type == "led":
                    shared.beeper.frequency = 1000
                    shared.beeper.value = 1.0
                    if shared.led_out2:
                        shared.led_out2.on()
                else:
                    vol = max(0.01, min(0.95, vol))
                    shared.beeper.frequency = max(100, min(4000, int(freq)))
                    shared.beeper.value = vol
                if duration:
                    time.sleep(duration)
                    if output_type == "led":
                        shared.beeper.value = 0
                        if shared.led_out2:
                            shared.led_out2.off()
                    else:
                        off_val = 1 if gnd_mode == "3v3" else 0
                        shared.beeper.value = off_val
        except Exception:
            pass


def stop_tone():
    """Stop any active tone output."""
    _dual = shared._spk_pins[1] is not None and shared._pigpio
    output_type = shared.settings.get("output_type", "speaker")
    if _dual:
        if output_type == "led":
            try:
                shared._pigpio.write(shared._spk_pins[0], 0)
                shared._pigpio.write(shared._spk_pins[1], 0)
            except Exception:
                pass
        else:
            _stop_wave()
    elif shared.beeper:
        try:
            if output_type == "led":
                shared.beeper.value = 0
                if shared.led_out2:
                    shared.led_out2.off()
            else:
                gnd_mode = shared.settings.get("speaker_gnd_mode", "3v3")
                shared.beeper.value = 1 if gnd_mode == "3v3" else 0
        except Exception:
            pass


def _play_morse_string(text):
    """Play plaintext as Morse code using proper WPM-based timing."""
    du = _get_dot_unit()
    chars = text.upper()
    for i, char in enumerate(chars):
        if char == ' ':
            time.sleep(_get_word_extra_secs())
            continue
        code = morse.MORSE_CODE.get(char)
        if not code or code == '/':
            continue
        for j, sym in enumerate(code):
            if sym == '.':
                play_tone(shared.settings["dot_freq"], du)
            elif sym == '-':
                play_tone(shared.settings["dash_freq"], du * 3)
            if j < len(code) - 1:
                time.sleep(du)
        if i < len(chars) - 1:
            time.sleep(_get_letter_gap_secs())
    stop_tone()


# ══════════════════════════════════════════════════════════════════════════════
#  GPIO HARDWARE INIT
# ══════════════════════════════════════════════════════════════════════════════

def init_gpio():
    """(Re)initialise all GPIO devices based on current settings."""
    if not shared.GPIO_AVAILABLE:
        return
    try:
        _stop_wave()
        for dev in [shared.beeper, shared.data_btn, shared.dot_btn,
                    shared.dash_btn, shared.ground_out, shared.led_out2]:
            if dev:
                try:
                    dev.close()
                except Exception:
                    pass
        shared.led_out2 = None
        for dev in shared.grounded_outputs:
            if dev:
                try:
                    dev.close()
                except Exception:
                    pass
        shared.grounded_outputs = []

        sp1 = shared.settings.get("speaker_pin")
        sp2 = shared.settings.get("speaker_pin2")
        shared._spk_pins = (sp1, sp2)
        output_type = shared.settings.get("output_type", "speaker")

        if sp2 is not None and shared._pigpio:
            shared.beeper = None
        elif sp2 is not None and output_type == "led" and not shared._pigpio:
            shared.beeper = shared.PWMOutputDevice(
                sp1, frequency=max(1, int(shared.settings["dot_freq"])), initial_value=0)
            shared.led_out2 = shared.OutputDevice(sp2, initial_value=False)
        else:
            gnd_mode = shared.settings.get("speaker_gnd_mode", "3v3")
            off_value = 1 if gnd_mode == "3v3" else 0
            shared.beeper = shared.PWMOutputDevice(
                sp1, frequency=max(1, int(shared.settings["dot_freq"])),
                initial_value=off_value)

        gp = shared.settings.get("ground_pin")
        if gp is not None:
            shared.ground_out = shared.OutputDevice(gp, initial_value=False)
        else:
            shared.ground_out = None

        grounded = shared.settings.get("grounded_pins", [])
        for pin in grounded:
            if pin is not None:
                try:
                    gnd_dev = shared.OutputDevice(int(pin), initial_value=False)
                    shared.grounded_outputs.append(gnd_dev)
                except Exception as e:
                    shared.gpio_error_log.append(f"ground pin {pin}: {e}")

        if shared.settings.get("pin_mode") == "dual":
            shared.dot_btn  = shared.Button(shared.settings["dot_pin"],  pull_up=True, bounce_time=0.005)
            shared.dash_btn = shared.Button(shared.settings["dash_pin"], pull_up=True, bounce_time=0.005)
            _start_keyer_thread()
        else:
            if shared.state["mode"] == "speed":
                shared.data_btn = shared.Button(shared.settings["data_pin"], pull_up=True, bounce_time=0.05)
                shared.data_btn.when_pressed  = speed_button_pressed
                shared.data_btn.when_released = speed_button_released
            else:
                shared.data_btn = shared.Button(shared.settings["data_pin"], pull_up=True, bounce_time=0.05)
                shared.data_btn.when_pressed  = send_button_pressed
                shared.data_btn.when_released = send_button_released
    except Exception as e:
        msg = f"init_gpio: {e}"
        print(msg)
        shared.gpio_error_log.append(msg)


def recreate_gpio():
    """Full GPIO teardown + rebuild (also resets virtual paddles)."""
    global _virtual_dot, _virtual_dash
    _stop_keyer_thread()
    _virtual_dot = _virtual_dash = False
    init_gpio()
    gpio_monitor.init_diag_readers()


# ══════════════════════════════════════════════════════════════════════════════
#  IAMBIC KEYER
# ══════════════════════════════════════════════════════════════════════════════
_KEYER_IDLE = 'IDLE'
_KEYER_DOT  = 'SENDING_DOT'
_KEYER_DASH = 'SENDING_DASH'
_KEYER_GAP  = 'INTER_ELEMENT_GAP'

keyer_state_label = _KEYER_IDLE
_keyer_stop       = threading.Event()
_keyer_thread_ref = None

# Virtual paddle state — driven by /key_press_dual in the browser
_virtual_dot  = False
_virtual_dash = False
_virtual_dot_timer  = None
_virtual_dash_timer = None


def _auto_release_virtual_key(sym):
    """Safety net: auto-release a virtual key after 3 s timeout."""
    global _virtual_dot, _virtual_dash
    if sym == 'dot':
        _virtual_dot = False
    elif sym == 'dash':
        _virtual_dash = False


def _keyer_emit(sym):
    """Append '.' or '-' into the buffer for the currently active mode."""
    mode = shared.state.get('mode', 'send')
    if mode == 'speed':
        speed_buffer.append(sym)
        shared.state['speed_morse_buffer'] = ''.join(speed_buffer)
    else:
        send_buffer.append(sym)
        shared.state['current_morse_buffer'] = ''.join(send_buffer)


def _keyer_do_finalize_letter():
    """Decode the accumulated buffer and commit the character to output."""
    mode = shared.state.get('mode', 'send')
    if mode == 'speed':
        if speed_buffer:
            code = ''.join(speed_buffer)
            shared.state['speed_morse_output'] += code + ' '
            shared.state['speed_morse_buffer'] = ''
            speed_buffer.clear()
    else:
        if send_buffer:
            code = ''.join(send_buffer)
            char = morse.REVERSE_MORSE.get(code, '?')
            shared.state['send_output']          += char
            shared.state['current_morse_buffer']  = ''
            send_buffer.clear()
            if shared.settings.get("kb_enabled", False) and shared.settings.get("kb_mode", "letters") == "letters":
                keyboard._hid_send_key(char)
                shared.state['kb_output'] = (shared.state.get('kb_output', '') + char)[-100:]


def _keyer_do_finalize_word():
    """Append a word separator to the active mode output."""
    mode = shared.state.get('mode', 'send')
    if mode == 'speed':
        out = shared.state['speed_morse_output']
        if out and not out.rstrip().endswith('/'):
            shared.state['speed_morse_output'] = out.rstrip() + ' / '
    else:
        out = shared.state['send_output']
        if out and not out.endswith(' '):
            shared.state['send_output'] += ' '
            if shared.settings.get("kb_enabled", False) and shared.settings.get("kb_mode", "letters") == "letters":
                keyboard._hid_send_key(' ')
                shared.state['kb_output'] = (shared.state.get('kb_output', '') + ' ')[-100:]


def _iambic_keyer_worker():
    """Electronic iambic keyer — Type A state machine (see original for docs)."""
    global keyer_state_label
    dot_memory  = False
    dash_memory = False
    last_sym    = None

    while not _keyer_stop.is_set():
        du     = _get_dot_unit()
        dot_p  = bool((shared.dot_btn and shared.dot_btn.is_pressed) or _virtual_dot)
        dash_p = bool((shared.dash_btn and shared.dash_btn.is_pressed) or _virtual_dash)

        if not dot_p and not dash_p and not dot_memory and not dash_memory:
            keyer_state_label = _KEYER_IDLE
            shared.state['button_active'] = False
            time.sleep(0.001)
            continue

        shared.state['button_active'] = True

        # Decide next element
        if dot_memory and not dash_p:
            sym = 'dot'; dot_memory = False
        elif dash_memory and not dot_p:
            sym = 'dash'; dash_memory = False
        elif dot_p and dash_p:
            sym = 'dash' if last_sym == 'dot' else 'dot'
        elif dot_p:
            sym = 'dot'
        else:
            sym = 'dash'
        last_sym = sym

        # ── SEND DOT ─────────────────────────────────────────────────────────
        if sym == 'dot':
            keyer_state_label = _KEYER_DOT
            _keyer_emit('.')
            shared.pin_states[shared.settings.get('dot_pin', 22)] = True
            play_tone(shared.settings['dot_freq'])
            if shared.settings.get("kb_enabled", False) and shared.settings.get("kb_mode") == "custom":
                key_char = shared.settings.get("kb_dot_key", "z")
                if keyboard._hid_send_custom_key(key_char):
                    dc = ' ' if key_char == 'space' else key_char
                    shared.state['kb_output'] = (shared.state.get('kb_output', '') + dc)[-100:]
            end = time.time() + du
            opp = False
            while time.time() < end and not _keyer_stop.is_set():
                if (shared.dash_btn and shared.dash_btn.is_pressed) or _virtual_dash:
                    opp = True
                time.sleep(0.001)
            stop_tone()
            shared.pin_states[shared.settings.get('dot_pin', 22)] = False
            if opp:
                dash_memory = True

        # ── SEND DASH ────────────────────────────────────────────────────────
        else:
            keyer_state_label = _KEYER_DASH
            _keyer_emit('-')
            shared.pin_states[shared.settings.get('dash_pin', 27)] = True
            play_tone(shared.settings['dash_freq'])
            if shared.settings.get("kb_enabled", False) and shared.settings.get("kb_mode") == "custom":
                key_char = shared.settings.get("kb_dash_key", "x")
                if keyboard._hid_send_custom_key(key_char):
                    dc = ' ' if key_char == 'space' else key_char
                    shared.state['kb_output'] = (shared.state.get('kb_output', '') + dc)[-100:]
            end = time.time() + du * 3
            opp = False
            while time.time() < end and not _keyer_stop.is_set():
                if (shared.dot_btn and shared.dot_btn.is_pressed) or _virtual_dot:
                    opp = True
                time.sleep(0.001)
            stop_tone()
            shared.pin_states[shared.settings.get('dash_pin', 27)] = False
            if opp:
                dot_memory = True

        # ── INTER-ELEMENT GAP ────────────────────────────────────────────────
        keyer_state_label = _KEYER_GAP
        end = time.time() + du
        while time.time() < end and not _keyer_stop.is_set():
            if (shared.dot_btn  and shared.dot_btn.is_pressed)  or _virtual_dot:  dot_memory  = True
            if (shared.dash_btn and shared.dash_btn.is_pressed) or _virtual_dash: dash_memory = True
            time.sleep(0.001)

        # ── Letter / word gap ─────────────────────────────────────────────────
        dot_p  = bool((shared.dot_btn  and shared.dot_btn.is_pressed)  or _virtual_dot)
        dash_p = bool((shared.dash_btn and shared.dash_btn.is_pressed) or _virtual_dash)
        if not dot_p and not dash_p and not dot_memory and not dash_memory:
            keyer_state_label = _KEYER_IDLE
            letter_remain = max(0.0, _get_letter_gap_secs() - du)
            t0 = time.time()
            while time.time() - t0 < letter_remain and not _keyer_stop.is_set():
                if (shared.dot_btn  and shared.dot_btn.is_pressed) or _virtual_dot or \
                   (shared.dash_btn and shared.dash_btn.is_pressed) or _virtual_dash:
                    break
                time.sleep(0.001)
            else:
                _keyer_do_finalize_letter()
                word_extra = _get_word_extra_secs()
                t0 = time.time()
                while time.time() - t0 < word_extra and not _keyer_stop.is_set():
                    if (shared.dot_btn  and shared.dot_btn.is_pressed) or _virtual_dot or \
                       (shared.dash_btn and shared.dash_btn.is_pressed) or _virtual_dash:
                        break
                    time.sleep(0.001)
                else:
                    _keyer_do_finalize_word()


def _start_keyer_thread():
    global _keyer_thread_ref
    _keyer_stop.clear()
    _keyer_thread_ref = threading.Thread(target=_iambic_keyer_worker, name='iambic_keyer', daemon=True)
    _keyer_thread_ref.start()


def _stop_keyer_thread():
    _keyer_stop.set()
    if _keyer_thread_ref and _keyer_thread_ref.is_alive():
        _keyer_thread_ref.join(timeout=0.5)


# ══════════════════════════════════════════════════════════════════════════════
#  SEND MODE
# ══════════════════════════════════════════════════════════════════════════════
send_buffer = []
send_active = False
send_press_time = 0
send_gap_timer = None
send_force_timer = None


def send_button_pressed():
    global send_active, send_press_time, send_gap_timer, send_force_timer
    send_active = True
    send_press_time = time.time()
    shared.state["button_active"] = True
    shared.pin_states[shared.settings.get("data_pin", 17)] = True
    if send_gap_timer:
        send_gap_timer.cancel()
    if send_force_timer:
        send_force_timer.cancel()
    play_tone(shared.settings["dot_freq"], duty=shared.settings["volume"])


def send_button_released():
    global send_active, send_gap_timer, send_force_timer
    send_active = False
    shared.state["button_active"] = False
    shared.pin_states[shared.settings.get("data_pin", 17)] = False
    stop_tone()
    duration = time.time() - send_press_time
    symbol = '.' if duration < _get_dot_unit() * 2 else '-'
    send_buffer.append(symbol)
    shared.state["current_morse_buffer"] = ''.join(send_buffer)

    if shared.settings.get("kb_enabled", False) and shared.settings.get("kb_mode") == "custom":
        key_char = shared.settings.get("kb_dot_key" if symbol == '.' else "kb_dash_key", "z")
        if keyboard._hid_send_custom_key(key_char):
            dc = ' ' if key_char == 'space' else key_char
            shared.state['kb_output'] = (shared.state.get('kb_output', '') + dc)[-100:]

    if send_gap_timer:
        send_gap_timer.cancel()
    send_gap_timer = threading.Timer(_get_letter_gap_secs(), finalize_letter)
    send_gap_timer.start()
    if send_force_timer:
        send_force_timer.cancel()
    send_force_timer = threading.Timer(_get_letter_gap_secs() + _get_dot_unit() * 2, finalize_letter)
    send_force_timer.start()


def finalize_letter():
    global send_gap_timer, send_force_timer
    if not send_active and send_buffer:
        code = ''.join(send_buffer)
        char = morse.REVERSE_MORSE.get(code, '?')
        shared.state["send_output"] += char
        shared.state["current_morse_buffer"] = ""
        send_buffer.clear()
        if shared.settings.get("kb_enabled", False) and shared.settings.get("kb_mode", "letters") == "letters":
            keyboard._hid_send_key(char)
            shared.state['kb_output'] = (shared.state.get('kb_output', '') + char)[-100:]
        send_gap_timer = threading.Timer(_get_word_extra_secs(), finalize_word)
        send_gap_timer.start()
        if send_force_timer:
            send_force_timer.cancel()
        send_force_timer = threading.Timer(_get_word_extra_secs() + _get_dot_unit() * 2, finalize_word)
        send_force_timer.start()


def finalize_word():
    if not send_active:
        if shared.state["send_output"] and not shared.state["send_output"].endswith(' '):
            shared.state["send_output"] += ' '
            if shared.settings.get("kb_enabled", False) and shared.settings.get("kb_mode", "letters") == "letters":
                keyboard._hid_send_key(' ')
                shared.state['kb_output'] = (shared.state.get('kb_output', '') + ' ')[-100:]


force_finalize_letter = finalize_letter
force_finalize_word   = finalize_word


# ══════════════════════════════════════════════════════════════════════════════
#  SPEED MODE
# ══════════════════════════════════════════════════════════════════════════════
speed_buffer = []
speed_active = False
speed_press_time = 0
speed_gap_timer = None
speed_force_timer = None


def speed_button_pressed():
    global speed_active, speed_press_time, speed_gap_timer, speed_force_timer
    speed_active = True
    speed_press_time = time.time()
    shared.state["button_active"] = True
    shared.pin_states[shared.settings.get("data_pin", 17)] = True
    if speed_gap_timer:
        speed_gap_timer.cancel()
    if speed_force_timer:
        speed_force_timer.cancel()
    play_tone(shared.settings["dot_freq"], duty=shared.settings["volume"])


def speed_button_released():
    global speed_active, speed_gap_timer, speed_force_timer
    speed_active = False
    shared.state["button_active"] = False
    shared.pin_states[shared.settings.get("data_pin", 17)] = False
    stop_tone()
    duration = time.time() - speed_press_time
    symbol = '.' if duration < _get_dot_unit() * 2 else '-'
    speed_buffer.append(symbol)
    shared.state["speed_morse_buffer"] = ''.join(speed_buffer)
    if speed_gap_timer:
        speed_gap_timer.cancel()
    speed_gap_timer = threading.Timer(_get_letter_gap_secs(), speed_finalize_letter)
    speed_gap_timer.start()
    if speed_force_timer:
        speed_force_timer.cancel()
    speed_force_timer = threading.Timer(_get_letter_gap_secs() + _get_dot_unit() * 2, speed_finalize_letter)
    speed_force_timer.start()


def speed_finalize_letter():
    global speed_gap_timer, speed_force_timer
    if not speed_active and speed_buffer:
        code = ''.join(speed_buffer)
        shared.state["speed_morse_output"] += code + ' '
        shared.state["speed_morse_buffer"] = ""
        speed_buffer.clear()
        speed_gap_timer = threading.Timer(_get_word_extra_secs(), speed_finalize_word)
        speed_gap_timer.start()
        if speed_force_timer:
            speed_force_timer.cancel()
        speed_force_timer = threading.Timer(_get_word_extra_secs() + _get_dot_unit() * 2, speed_finalize_word)
        speed_force_timer.start()


def speed_finalize_word():
    if not speed_active:
        if shared.state["speed_morse_output"] and not shared.state["speed_morse_output"].endswith('/'):
            shared.state["speed_morse_output"] += '/ '


speed_force_finalize_letter = speed_finalize_letter
speed_force_finalize_word   = speed_finalize_word


# ══════════════════════════════════════════════════════════════════════════════
#  NETWORK KEY MODE
# ══════════════════════════════════════════════════════════════════════════════
net_morse_buffer = []
net_morse_active = False
net_morse_press_time = 0
net_morse_gap_timer = None


def net_key_pressed():
    global net_morse_active, net_morse_press_time, net_morse_gap_timer
    net_morse_active = True
    net_morse_press_time = time.time()
    shared.state["button_active"] = True
    if net_morse_gap_timer:
        net_morse_gap_timer.cancel()
    play_tone(shared.settings["dot_freq"], duty=shared.settings["volume"])


def net_key_released():
    global net_morse_active, net_morse_gap_timer
    net_morse_active = False
    shared.state["button_active"] = False
    stop_tone()
    duration = time.time() - net_morse_press_time
    symbol = '.' if duration < _get_dot_unit() * 2 else '-'
    net_morse_buffer.append(symbol)
    shared.state["net_morse_buffer"] = ''.join(net_morse_buffer)
    if net_morse_gap_timer:
        net_morse_gap_timer.cancel()
    net_morse_gap_timer = threading.Timer(_get_letter_gap_secs(), net_finalize_letter)
    net_morse_gap_timer.start()


def net_finalize_letter():
    global net_morse_gap_timer
    if not net_morse_active and net_morse_buffer:
        code = ''.join(net_morse_buffer)
        char = morse.REVERSE_MORSE.get(code, '?')
        shared.state["net_morse_output"] += char
        shared.state["net_morse_buffer"] = ""
        net_morse_buffer.clear()
        net_morse_gap_timer = threading.Timer(_get_word_extra_secs(), net_finalize_word)
        net_morse_gap_timer.start()


def net_finalize_word():
    if not net_morse_active:
        if shared.state["net_morse_output"] and not shared.state["net_morse_output"].endswith(' '):
            shared.state["net_morse_output"] += ' '
