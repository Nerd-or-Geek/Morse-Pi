// ============================================================================
//  Morse-Pi — Shared state, settings, statistics.
//
//  Central state module. Uses Arc<Mutex<...>> for thread-safe mutable state.
// ============================================================================
use serde::{Deserialize, Serialize};
use std::fs;
use std::sync::Mutex;

// ════════════════════════════════════════════════════════════════════════════
//  SETTINGS
// ════════════════════════════════════════════════════════════════════════════

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Settings {
    #[serde(default = "default_speaker_pin")]
    pub speaker_pin: i32,
    #[serde(default)]
    pub speaker_pin2: Option<i32>,
    #[serde(default = "default_speaker_gnd_mode")]
    pub speaker_gnd_mode: String,
    #[serde(default = "default_output_type")]
    pub output_type: String,
    #[serde(default = "default_pin_mode")]
    pub pin_mode: String,
    #[serde(default = "default_data_pin")]
    pub data_pin: i32,
    #[serde(default = "default_dot_pin")]
    pub dot_pin: i32,
    #[serde(default = "default_dash_pin")]
    pub dash_pin: i32,
    #[serde(default)]
    pub ground_pin: Option<i32>,
    #[serde(default)]
    pub grounded_pins: Vec<i32>,
    #[serde(default)]
    pub use_external_switch: bool,
    #[serde(default = "default_dot_freq")]
    pub dot_freq: i32,
    #[serde(default = "default_dash_freq")]
    pub dash_freq: i32,
    #[serde(default = "default_volume")]
    pub volume: f64,
    #[serde(default = "default_wpm_target")]
    pub wpm_target: i32,
    #[serde(default = "default_farnsworth_wpm")]
    pub farnsworth_wpm: i32,
    #[serde(default = "default_theme")]
    pub theme: String,
    #[serde(default = "default_difficulty")]
    pub difficulty: String,
    #[serde(default = "default_quiz_categories")]
    pub quiz_categories: Vec<String>,
    #[serde(default = "default_practice_chars")]
    pub practice_chars: String,
    #[serde(default, skip_serializing)]
    pub farnsworth_enabled: bool,
    #[serde(default = "default_farnsworth_mult", skip_serializing)]
    pub farnsworth_letter_mult: f64,
    #[serde(default = "default_farnsworth_mult", skip_serializing)]
    pub farnsworth_word_mult: f64,
    #[serde(default = "default_device_name")]
    pub device_name: String,
    #[serde(default)]
    pub kb_enabled: bool,
    #[serde(default = "default_kb_mode")]
    pub kb_mode: String,
    #[serde(default = "default_kb_dot_key")]
    pub kb_dot_key: String,
    #[serde(default = "default_kb_dash_key")]
    pub kb_dash_key: String,
}

fn default_speaker_pin() -> i32 { 18 }
fn default_speaker_gnd_mode() -> String { "3v3".into() }
fn default_output_type() -> String { "speaker".into() }
fn default_pin_mode() -> String { "single".into() }
fn default_data_pin() -> i32 { 17 }
fn default_dot_pin() -> i32 { 22 }
fn default_dash_pin() -> i32 { 27 }
fn default_dot_freq() -> i32 { 700 }
fn default_dash_freq() -> i32 { 500 }
fn default_volume() -> f64 { 0.75 }
fn default_wpm_target() -> i32 { 20 }
fn default_farnsworth_wpm() -> i32 { 20 }
fn default_theme() -> String { "dark".into() }
fn default_difficulty() -> String { "easy".into() }
fn default_quiz_categories() -> Vec<String> { vec!["words".into()] }
fn default_practice_chars() -> String { "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".into() }
fn default_farnsworth_mult() -> f64 { 2.0 }
fn default_device_name() -> String { "Morse Pi".into() }
fn default_kb_mode() -> String { "letters".into() }
fn default_kb_dot_key() -> String { "z".into() }
fn default_kb_dash_key() -> String { "x".into() }

