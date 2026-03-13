// ============================================================================
//  Morse-Pi — Sound output, GPIO hardware init, iambic keyer, and all
//  send / speed / network-key mode logic.
// ============================================================================
use crate::gpio;
use crate::keyboard;
use crate::morse;
use crate::state;
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

// ════════════════════════════════════════════════════════════════════════════
//  TIMING HELPERS
// ════════════════════════════════════════════════════════════════════════════

/// Dot element duration: 1200 ms / WPM.
pub fn get_dot_unit(wpm: i32) -> Duration {
    let wpm = wpm.max(5) as u64;
    Duration::from_millis(1200 / wpm)
}

fn get_farnsworth_wpm(settings: &state::Settings) -> i32 {
    settings.farnsworth_wpm.max(5).min(settings.wpm_target.max(5))
}

fn get_letter_gap(settings: &state::Settings) -> Duration {
    get_dot_unit(get_farnsworth_wpm(settings)) * 3
}

fn get_word_extra(settings: &state::Settings) -> Duration {
    get_dot_unit(get_farnsworth_wpm(settings)) * 4
}

pub fn get_dot_unit_secs(wpm: i32) -> f64 {
    let wpm_f = wpm.max(5) as f64;
    1.2 / wpm_f
}

fn radio_local_monitor_enabled() -> bool {
    let st = state::STATE.lock().unwrap();
    !st.net_live_transmit_enabled || st.settings.radio_local_monitor
}

fn radio_receive_enabled() -> bool {
    state::STATE.lock().unwrap().settings.radio_receive_enabled
}

