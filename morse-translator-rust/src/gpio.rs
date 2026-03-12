// ============================================================================
//  Morse-Pi — GPIO monitoring via pigpiod_if2 C library.
//
//  Reads every BCM pin plus fixed power rails.  Polls pin state in a
//  background thread for the diagnostic page and the status API.
//
//  When compiled without the "gpio" feature, all functions are no-ops.
// ============================================================================
use crate::state;
use std::thread;
use std::time::Duration;

// ── pigpio C bindings (only when compiled with --features gpio) ──────────────

#[cfg(feature = "gpio")]
#[link(name = "pigpiod_if2")]
extern "C" {
    fn pigpio_start(addr: *const i8, port: *const i8) -> i32;
    fn pigpio_stop(pi: i32);
    fn set_mode(pi: i32, gpio: u32, mode: u32) -> i32;
    fn gpio_read(pi: i32, gpio: u32) -> i32;
    fn gpio_write(pi: i32, gpio: u32, level: u32) -> i32;
    fn set_pull_up_down(pi: i32, gpio: u32, pud: u32) -> i32;
    fn set_PWM_frequency(pi: i32, gpio: u32, frequency: u32) -> i32;
    fn set_PWM_dutycycle(pi: i32, gpio: u32, dutycycle: u32) -> i32;
    fn hardware_PWM(pi: i32, gpio: u32, freq: u32, duty: u32) -> i32;
    fn wave_clear(pi: i32) -> i32;
    fn wave_add_generic(pi: i32, num_pulses: u32, pulses: *mut GpioPulse) -> i32;
    fn wave_create(pi: i32) -> i32;
    fn wave_send_repeat(pi: i32, wave_id: u32) -> i32;
    fn wave_tx_stop(pi: i32) -> i32;
    fn wave_delete(pi: i32, wave_id: u32) -> i32;
}

#[cfg(feature = "gpio")]
#[repr(C)]
pub struct GpioPulse {
    pub gpio_on: u32,
    pub gpio_off: u32,
    pub us_delay: u32,
}

pub const PI_INPUT: u32 = 0;
pub const PI_OUTPUT: u32 = 1;
#[allow(dead_code)]
pub const PI_PUD_OFF: u32 = 0;
#[allow(dead_code)]
pub const PI_PUD_DOWN: u32 = 1;
pub const PI_PUD_UP: u32 = 2;

// ── BCM pins on a Pi 40-pin header ──────────────────────────────────────────

pub const ALL_BCM_PINS: &[u8] = &[
    2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,
    14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27,
];

pub struct PowerPin {
    pub phys: u8,
    pub label: &'static str,
}

pub static BOARD_POWER_PINS: &[PowerPin] = &[
    PowerPin { phys: 1, label: "3.3V" },
    PowerPin { phys: 2, label: "5V" },
    PowerPin { phys: 4, label: "5V" },
    PowerPin { phys: 6, label: "GND" },
    PowerPin { phys: 9, label: "GND" },
    PowerPin { phys: 14, label: "GND" },
    PowerPin { phys: 17, label: "3.3V" },
    PowerPin { phys: 20, label: "GND" },
    PowerPin { phys: 25, label: "GND" },
    PowerPin { phys: 27, label: "ID_SD" },
    PowerPin { phys: 28, label: "ID_SC" },
    PowerPin { phys: 30, label: "GND" },
    PowerPin { phys: 34, label: "GND" },
    PowerPin { phys: 39, label: "GND" },
];

// ── Wrappers (no-op when gpio feature disabled) ─────────────────────────────

pub fn use_pigpio() -> bool {
    cfg!(feature = "gpio")
}

pub fn pigpio_connect() -> i32 {
    #[cfg(feature = "gpio")]
    {
        unsafe { pigpio_start(std::ptr::null(), std::ptr::null()) }
    }
    #[cfg(not(feature = "gpio"))]
    { -1 }
}

#[allow(dead_code)]
pub fn pigpio_disconnect(pi: i32) {
    #[cfg(feature = "gpio")]
    {
        unsafe { pigpio_stop(pi); }
    }
    #[cfg(not(feature = "gpio"))]
    { let _ = pi; }
}