impl Default for Settings {
    fn default() -> Self {
        Self {
            speaker_pin: 18,
            speaker_pin2: None,
            speaker_gnd_mode: "3v3".into(),
            output_type: "speaker".into(),
            pin_mode: "single".into(),
            data_pin: 17,
            dot_pin: 22,
            dash_pin: 27,
            ground_pin: None,
            grounded_pins: vec![],
            use_external_switch: false,
            dot_freq: 700,
            dash_freq: 500,
            volume: 0.75,
            wpm_target: 20,
            farnsworth_wpm: 20,
            theme: "dark".into(),
            difficulty: "easy".into(),
            quiz_categories: vec!["words".into()],
            practice_chars: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".into(),
            farnsworth_enabled: false,
            farnsworth_letter_mult: 2.0,
            farnsworth_word_mult: 2.0,
            device_name: "Morse Pi".into(),
            kb_enabled: false,
            kb_mode: "letters".into(),
            kb_dot_key: "z".into(),
            kb_dash_key: "x".into(),
        }
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  STATISTICS
// ════════════════════════════════════════════════════════════════════════════

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Stats {
    #[serde(default)]
    pub total_attempts: i64,
    #[serde(default)]
    pub correct: i64,
    #[serde(default)]
    pub streak: i64,
    #[serde(default)]
    pub best_streak: i64,
    #[serde(default)]
    pub total_chars: i64,
}

// ════════════════════════════════════════════════════════════════════════════
//  NETWORK MESSAGE
// ════════════════════════════════════════════════════════════════════════════

#[derive(Debug, Clone, Serialize)]
pub struct NetMessage {
    pub sender: String,
    pub text: String,
    pub morse: String,
    pub ts: f64,
}

// ════════════════════════════════════════════════════════════════════════════
//  RUNTIME STATE
// ════════════════════════════════════════════════════════════════════════════

pub struct AppState {
    pub settings: Settings,
    pub stats: Stats,
    pub mode: String,
    pub cheat_sheet: bool,
    pub current_phrase: String,
    pub decode_result: String,
    pub decode_correct_answer: String,
    pub speed_phrase: String,
    pub speed_result: String,
    pub speed_morse_buffer: String,
    pub speed_morse_output: String,
    pub send_output: String,
    pub encode_output: String,
    pub encode_input: String,
    pub button_active: bool,
    pub current_morse_buffer: String,
    pub net_key_mode_enabled: bool,
    pub net_morse_buffer_str: String,
    pub net_morse_output_str: String,
    pub net_live_transmit_enabled: bool,
    pub net_live_transmit_target_ip: String,
    pub net_live_transmit_target_port: u16,
    pub kb_output: String,
    pub net_inbox: Vec<NetMessage>,
    // GPIO state
    pub gpio_available: bool,
    pub gpio_error: Option<String>,
    pub gpio_error_log: Vec<String>,
    pub pin_states: [Option<bool>; 28],
    // pigpio handle
    pub pi_handle: i32,
    pub wave_id: i32,
    pub spk_pin1: Option<i32>,
    pub spk_pin2: Option<i32>,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            settings: Settings::default(),
            stats: Stats::default(),
            mode: "send".into(),
            cheat_sheet: false,
            current_phrase: String::new(),
            decode_result: String::new(),
            decode_correct_answer: String::new(),
            speed_phrase: String::new(),
            speed_result: String::new(),
            speed_morse_buffer: String::new(),
            speed_morse_output: String::new(),
            send_output: String::new(),
            encode_output: String::new(),
            encode_input: String::new(),
            button_active: false,
            current_morse_buffer: String::new(),
            net_key_mode_enabled: false,
            net_morse_buffer_str: String::new(),
            net_morse_output_str: String::new(),
            net_live_transmit_enabled: false,
            net_live_transmit_target_ip: String::new(),
            net_live_transmit_target_port: 5000,
            kb_output: String::new(),
            net_inbox: Vec::new(),
            gpio_available: false,
            gpio_error: None,
            gpio_error_log: Vec::new(),
            pin_states: [None; 28],
            pi_handle: -1,
            wave_id: -1,
            spk_pin1: None,
            spk_pin2: None,
        }
    }
}

impl AppState {
    pub fn load_settings(&mut self) {
        match fs::read_to_string("settings.json") {
            Ok(data) => match serde_json::from_str::<Settings>(&data) {
                Ok(mut s) => {
                    s.wpm_target = s.wpm_target.max(5);

                    if !data.contains("\"farnsworth_wpm\"") {
                        if s.farnsworth_enabled {
                            let legacy_mult = s
                                .farnsworth_letter_mult
                                .max(s.farnsworth_word_mult)
                                .max(1.0);
                            s.farnsworth_wpm = ((s.wpm_target as f64) / legacy_mult).round() as i32;
                        } else {
                            s.farnsworth_wpm = s.wpm_target;
                        }
                    }

                    s.farnsworth_wpm = s.farnsworth_wpm.max(5).min(s.wpm_target);
                    self.settings = s;
                }
                Err(_) => {}
            },
            Err(_) => {}
        }
    }