fn tone_freq_for_symbol(sym: &str) -> u32 {
    let st = state::STATE.lock().unwrap();
    if sym == "dash" || sym == "-" {
        st.settings.dash_freq as u32
    } else {
        st.settings.dot_freq as u32
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  LOW-LEVEL TONE / WAVE HELPERS (pigpio)
// ════════════════════════════════════════════════════════════════════════════

fn stop_wave() {
    if !gpio::use_pigpio() { return; }
    let mut st = state::STATE.lock().unwrap();
    let pi = st.pi_handle;
    if pi < 0 { return; }
    if st.wave_id >= 0 {
        #[cfg(feature = "gpio")]
        {
            gpio::wave_stop(pi);
            gpio::wave_del(pi, st.wave_id as u32);
        }
        st.wave_id = -1;
    }
    if let Some(p1) = st.spk_pin1 { gpio::write_pin(pi, p1 as u32, 0); }
    if let Some(p2) = st.spk_pin2 { gpio::write_pin(pi, p2 as u32, 0); }
}

#[cfg(feature = "gpio")]
fn start_wave(freq: u32) -> bool {
    stop_wave();
    let mut st = state::STATE.lock().unwrap();
    let pi = st.pi_handle;
    if pi < 0 { return false; }
    let p1 = match st.spk_pin1 { Some(p) => p, None => return false };
    let p2 = match st.spk_pin2 { Some(p) => p, None => return false };
    let clamped_freq = freq.max(100).min(4000);
    let half_period_us = (500_000 / clamped_freq).max(1);
    let mask1: u32 = 1 << p1;
    let mask2: u32 = 1 << p2;

    gpio::set_pin_mode(pi, p1 as u32, gpio::PI_OUTPUT);
    gpio::set_pin_mode(pi, p2 as u32, gpio::PI_OUTPUT);
    gpio::wave_clr(pi);

    let mut pulses = [
        gpio::GpioPulse { gpio_on: mask1, gpio_off: mask2, us_delay: half_period_us },
        gpio::GpioPulse { gpio_on: mask2, gpio_off: mask1, us_delay: half_period_us },
    ];
    gpio::wave_add(pi, &mut pulses);
    let wid = gpio::wave_new(pi);
    if wid >= 0 {
        st.wave_id = wid;
        gpio::wave_repeat(pi, wid as u32);
        return true;
    }
    st.wave_id = -1;
    false
}

// ════════════════════════════════════════════════════════════════════════════
//  PUBLIC TONE API
// ════════════════════════════════════════════════════════════════════════════

pub fn play_tone(freq: u32, duration: Option<Duration>) {
    if !gpio::use_pigpio() { return; }
    let (pi, dual, is_led, spk1, spk2) = {
        let st = state::STATE.lock().unwrap();
        (
            st.pi_handle,
            st.spk_pin2.is_some(),
            st.settings.output_type == "led",
            st.spk_pin1,
            st.spk_pin2,
        )
    };
    if pi < 0 { return; }

    if dual {
        if is_led {
            stop_wave();
            if let Some(p1) = spk1 { gpio::write_pin(pi, p1 as u32, 1); }
            if let Some(p2) = spk2 { gpio::write_pin(pi, p2 as u32, 0); }
        } else {
            #[cfg(feature = "gpio")]
            { start_wave(freq); }
        }
        if let Some(dur) = duration {
            thread::sleep(dur);
            if is_led {
                if let Some(p1) = spk1 { gpio::write_pin(pi, p1 as u32, 0); }
                if let Some(p2) = spk2 { gpio::write_pin(pi, p2 as u32, 0); }
            } else {
                stop_wave();
            }
        }
    } else {
        // Single pin PWM
        if let Some(p1) = spk1 {
            if is_led {
                gpio::write_pin(pi, p1 as u32, 1);
            } else {
                let volume = {
                    let st = state::STATE.lock().unwrap();
                    st.settings.volume
                };
                let duty = (volume.max(0.01).min(0.95) * 1_000_000.0) as u32;
                gpio::hw_pwm(pi, p1 as u32, freq, duty);
            }
            if let Some(dur) = duration {
                thread::sleep(dur);
                if is_led {
                    gpio::write_pin(pi, p1 as u32, 0);
                } else {
                    gpio::hw_pwm(pi, p1 as u32, 0, 0);
                }
            }
        }
    }
}

pub fn stop_tone() {
    if !gpio::use_pigpio() { return; }
    let (pi, dual, is_led, spk1, spk2) = {
        let st = state::STATE.lock().unwrap();
        (
            st.pi_handle,
            st.spk_pin2.is_some(),
            st.settings.output_type == "led",
            st.spk_pin1,
            st.spk_pin2,
        )
    };
    if pi < 0 { return; }

    if dual {
        if is_led {
            if let Some(p1) = spk1 { gpio::write_pin(pi, p1 as u32, 0); }
            if let Some(p2) = spk2 { gpio::write_pin(pi, p2 as u32, 0); }
        } else {
            stop_wave();
        }
    } else if let Some(p1) = spk1 {
        if is_led {
            gpio::write_pin(pi, p1 as u32, 0);
        } else {
            gpio::hw_pwm(pi, p1 as u32, 0, 0);
        }
    }
}

/// Play plaintext as Morse code using proper WPM-based timing.
pub fn play_morse_string(text: &str) {
    let (wpm, farnsworth_wpm, dot_freq, dash_freq) = {
        let st = state::STATE.lock().unwrap();
        (
            st.settings.wpm_target,
            st.settings.farnsworth_wpm,
            st.settings.dot_freq,
            st.settings.dash_freq,
        )
    };
    let du = get_dot_unit(wpm);
    let settings = state::Settings {
        wpm_target: wpm,
        farnsworth_wpm,
        ..Default::default()
    };
    let letter_gap = get_letter_gap(&settings);
    let word_extra = get_word_extra(&settings);

    let chars: Vec<char> = text.chars().collect();
    for (i, &ch) in chars.iter().enumerate() {
        let c = ch.to_ascii_uppercase();
        if c == ' ' {
            thread::sleep(word_extra);
            continue;
        }
        let code = match morse::char_to_morse(c) {
            Some(code) => code,
            None => continue,
        };
        if code == "/" { continue; }
        let syms: Vec<char> = code.chars().collect();
        for (j, &sym) in syms.iter().enumerate() {
            if sym == '.' {
                play_tone(dot_freq as u32, Some(du));
            } else if sym == '-' {
                play_tone(dash_freq as u32, Some(du * 3));
            }
            if j < syms.len() - 1 {
                thread::sleep(du);
            }
        }
        if i < chars.len() - 1 {
            thread::sleep(letter_gap);
        }
    }
    stop_tone();
}

// ════════════════════════════════════════════════════════════════════════════
//  GPIO HARDWARE INIT
// ════════════════════════════════════════════════════════════════════════════

pub fn init_gpio() {
    let st = state::STATE.lock().unwrap();
    let pi = st.pi_handle;
    if !gpio::use_pigpio() || pi < 0 { return; }

    // Stop any existing wave
    drop(st);
    stop_wave();

    let mut st = state::STATE.lock().unwrap();
    let pi = st.pi_handle;
    st.spk_pin1 = if st.settings.speaker_pin >= 0 { Some(st.settings.speaker_pin) } else { None };
    st.spk_pin2 = st.settings.speaker_pin2;

    let settings = st.settings.clone();
    let spk1 = st.spk_pin1;
    let spk2 = st.spk_pin2;
    drop(st);

    // Set up speaker pins
    if let Some(p1) = spk1 { gpio::setup_output_pin(pi, p1); }
    if let Some(p2) = spk2 { gpio::setup_output_pin(pi, p2); }

    // Set up ground pins
    if let Some(gp) = settings.ground_pin {
        gpio::setup_output_pin(pi, gp);
        gpio::write_pin(pi, gp as u32, 0);
    }
    for &gp in &settings.grounded_pins {
        gpio::setup_output_pin(pi, gp);
        gpio::write_pin(pi, gp as u32, 0);
    }

    // Set up key/button pins
    if settings.pin_mode == "dual" {
        gpio::setup_input_pin(pi, settings.dot_pin);
        gpio::setup_input_pin(pi, settings.dash_pin);
        start_keyer_thread();
    } else {
        gpio::setup_input_pin(pi, settings.data_pin);
        start_straight_key_thread();
    }
}

pub fn recreate_gpio() {
    stop_keyer_thread();
    stop_straight_key_thread();
    VIRTUAL_DOT.store(false, Ordering::Relaxed);
    VIRTUAL_DASH.store(false, Ordering::Relaxed);
    init_gpio();
}

// ════════════════════════════════════════════════════════════════════════════
//  IAMBIC KEYER
// ════════════════════════════════════════════════════════════════════════════

pub static KEYER_STATE_LABEL: once_cell::sync::Lazy<Mutex<String>> =
    once_cell::sync::Lazy::new(|| Mutex::new("IDLE".into()));
static KEYER_STOP: AtomicBool = AtomicBool::new(false);
static KEYER_RUNNING: AtomicBool = AtomicBool::new(false);

pub static VIRTUAL_DOT: AtomicBool = AtomicBool::new(false);
pub static VIRTUAL_DASH: AtomicBool = AtomicBool::new(false);

static STRAIGHT_KEY_STOP: AtomicBool = AtomicBool::new(false);
static STRAIGHT_KEY_RUNNING: AtomicBool = AtomicBool::new(false);

fn is_dot_pressed() -> bool {
    if VIRTUAL_DOT.load(Ordering::Relaxed) { return true; }
    let st = state::STATE.lock().unwrap();
    if !gpio::use_pigpio() || st.pi_handle < 0 { return false; }
    // Active-low: pull-up resistor means pin reads HIGH when open, LOW when pressed
    gpio::read_pin(st.pi_handle, st.settings.dot_pin as u32) == Some(false)
}

fn is_dash_pressed() -> bool {
    if VIRTUAL_DASH.load(Ordering::Relaxed) { return true; }
    let st = state::STATE.lock().unwrap();
    if !gpio::use_pigpio() || st.pi_handle < 0 { return false; }
    // Active-low: pull-up resistor means pin reads HIGH when open, LOW when pressed
    gpio::read_pin(st.pi_handle, st.settings.dash_pin as u32) == Some(false)
}

fn keyer_emit(sym: char) {
    let mut st = state::STATE.lock().unwrap();
    if st.mode == "speed" {
        st.speed_morse_buffer.push(sym);
    } else {
        st.current_morse_buffer.push(sym);
    }
}

fn keyer_finalize_letter() {
    let mut st = state::STATE.lock().unwrap();
    if st.mode == "speed" {
        if !st.speed_morse_buffer.is_empty() {
            let buf = st.speed_morse_buffer.clone();
            st.speed_morse_output.push_str(&buf);
            st.speed_morse_output.push(' ');
            st.speed_morse_buffer.clear();
        }
    } else {
        if !st.current_morse_buffer.is_empty() {
            let ch = morse::morse_to_char(&st.current_morse_buffer);
            st.send_output.push(ch);
            st.current_morse_buffer.clear();
            let kb_enabled = st.settings.kb_enabled;
            let kb_mode = st.settings.kb_mode.clone();
            if kb_enabled && kb_mode == "letters" {
                keyboard::send_key(ch, kb_enabled);
                st.kb_output.push(ch);
            }
        }
    }
}

fn keyer_finalize_word() {
    let mut st = state::STATE.lock().unwrap();
    if st.mode == "speed" {
        if !st.speed_morse_output.is_empty() && !st.speed_morse_output.ends_with('/') {
            st.speed_morse_output.push_str("/ ");
        }
    } else {
        if !st.send_output.is_empty() && !st.send_output.ends_with(' ') {
            st.send_output.push(' ');
            let kb_enabled = st.settings.kb_enabled;
            let kb_mode = st.settings.kb_mode.clone();
            if kb_enabled && kb_mode == "letters" {
                keyboard::send_key(' ', kb_enabled);
                st.kb_output.push(' ');
            }
        }
    }
}

fn iambic_keyer_worker() {
    let mut dot_memory = false;
    let mut dash_memory = false;
    let mut last_sym: Option<bool> = None; // Some(true)=dot, Some(false)=dash

    while !KEYER_STOP.load(Ordering::Relaxed) {
        let (du, settings) = {
            let st = state::STATE.lock().unwrap();
            (get_dot_unit(st.settings.wpm_target), st.settings.clone())
        };
        let dot_p = is_dot_pressed();
        let dash_p = is_dash_pressed();

        if !dot_p && !dash_p && !dot_memory && !dash_memory {
            *KEYER_STATE_LABEL.lock().unwrap() = "IDLE".into();
            state::STATE.lock().unwrap().button_active = false;
            thread::sleep(Duration::from_millis(1));
            continue;
        }

        state::STATE.lock().unwrap().button_active = true;

        // Decide next element
        let is_dot = if dot_memory && !dash_p {
            dot_memory = false;
            true
        } else if dash_memory && !dot_p {
            dash_memory = false;
            false
        } else if dot_p && dash_p {
            last_sym != Some(true)  // alternate
        } else {
            dot_p
        };
        last_sym = Some(is_dot);

        // Send element
        if is_dot {
            *KEYER_STATE_LABEL.lock().unwrap() = "SENDING_DOT".into();
            keyer_emit('.');
            send_live_key_to_peer(true, "dot");
            if radio_local_monitor_enabled() {
                play_tone(settings.dot_freq as u32, None);
            }
            if settings.kb_enabled && settings.kb_mode == "custom" {
                keyboard::send_custom_key(&settings.kb_dot_key, settings.kb_enabled);
            }
            let end = Instant::now() + du;
            let mut opp = false;
            while Instant::now() < end && !KEYER_STOP.load(Ordering::Relaxed) {
                if is_dash_pressed() { opp = true; }
                thread::sleep(Duration::from_millis(1));
            }
            stop_tone();
            send_live_key_to_peer(false, "dot");
            if opp { dash_memory = true; }
        } else {
            *KEYER_STATE_LABEL.lock().unwrap() = "SENDING_DASH".into();
            keyer_emit('-');
            send_live_key_to_peer(true, "dash");
            if radio_local_monitor_enabled() {
                play_tone(settings.dash_freq as u32, None);
            }
            if settings.kb_enabled && settings.kb_mode == "custom" {
                keyboard::send_custom_key(&settings.kb_dash_key, settings.kb_enabled);
            }
            let end = Instant::now() + du * 3;
            let mut opp = false;
            while Instant::now() < end && !KEYER_STOP.load(Ordering::Relaxed) {
                if is_dot_pressed() { opp = true; }
                thread::sleep(Duration::from_millis(1));
            }
            stop_tone();
            send_live_key_to_peer(false, "dash");
            if opp { dot_memory = true; }
        }

        // Inter-element gap
        *KEYER_STATE_LABEL.lock().unwrap() = "INTER_ELEMENT_GAP".into();
        {
            let end = Instant::now() + du;
            while Instant::now() < end && !KEYER_STOP.load(Ordering::Relaxed) {
                if is_dot_pressed() { dot_memory = true; }
                if is_dash_pressed() { dash_memory = true; }
                thread::sleep(Duration::from_millis(1));
            }
        }

        // Letter / word gap
        if !is_dot_pressed() && !is_dash_pressed() && !dot_memory && !dash_memory {
            *KEYER_STATE_LABEL.lock().unwrap() = "IDLE".into();
            let letter_remain = get_letter_gap(&settings).saturating_sub(du);
            let t0 = Instant::now();
            let mut broken = false;
            while Instant::now() - t0 < letter_remain && !KEYER_STOP.load(Ordering::Relaxed) {
                if is_dot_pressed() || is_dash_pressed() { broken = true; break; }
                thread::sleep(Duration::from_millis(1));
            }
            if !broken {
                keyer_finalize_letter();
                let word_extra = get_word_extra(&settings);
                let t1 = Instant::now();
                let mut broken2 = false;
                while Instant::now() - t1 < word_extra && !KEYER_STOP.load(Ordering::Relaxed) {
                    if is_dot_pressed() || is_dash_pressed() { broken2 = true; break; }
                    thread::sleep(Duration::from_millis(1));
                }
                if !broken2 { keyer_finalize_word(); }
            }
        }
    }
    KEYER_RUNNING.store(false, Ordering::Relaxed);
}

fn start_keyer_thread() {
    KEYER_STOP.store(false, Ordering::Relaxed);
    if KEYER_RUNNING.load(Ordering::Relaxed) { return; }
    KEYER_RUNNING.store(true, Ordering::Relaxed);
    thread::spawn(iambic_keyer_worker);
}

fn stop_keyer_thread() {
    KEYER_STOP.store(true, Ordering::Relaxed);
    // Wait for thread to exit
    while KEYER_RUNNING.load(Ordering::Relaxed) {
        thread::sleep(Duration::from_millis(5));
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  STRAIGHT KEY GPIO POLLING  (single-pin mode)
// ════════════════════════════════════════════════════════════════════════════

fn straight_key_worker() {
    let mut was_pressed = false;
    while !STRAIGHT_KEY_STOP.load(Ordering::Relaxed) {
        // Read pin and current mode under a single lock scope
        let (pressed, mode) = {
            let st = state::STATE.lock().unwrap();
            if !gpio::use_pigpio() || st.pi_handle < 0 {
                drop(st);
                thread::sleep(Duration::from_millis(50));
                continue;
            }
            let p = gpio::read_pin(st.pi_handle, st.settings.data_pin as u32)
                        == Some(false);          // active-low
            let m = st.mode.clone();
            (p, m)
        };
        // STATE lock is dropped — safe to call press/release functions

        if pressed != was_pressed {
            was_pressed = pressed;
            if pressed {
                match mode.as_str() {
                    "speed"   => speed_button_pressed(),
                    "network" => net_key_pressed(),
                    _         => send_button_pressed(),
                }
            } else {
                match mode.as_str() {
                    "speed"   => speed_button_released(),
                    "network" => net_key_released(),
                    _         => send_button_released(),
                }
            }
            thread::sleep(Duration::from_millis(50)); // debounce
        } else {
            thread::sleep(Duration::from_millis(5));
        }
    }
    STRAIGHT_KEY_RUNNING.store(false, Ordering::Relaxed);
}

fn start_straight_key_thread() {
    STRAIGHT_KEY_STOP.store(false, Ordering::Relaxed);
    if STRAIGHT_KEY_RUNNING.load(Ordering::Relaxed) { return; }
    STRAIGHT_KEY_RUNNING.store(true, Ordering::Relaxed);
    thread::spawn(straight_key_worker);
}

fn stop_straight_key_thread() {
    STRAIGHT_KEY_STOP.store(true, Ordering::Relaxed);
    while STRAIGHT_KEY_RUNNING.load(Ordering::Relaxed) {
        thread::sleep(Duration::from_millis(5));
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  SEND MODE (single key — straight key)
// ════════════════════════════════════════════════════════════════════════════

static SEND_BUFFER: once_cell::sync::Lazy<Mutex<Vec<char>>> =
    once_cell::sync::Lazy::new(|| Mutex::new(Vec::new()));
static SEND_ACTIVE: AtomicBool = AtomicBool::new(false);
static SEND_PRESS_TIME: once_cell::sync::Lazy<Mutex<Instant>> =
    once_cell::sync::Lazy::new(|| Mutex::new(Instant::now()));

pub fn send_button_pressed() {
    SEND_ACTIVE.store(true, Ordering::Relaxed);
    *SEND_PRESS_TIME.lock().unwrap() = Instant::now();
    state::STATE.lock().unwrap().button_active = true;
    let freq = state::STATE.lock().unwrap().settings.dot_freq;
    send_live_key_to_peer(true, "single");
    if radio_local_monitor_enabled() {
        play_tone(freq as u32, None);
    }
}

pub fn send_button_released() {
    SEND_ACTIVE.store(false, Ordering::Relaxed);
    state::STATE.lock().unwrap().button_active = false;
    send_live_key_to_peer(false, "single");
    stop_tone();
    let duration = SEND_PRESS_TIME.lock().unwrap().elapsed();
    let wpm = state::STATE.lock().unwrap().settings.wpm_target;
    let dot_unit = get_dot_unit(wpm);
    let symbol: char = if duration < dot_unit * 2 { '.' } else { '-' };
    {
        let mut buf = SEND_BUFFER.lock().unwrap();
        buf.push(symbol);
        let buf_str: String = buf.iter().collect();
        state::STATE.lock().unwrap().current_morse_buffer = buf_str;
    }

    // Keyboard custom mode
    {
        let st = state::STATE.lock().unwrap();
        if st.settings.kb_enabled && st.settings.kb_mode == "custom" {
            let key = if symbol == '.' {
                st.settings.kb_dot_key.clone()
            } else {
                st.settings.kb_dash_key.clone()
            };
            keyboard::send_custom_key(&key, st.settings.kb_enabled);
        }
    }

    // Finalize letter after letter gap
    thread::spawn(send_gap_worker);
}

fn send_gap_worker() {
    let settings = state::STATE.lock().unwrap().settings.clone();
    thread::sleep(get_letter_gap(&settings));
    if !SEND_ACTIVE.load(Ordering::Relaxed) {
        let mut buf = SEND_BUFFER.lock().unwrap();
        if !buf.is_empty() {
            let buf_str: String = buf.iter().collect();
            let ch = morse::morse_to_char(&buf_str);
            let mut st = state::STATE.lock().unwrap();
            st.send_output.push(ch);
            st.current_morse_buffer.clear();
            buf.clear();
            let kb_enabled = st.settings.kb_enabled;
            let kb_mode = st.settings.kb_mode.clone();
            if kb_enabled && kb_mode == "letters" {
                keyboard::send_key(ch, kb_enabled);
                st.kb_output.push(ch);
            }
            drop(st);

            // Wait for word gap
            thread::sleep(get_word_extra(&settings));
            if !SEND_ACTIVE.load(Ordering::Relaxed) {
                let mut st = state::STATE.lock().unwrap();
                if !st.send_output.is_empty() && !st.send_output.ends_with(' ') {
                    st.send_output.push(' ');
                    let kb_enabled = st.settings.kb_enabled;
                    let kb_mode = st.settings.kb_mode.clone();
                    if kb_enabled && kb_mode == "letters" {
                        keyboard::send_key(' ', kb_enabled);
                        st.kb_output.push(' ');
                    }
                }
            }
        }
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  SPEED MODE
// ════════════════════════════════════════════════════════════════════════════

static SPEED_BUFFER: once_cell::sync::Lazy<Mutex<Vec<char>>> =
    once_cell::sync::Lazy::new(|| Mutex::new(Vec::new()));
pub static SPEED_ACTIVE: AtomicBool = AtomicBool::new(false);
static SPEED_PRESS_TIME: once_cell::sync::Lazy<Mutex<Instant>> =
    once_cell::sync::Lazy::new(|| Mutex::new(Instant::now()));

pub fn speed_button_pressed() {
    SPEED_ACTIVE.store(true, Ordering::Relaxed);
    *SPEED_PRESS_TIME.lock().unwrap() = Instant::now();
    state::STATE.lock().unwrap().button_active = true;
    let freq = state::STATE.lock().unwrap().settings.dot_freq;
    send_live_key_to_peer(true, "single");
    if radio_local_monitor_enabled() {
        play_tone(freq as u32, None);
    }
}

pub fn speed_button_released() {
    SPEED_ACTIVE.store(false, Ordering::Relaxed);
    state::STATE.lock().unwrap().button_active = false;
    send_live_key_to_peer(false, "single");
    stop_tone();
    let duration = SPEED_PRESS_TIME.lock().unwrap().elapsed();
    let wpm = state::STATE.lock().unwrap().settings.wpm_target;
    let dot_unit = get_dot_unit(wpm);
    let symbol: char = if duration < dot_unit * 2 { '.' } else { '-' };
    {
        let mut buf = SPEED_BUFFER.lock().unwrap();
        buf.push(symbol);
        let buf_str: String = buf.iter().collect();
        state::STATE.lock().unwrap().speed_morse_buffer = buf_str;
    }

    thread::spawn(speed_gap_worker);
}

fn speed_gap_worker() {
    let settings = state::STATE.lock().unwrap().settings.clone();
    thread::sleep(get_letter_gap(&settings));
    if !SPEED_ACTIVE.load(Ordering::Relaxed) {
        let mut buf = SPEED_BUFFER.lock().unwrap();
        if !buf.is_empty() {
            let code: String = buf.iter().collect();
            let mut st = state::STATE.lock().unwrap();
            st.speed_morse_output.push_str(&code);
            st.speed_morse_output.push(' ');
            st.speed_morse_buffer.clear();
            buf.clear();
            drop(st);

            // Wait for word gap
            thread::sleep(get_word_extra(&settings));
            if !SPEED_ACTIVE.load(Ordering::Relaxed) {
                let mut st = state::STATE.lock().unwrap();
                if !st.speed_morse_output.is_empty() && !st.speed_morse_output.ends_with('/') {
                    st.speed_morse_output.push_str("/ ");
                }
            }
        }
    }
}

pub fn clear_speed_buffers() {
    SPEED_BUFFER.lock().unwrap().clear();
    SPEED_ACTIVE.store(false, Ordering::Relaxed);
}

pub fn clear_send_buffers() {
    SEND_BUFFER.lock().unwrap().clear();
}

// ════════════════════════════════════════════════════════════════════════════
//  NETWORK KEY MODE
// ════════════════════════════════════════════════════════════════════════════

static NET_MORSE_BUFFER: once_cell::sync::Lazy<Mutex<Vec<char>>> =
    once_cell::sync::Lazy::new(|| Mutex::new(Vec::new()));
static NET_MORSE_ACTIVE: AtomicBool = AtomicBool::new(false);
static NET_MORSE_PRESS_TIME: once_cell::sync::Lazy<Mutex<Instant>> =
    once_cell::sync::Lazy::new(|| Mutex::new(Instant::now()));

static NET_RECEIVE_BUFFER: once_cell::sync::Lazy<Mutex<Vec<char>>> =
    once_cell::sync::Lazy::new(|| Mutex::new(Vec::new()));
static NET_RECEIVE_ACTIVE: AtomicBool = AtomicBool::new(false);
static NET_RECEIVE_PRESS_TIME: once_cell::sync::Lazy<Mutex<Instant>> =
    once_cell::sync::Lazy::new(|| Mutex::new(Instant::now()));
static NET_RECEIVE_LAST_SYM: once_cell::sync::Lazy<Mutex<String>> =
    once_cell::sync::Lazy::new(|| Mutex::new("single".into()));
static NET_RECEIVE_SEQ: AtomicU64 = AtomicU64::new(0);

pub fn net_key_pressed() {
    NET_MORSE_ACTIVE.store(true, Ordering::Relaxed);
    *NET_MORSE_PRESS_TIME.lock().unwrap() = Instant::now();
    state::STATE.lock().unwrap().button_active = true;
    let freq = state::STATE.lock().unwrap().settings.dot_freq;
    send_live_key_to_peer(true, "single");
    if radio_local_monitor_enabled() {
        play_tone(freq as u32, None);
    }
}

pub fn net_key_released() {
    NET_MORSE_ACTIVE.store(false, Ordering::Relaxed);
    state::STATE.lock().unwrap().button_active = false;
    send_live_key_to_peer(false, "single");
    stop_tone();
    let duration = NET_MORSE_PRESS_TIME.lock().unwrap().elapsed();
    let wpm = state::STATE.lock().unwrap().settings.wpm_target;
    let dot_unit = get_dot_unit(wpm);
    let symbol: char = if duration < dot_unit * 2 { '.' } else { '-' };

    {
        let mut buf = NET_MORSE_BUFFER.lock().unwrap();
        buf.push(symbol);
        let buf_str: String = buf.iter().collect();
        state::STATE.lock().unwrap().net_morse_buffer_str = buf_str;
    }

    thread::spawn(net_gap_worker);
}

fn net_gap_worker() {
    let settings = state::STATE.lock().unwrap().settings.clone();
    thread::sleep(get_letter_gap(&settings));
    if !NET_MORSE_ACTIVE.load(Ordering::Relaxed) {
        let mut buf = NET_MORSE_BUFFER.lock().unwrap();
        if !buf.is_empty() {
            let code: String = buf.iter().collect();
            let ch = morse::morse_to_char(&code);
            let mut st = state::STATE.lock().unwrap();
            st.net_morse_output_str.push(ch);
            st.net_morse_buffer_str.clear();
            buf.clear();
            drop(st);

            thread::sleep(get_word_extra(&settings));
            if !NET_MORSE_ACTIVE.load(Ordering::Relaxed) {
                let mut st = state::STATE.lock().unwrap();
                if !st.net_morse_output_str.is_empty() && !st.net_morse_output_str.ends_with(' ') {
                    st.net_morse_output_str.push(' ');
                }
            }
        }
    }
}

pub fn clear_net_morse_buffers() {
    NET_MORSE_BUFFER.lock().unwrap().clear();
}

fn net_receive_push_symbol(symbol: char) -> u64 {
    let snapshot = {
        let mut buf = NET_RECEIVE_BUFFER.lock().unwrap();
        buf.push(symbol);
        buf.iter().collect::<String>()
    };
    state::STATE.lock().unwrap().net_receive_morse_buffer_str = snapshot;
    NET_RECEIVE_SEQ.fetch_add(1, Ordering::Relaxed) + 1
}

fn net_receive_finalize_letter() {
    let code = {
        let mut buf = NET_RECEIVE_BUFFER.lock().unwrap();
        if buf.is_empty() {
            None
        } else {
            let s: String = buf.iter().collect();
            buf.clear();
            Some(s)
        }
    };

    if let Some(morse_code) = code {
        let ch = morse::morse_to_char(&morse_code);
        let mut st = state::STATE.lock().unwrap();
        st.net_receive_output_str.push(ch);
        st.net_receive_morse_buffer_str.clear();
    }
}

fn net_receive_finalize_word() {
    let mut st = state::STATE.lock().unwrap();
    if !st.net_receive_output_str.is_empty() && !st.net_receive_output_str.ends_with(' ') {
        st.net_receive_output_str.push(' ');
    }
}

fn net_receive_gap_worker(expected_seq: u64) {
    let settings = state::STATE.lock().unwrap().settings.clone();

    thread::sleep(get_letter_gap(&settings));
    let seq_now = NET_RECEIVE_SEQ.load(Ordering::Relaxed);
    if seq_now == expected_seq && !NET_RECEIVE_ACTIVE.load(Ordering::Relaxed) {
        net_receive_finalize_letter();

        thread::sleep(get_word_extra(&settings));
        let seq_after_word_wait = NET_RECEIVE_SEQ.load(Ordering::Relaxed);
        if seq_after_word_wait == expected_seq && !NET_RECEIVE_ACTIVE.load(Ordering::Relaxed) {
            net_receive_finalize_word();
        }
    }
}

/// Receive a live key-down event from a remote peer — start tone indefinitely.
pub fn net_live_receive_key_down(sym: &str) {
    NET_RECEIVE_ACTIVE.store(true, Ordering::Relaxed);
    *NET_RECEIVE_PRESS_TIME.lock().unwrap() = Instant::now();
    *NET_RECEIVE_LAST_SYM.lock().unwrap() = sym.to_string();

    if radio_receive_enabled() {
        let freq = tone_freq_for_symbol(sym);
        play_tone(freq, None);
    }
    state::STATE.lock().unwrap().button_active = true;
}

/// Receive a live key-up event from a remote peer — stop tone immediately.
pub fn net_live_receive_key_up() {
    let was_active = NET_RECEIVE_ACTIVE.swap(false, Ordering::Relaxed);
    stop_tone();
    state::STATE.lock().unwrap().button_active = false;
    if !was_active { return; }

    let last_sym = NET_RECEIVE_LAST_SYM.lock().unwrap().clone();
    let symbol = match last_sym.as_str() {
        "dot" | "." => '.',
        "dash" | "-" => '-',
        _ => {
            let duration = NET_RECEIVE_PRESS_TIME.lock().unwrap().elapsed();
            let wpm = state::STATE.lock().unwrap().settings.wpm_target;
            let dot_unit = get_dot_unit(wpm);
            if duration < dot_unit * 2 { '.' } else { '-' }
        }
    };

    let seq = net_receive_push_symbol(symbol);
    thread::spawn(move || net_receive_gap_worker(seq));
}

/// Forward a live key_down or key_up event to the peer, if live transmit is active.
/// Spawns a background thread so the caller is not blocked.
fn send_live_key_to_peer(pressed: bool, sym: &str) {
    let (enabled, remote_enabled, tx_mode, selected, ip, port, dev_name, dev_uuid) = {
        let st = state::STATE.lock().unwrap();
        (
            st.net_live_transmit_enabled,
            st.settings.radio_remote_monitor,
            st.net_tx_mode.clone(),
            st.net_selected_peer_uuids.clone(),
            st.net_live_transmit_target_ip.clone(),
            st.net_live_transmit_target_port,
            st.settings.device_name.clone(),
            crate::network::device_uuid().to_string(),
        )
    };

    if !enabled || !remote_enabled { return; }

    let peers = crate::network::peers_snapshot();
    let selected_set: HashSet<String> = selected.into_iter().collect();
    let mut targets: Vec<(String, u16)> = Vec::new();

    match tx_mode.as_str() {
        "all_on_air" => {
            for p in peers {
                if p.on_air {
                    targets.push((p.ip, p.port));
                }
            }
        }
        "selected" => {
            for p in peers {
                if selected_set.contains(&p.uuid) && p.on_air {
                    targets.push((p.ip, p.port));
                }
            }
            if targets.is_empty() && selected_set.is_empty() && !ip.is_empty() {
                targets.push((ip, port));
            }
        }
        _ => {
            if !ip.is_empty() {
                targets.push((ip, port));
            }
        }
    }

    let mut uniq = HashSet::new();
    for (t_ip, t_port) in targets {
        let key = format!("{}:{}", t_ip, t_port);
        if !uniq.insert(key) { continue; }
        let sym_copy = sym.to_string();
        let name_copy = dev_name.clone();
        let uuid_copy = dev_uuid.clone();
        thread::spawn(move || {
            crate::network::send_live_key_http(&t_ip, t_port, pressed, &sym_copy, &name_copy, &uuid_copy);
        });
    }
}

pub fn forward_live_key_to_peers(pressed: bool, sym: &str) {
    send_live_key_to_peer(pressed, sym);
}

/// Play a live morse symbol (. or -) from a remote peer.
pub fn play_live_morse_symbol(symbol: &str) {
    if symbol != "." && symbol != "-" { return; }

    let wpm = state::STATE.lock().unwrap().settings.wpm_target;
    let dot_unit = get_dot_unit(wpm);
    let freq = if symbol == "." {
        state::STATE.lock().unwrap().settings.dot_freq as u32
    } else {
        state::STATE.lock().unwrap().settings.dash_freq as u32
    };

    let duration = if symbol == "." { dot_unit } else { dot_unit * 3 };
    NET_RECEIVE_ACTIVE.store(true, Ordering::Relaxed);
    state::STATE.lock().unwrap().button_active = true;

    if radio_receive_enabled() {
        play_tone(freq, Some(duration));
    } else {
        thread::sleep(duration);
    }

    NET_RECEIVE_ACTIVE.store(false, Ordering::Relaxed);
    state::STATE.lock().unwrap().button_active = false;

    let seq = net_receive_push_symbol(if symbol == "." { '.' } else { '-' });
    thread::spawn(move || net_receive_gap_worker(seq));
}