pub fn set_pin_mode(pi: i32, gpio_pin: u32, mode: u32) -> i32 {
    #[cfg(feature = "gpio")]
    { unsafe { set_mode(pi, gpio_pin, mode) } }
    #[cfg(not(feature = "gpio"))]
    { let _ = (pi, gpio_pin, mode); -1 }
}

pub fn read_pin(pi: i32, gpio_pin: u32) -> Option<bool> {
    #[cfg(feature = "gpio")]
    {
        if pi < 0 { return None; }
        let val = unsafe { gpio_read(pi, gpio_pin) };
        if val < 0 { None } else { Some(val == 1) }
    }
    #[cfg(not(feature = "gpio"))]
    { let _ = (pi, gpio_pin); None }
}

pub fn write_pin(pi: i32, gpio_pin: u32, level: u32) {
    #[cfg(feature = "gpio")]
    { unsafe { gpio_write(pi, gpio_pin, level); } }
    #[cfg(not(feature = "gpio"))]
    { let _ = (pi, gpio_pin, level); }
}

pub fn set_pud(pi: i32, gpio_pin: u32, pud: u32) {
    #[cfg(feature = "gpio")]
    { unsafe { set_pull_up_down(pi, gpio_pin, pud); } }
    #[cfg(not(feature = "gpio"))]
    { let _ = (pi, gpio_pin, pud); }
}

pub fn hw_pwm(pi: i32, gpio_pin: u32, freq: u32, duty: u32) -> i32 {
    #[cfg(feature = "gpio")]
    { unsafe { hardware_PWM(pi, gpio_pin, freq, duty) } }
    #[cfg(not(feature = "gpio"))]
    { let _ = (pi, gpio_pin, freq, duty); -1 }
}

#[cfg(feature = "gpio")]
pub fn wave_stop(pi: i32) {
    unsafe { wave_tx_stop(pi); }
}

#[cfg(feature = "gpio")]
pub fn wave_del(pi: i32, wid: u32) {
    unsafe { wave_delete(pi, wid); }
}

#[cfg(feature = "gpio")]
pub fn wave_clr(pi: i32) {
    unsafe { wave_clear(pi); }
}

#[cfg(feature = "gpio")]
pub fn wave_add(pi: i32, pulses: &mut [GpioPulse]) -> i32 {
    unsafe { wave_add_generic(pi, pulses.len() as u32, pulses.as_mut_ptr()) }
}

#[cfg(feature = "gpio")]
pub fn wave_new(pi: i32) -> i32 {
    unsafe { wave_create(pi) }
}

#[cfg(feature = "gpio")]
pub fn wave_repeat(pi: i32, wid: u32) -> i32 {
    unsafe { wave_send_repeat(pi, wid) }
}

// ── Initialisation ───────────────────────────────────────────────────────────

pub fn init() {
    if !use_pigpio() { return; }
    let pi = pigpio_connect();
    let mut st = state::STATE.lock().unwrap();
    if pi < 0 {
        st.gpio_available = false;
        st.gpio_error = Some("pigpiod not running or connection failed".into());
        return;
    }
    st.pi_handle = pi;
    st.gpio_available = true;

    // Set up input pins with pull-up for button reading
    let settings = st.settings.clone();
    for &bcm in ALL_BCM_PINS {
        if !is_managed_pin(&settings, bcm as i32) {
            set_pin_mode(pi, bcm as u32, PI_INPUT);
            set_pud(pi, bcm as u32, PI_PUD_UP);
        }
    }
}

#[allow(dead_code)]
pub fn deinit() {
    let st = state::STATE.lock().unwrap();
    if use_pigpio() && st.pi_handle >= 0 {
        pigpio_disconnect(st.pi_handle);
    }
}

fn is_managed_pin(s: &state::Settings, bcm: i32) -> bool {
    if s.speaker_pin == bcm { return true; }
    if let Some(sp2) = s.speaker_pin2 { if sp2 == bcm { return true; } }
    if let Some(gp) = s.ground_pin { if gp == bcm { return true; } }
    for &gp in &s.grounded_pins { if gp == bcm { return true; } }
    if s.pin_mode == "dual" {
        if s.dot_pin == bcm || s.dash_pin == bcm { return true; }
    } else {
        if s.data_pin == bcm { return true; }
    }
    false
}