    pub fn save_settings(&self) {
        if let Ok(data) = serde_json::to_string_pretty(&self.settings) {
            let _ = fs::write("settings.json", data);
        }
    }

    pub fn settings_json(&self) -> String {
        serde_json::to_string(&self.settings).unwrap_or_else(|_| "{}".into())
    }

    pub fn load_stats(&mut self) {
        match fs::read_to_string("stats.json") {
            Ok(data) => match serde_json::from_str::<Stats>(&data) {
                Ok(s) => self.stats = s,
                Err(_) => {}
            },
            Err(_) => {}
        }
    }

    pub fn save_stats(&self) {
        if let Ok(data) = serde_json::to_string(&self.stats) {
            let _ = fs::write("stats.json", data);
        }
    }

    pub fn add_inbox_message(&mut self, sender: &str, text: &str, morse_str: &str) {
        let msg = NetMessage {
            sender: sender.to_string(),
            text: text.to_string(),
            morse: morse_str.to_string(),
            ts: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0),
        };
        if self.net_inbox.len() >= 32 {
            self.net_inbox.remove(0);
        }
        self.net_inbox.push(msg);
    }

    pub fn clear_inbox(&mut self) {
        self.net_inbox.clear();
    }

    /// Write full runtime state as JSON.
    pub fn state_json(&self) -> String {
        let stats_json = format!(
            r#"{{"total_attempts":{},"correct":{},"streak":{},"best_streak":{},"total_chars":{},"sessions":[]}}"#,
            self.stats.total_attempts, self.stats.correct, self.stats.streak,
            self.stats.best_streak, self.stats.total_chars,
        );
        let inbox_json = self.inbox_json();
        format!(
            r#"{{"mode":"{}","cheat_sheet":{},"current_phrase":"{}","decode_result":"{}","decode_correct_answer":"{}","speed_phrase":"{}","speed_result":"{}","speed_morse_buffer":"{}","speed_morse_output":"{}","send_output":"{}","encode_output":"{}","encode_input":"{}","button_active":{},"current_morse_buffer":"{}","net_key_mode":{},"net_morse_buffer":"{}","net_morse_output":"{}","net_live_transmit_enabled":{},"kb_output":"{}","stats":{},"net_inbox":{}}}"#,
            escape_json(&self.mode),
            self.cheat_sheet,
            escape_json(&self.current_phrase),
            escape_json(&self.decode_result),
            escape_json(&self.decode_correct_answer),
            escape_json(&self.speed_phrase),
            escape_json(&self.speed_result),
            escape_json(&self.speed_morse_buffer),
            escape_json(&self.speed_morse_output),
            escape_json(&self.send_output),
            escape_json(&self.encode_output),
            escape_json(&self.encode_input),
            self.button_active,
            escape_json(&self.current_morse_buffer),
            self.net_key_mode_enabled,
            escape_json(&self.net_morse_buffer_str),
            escape_json(&self.net_morse_output_str),
            self.net_live_transmit_enabled,
            escape_json(&self.kb_output),
            stats_json,
            inbox_json,
        )
    }

    pub fn stats_json(&self) -> String {
        format!(
            r#"{{"total_attempts":{},"correct":{},"streak":{},"best_streak":{},"total_chars":{},"sessions":[]}}"#,
            self.stats.total_attempts, self.stats.correct, self.stats.streak,
            self.stats.best_streak, self.stats.total_chars,
        )
    }

    fn inbox_json(&self) -> String {
        let entries: Vec<String> = self.net_inbox.iter().map(|msg| {
            format!(
                r#"{{"sender":"{}","text":"{}","morse":"{}","ts":{}}}"#,
                escape_json(&msg.sender),
                escape_json(&msg.text),
                escape_json(&msg.morse),
                msg.ts,
            )
        }).collect();
        format!("[{}]", entries.join(","))
    }

    pub fn init(&mut self) {
        self.load_settings();
        self.load_stats();
        self.mode = "send".into();
    }
}

/// Escape a string for JSON embedding (handle backslash, quotes, newlines).
pub fn escape_json(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            _ => out.push(c),
        }
    }
    out
}

/// Global shared state.
pub static STATE: once_cell::sync::Lazy<Mutex<AppState>> =
    once_cell::sync::Lazy::new(|| Mutex::new(AppState::default()));