// ── Setup helpers ────────────────────────────────────────────────────────────

pub fn setup_output_pin(pi: i32, pin: i32) {
    if !use_pigpio() || pi < 0 { return; }
    set_pin_mode(pi, pin as u32, PI_OUTPUT);
    write_pin(pi, pin as u32, 0);
}

pub fn setup_input_pin(pi: i32, pin: i32) {
    if !use_pigpio() || pi < 0 { return; }
    set_pin_mode(pi, pin as u32, PI_INPUT);
    set_pud(pi, pin as u32, PI_PUD_UP);
}

// ── Pin state JSON ───────────────────────────────────────────────────────────

pub fn pin_states_json() -> String {
    let st = state::STATE.lock().unwrap();
    let s = &st.settings;
    let pi = st.pi_handle;
    let pm = &s.pin_mode;
    let mut pieces: Vec<String> = Vec::new();

    for &bcm in ALL_BCM_PINS {
        let bcm_i32 = bcm as i32;
        let entry = if bcm_i32 == s.speaker_pin {
            format!("\"{}\":{{\"active\":null,\"role\":\"sp_led_pos\"}}", bcm)
        } else if s.speaker_pin2 == Some(bcm_i32) {
            format!("\"{}\":{{\"active\":null,\"role\":\"sp_led_neg\"}}", bcm)
        } else if s.ground_pin == Some(bcm_i32) || s.grounded_pins.contains(&bcm_i32) {
            format!("\"{}\":{{\"active\":null,\"role\":\"ground\"}}", bcm)
        } else if pm == "dual" && bcm_i32 == s.dot_pin {
            let active = read_pin(pi, bcm as u32);
            format!("\"{}\":{{\"active\":{},\"role\":\"dot\"}}", bcm, opt_bool_json(active))
        } else if pm == "dual" && bcm_i32 == s.dash_pin {
            let active = read_pin(pi, bcm as u32);
            format!("\"{}\":{{\"active\":{},\"role\":\"dash\"}}", bcm, opt_bool_json(active))
        } else if pm != "dual" && bcm_i32 == s.data_pin {
            let active = read_pin(pi, bcm as u32);
            format!("\"{}\":{{\"active\":{},\"role\":\"data\"}}", bcm, opt_bool_json(active))
        } else {
            let active = read_pin(pi, bcm as u32);
            format!("\"{}\":{{\"active\":{},\"role\":\"unused\"}}", bcm, opt_bool_json(active))
        };
        pieces.push(entry);
    }
    format!("{{{}}}", pieces.join(","))
}

fn opt_bool_json(v: Option<bool>) -> &'static str {
    match v {
        Some(true) => "true",
        Some(false) => "false",
        None => "null",
    }
}

pub fn power_pins_json() -> String {
    let entries: Vec<String> = BOARD_POWER_PINS.iter().map(|pp| {
        format!("\"{}\":\"{}\"", pp.phys, pp.label)
    }).collect();
    format!("{{{}}}", entries.join(","))
}

// ── Background poll thread ───────────────────────────────────────────────────

pub fn start_poll_thread() {
    if !use_pigpio() { return; }
    thread::spawn(|| {
        loop {
            {
                let mut st = state::STATE.lock().unwrap();
                let pi = st.pi_handle;
                if pi >= 0 {
                    let s = st.settings.clone();
                    if s.pin_mode == "dual" {
                        if let Some(v) = read_pin(pi, s.dot_pin as u32) {
                            st.pin_states[s.dot_pin as usize] = Some(v);
                        }
                        if let Some(v) = read_pin(pi, s.dash_pin as u32) {
                            st.pin_states[s.dash_pin as usize] = Some(v);
                        }
                    } else {
                        if let Some(v) = read_pin(pi, s.data_pin as u32) {
                            st.pin_states[s.data_pin as usize] = Some(v);
                        }
                    }
                }
            }
            thread::sleep(Duration::from_millis(50));
        }
    });
}
