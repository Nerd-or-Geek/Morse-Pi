// ============================================================================
//  Morse-Pi — Rust backend.  HTTP server, route dispatch, all handlers.
//
//  Entry-point: `main()` at the bottom.
//  Uses a simple TCP-based HTTP/1.1 server with one thread per connection.
// ============================================================================
mod gpio;
mod keyboard;
mod morse;
mod network;
mod sound;
mod state;

use state::escape_json;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::Command;
use std::thread;
use std::time::Duration;

// ════════════════════════════════════════════════════════════════════════════
//  HTTP HELPERS
// ════════════════════════════════════════════════════════════════════════════

#[derive(Debug)]
enum Method { GET, POST, OPTIONS, OTHER }

struct Request {
    method: Method,
    path: String,
    body: String,
}

/// Parse an HTTP request from the stream.
fn parse_request(stream: &mut TcpStream) -> Option<Request> {
    let mut reader = BufReader::new(stream.try_clone().ok()?);
    let mut headers = String::new();

    // Read headers
    loop {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => return None,
            Ok(_) => {
                headers.push_str(&line);
                if line == "\r\n" || line == "\n" { break; }
            }
            Err(_) => return None,
        }
    }

    let first_line = headers.lines().next()?;
    let mut parts = first_line.split_whitespace();
    let method_str = parts.next()?;
    let path = parts.next()?.to_string();

    let method = match method_str {
        "GET" => Method::GET,
        "POST" => Method::POST,
        "OPTIONS" => Method::OPTIONS,
        _ => Method::OTHER,
    };

    // Find Content-Length
    let mut content_length: usize = 0;
    for line in headers.lines() {
        let lower = line.to_lowercase();
        if lower.starts_with("content-length:") {
            let val = line["content-length:".len()..].trim();
            content_length = val.parse().unwrap_or(0);
        }
    }

    // Read body
    let mut body = String::new();
    if content_length > 0 {
        let mut buf = vec![0u8; content_length];
        let _ = reader.read_exact(&mut buf);
        body = String::from_utf8_lossy(&buf).to_string();
    }

    Some(Request { method, path, body })
}

fn send_response(stream: &mut TcpStream, status: u16, content_type: &str, body: &str) {
    let status_text = match status {
        200 => "OK",
        204 => "No Content",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        _ => "OK",
    };
    let header = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n",
        status, status_text, content_type, body.len(),
    );
    let _ = stream.write_all(header.as_bytes());
    let _ = stream.write_all(body.as_bytes());
}

fn send_no_content(stream: &mut TcpStream) {
    let header = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    let _ = stream.write_all(header.as_bytes());
}

fn send_json(stream: &mut TcpStream, body: &str) {
    send_response(stream, 200, "application/json", body);
}

fn send_404(stream: &mut TcpStream) {
    send_response(stream, 404, "text/plain", "Not Found");
}

fn send_405(stream: &mut TcpStream) {
    send_response(stream, 405, "text/plain", "Method Not Allowed");
}

// ── JSON extraction from request body ────────────────────────────────────────

fn json_str<'a>(body: &'a str, key: &str) -> Option<&'a str> {
    let needle = format!("\"{}\":", key);
    let idx = body.find(&needle)?;
    let after = &body[idx + needle.len()..];
    let trimmed = after.trim_start();
    if trimmed.starts_with('"') {
        let rest = &trimmed[1..];
        // Walk through chars to find unescaped closing quote
        let mut i = 0;
        let bytes = rest.as_bytes();
        while i < bytes.len() {
            if bytes[i] == b'\\' {
                i += 2; // skip escaped char
                continue;
            }
            if bytes[i] == b'"' {
                return Some(&rest[..i]);
            }
            i += 1;
        }
        None
    } else {
        // Non-string value
        let end = trimmed.find(|c: char| c == ',' || c == '}' || c == ' ' || c == '\r' || c == '\n').unwrap_or(trimmed.len());
        Some(&trimmed[..end])
    }
}

fn json_bool(body: &str, key: &str) -> Option<bool> {
    let val = json_str(body, key)?;
    match val {
        "true" => Some(true),
        "false" => Some(false),
        _ => None,
    }
}

fn json_int(body: &str, key: &str) -> Option<i64> {
    json_str(body, key)?.parse().ok()
}

fn json_float(body: &str, key: &str) -> Option<f64> {
    json_str(body, key)?.parse().ok()
}

// ════════════════════════════════════════════════════════════════════════════
//  TEMPLATE SERVING
// ════════════════════════════════════════════════════════════════════════════

fn serve_template(stream: &mut TcpStream, filename: &str) {
    let content = match std::fs::read_to_string(filename) {
        Ok(c) => c,
        Err(_) => { send_404(stream); return; }
    };

    let mut result = String::with_capacity(content.len());
    let bytes = content.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if i + 2 < bytes.len() && bytes[i] == b'{' && bytes[i + 1] == b'{' {
            if let Some(close_idx) = content[i + 2..].find("}}") {
                let expr = content[i + 2..i + 2 + close_idx].trim();
                substitute_expr(&mut result, expr);
                i = i + 2 + close_idx + 2;
                continue;
            }
        }
        result.push(bytes[i] as char);
        i += 1;
    }
    send_response(stream, 200, "text/html; charset=utf-8", &result);
}

fn substitute_expr(result: &mut String, expr: &str) {
    let trimmed = expr.trim();
    if trimmed.contains("state") && trimmed.contains("tojson") {
        let st = state::STATE.lock().unwrap();
        result.push_str(&st.state_json());
    } else if trimmed.contains("settings") && trimmed.contains("tojson") {
        let st = state::STATE.lock().unwrap();
        result.push_str(&st.settings_json());
    } else if trimmed.contains("gpio_available") {
        let st = state::STATE.lock().unwrap();
        result.push_str(if st.gpio_available { "true" } else { "false" });
    } else if trimmed.contains("morse_code") && trimmed.contains("tojson") {
        result.push_str(&morse::morse_table_json());
    } else {
        result.push_str("{{");
        result.push_str(expr);
        result.push_str("}}");
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  ROUTE DISPATCH
// ════════════════════════════════════════════════════════════════════════════

fn handle_connection(mut stream: TcpStream) {
    // Set read/write timeout so stalled connections don't hang threads forever
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));

    let req = match parse_request(&mut stream) {
        Some(r) => r,
        None => return,
    };

    match req.method {
        Method::GET => route_get(&mut stream, &req.path),
        Method::POST => route_post(&mut stream, &req.path, &req.body),
        Method::OPTIONS => send_no_content(&mut stream),
        Method::OTHER => send_405(&mut stream),
    }
}

fn route_get(stream: &mut TcpStream, path: &str) {
    match path {
        "/" => serve_template(stream, "templates/index.html"),
        "/diag" => serve_template(stream, "templates/diag.html"),
        "/status" => handle_status(stream),
        "/gpio_poll" => handle_gpio_poll(stream),
        "/get_settings" => {
            let json = state::STATE.lock().unwrap().settings_json();
            send_json(stream, &json);
        }
        "/peers" => {
            let json = network::peers_json();
            send_json(stream, &json);
        }
        "/net_status" => handle_net_status(stream),
        "/kb_status" => handle_kb_status(stream),
        "/favicon.ico" => send_response(stream, 204, "image/x-icon", ""),
        _ => send_404(stream),
    }
}

fn route_post(stream: &mut TcpStream, path: &str, body: &str) {
    match path {
        "/set_mode" => handle_set_mode(stream, body),
        "/encode" => handle_encode(stream, body),
        "/play" => handle_play(stream),
        "/play_phrase" => handle_play_phrase(stream),
        "/wpm_test" => handle_wpm_test(stream),
        "/save_settings" => handle_save_settings(stream, body),
        "/preview_tone" => handle_preview_tone(stream, body),
        "/decode_submit" => handle_decode_submit(stream, body),
        "/submit_test" => handle_submit_test(stream, body),
        "/clear" => handle_clear(stream),
        "/toggle_cheat_sheet" => handle_toggle_cheat_sheet(stream),
        "/receive_morse" => handle_receive_morse(stream, body),
        "/send_to_peer" => handle_send_to_peer(stream, body),
        "/clear_inbox" => handle_clear_inbox(stream),
        "/assign_gpio" => handle_assign_gpio(stream, body),
        "/net_key_mode" => handle_net_key_mode(stream, body),
        "/net_key_press" => handle_net_key_press(stream, body),
        "/net_clear_morse" => handle_net_clear_morse(stream),
        "/net_send_morse" => handle_net_send_morse(stream, body),
        "/net_live_transmit_set" => handle_net_live_transmit_set(stream, body),
        "/net_live_transmit_symbol" => handle_net_live_transmit_symbol(stream, body),
        "/net_receive_live_symbol" => handle_net_receive_live_symbol(stream, body),
        "/net_live_key" => handle_net_live_key(stream, body),
        "/net_receive_live_key" => handle_net_receive_live_key(stream, body),
        "/kb_enable" => handle_kb_enable(stream, body),
        "/kb_hid_setup" => handle_kb_hid_setup(stream),
        "/kb_mode" => handle_kb_mode(stream, body),
        "/kb_set_keys" => handle_kb_set_keys(stream, body),
        "/kb_clear" => handle_kb_clear(stream),
        "/kb_send_custom" => handle_kb_send_custom(stream, body),
        "/key_press" => handle_key_press(stream, body),
        "/key_press_dual" => handle_key_press_dual(stream, body),
        "/reset_stats" => handle_reset_stats(stream),
        "/clear_speed" => handle_clear_speed(stream),
        "/gpio_reinit" => handle_gpio_reinit(stream),
        _ => send_404(stream),
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  GET HANDLERS
// ════════════════════════════════════════════════════════════════════════════

fn handle_status(stream: &mut TcpStream) {
    let (mut json, gpio_avail, kb_enabled, kb_mode, kb_dot, kb_dash) = {
        let st = state::STATE.lock().unwrap();
        let j = st.state_json();
        (
            j,
            st.gpio_available,
            st.settings.kb_enabled,
            st.settings.kb_mode.clone(),
            st.settings.kb_dot_key.clone(),
            st.settings.kb_dash_key.clone(),
        )
    };
    // Lock is released — safe to call pin_states_json (which also locks STATE)
    let keyer_label = sound::KEYER_STATE_LABEL.lock().unwrap().clone();
    let pin_states = gpio::pin_states_json();
    let hid_avail = keyboard::USB_HID_AVAILABLE.load(std::sync::atomic::Ordering::Relaxed);

    if json.ends_with('}') {
        json.pop();
    }
    let extra = format!(
        r#","gpio_available":{},"pin_states":{},"keyer_state":"{}","kb_enabled":{},"kb_mode":"{}","kb_dot_key":"{}","kb_dash_key":"{}","usb_hid_available":{}}}"#,
        gpio_avail,
        pin_states,
        escape_json(&keyer_label),
        kb_enabled,
        escape_json(&kb_mode),
        escape_json(&kb_dot),
        escape_json(&kb_dash),
        hid_avail,
    );
    json.push_str(&extra);
    send_json(stream, &json);
}

fn handle_gpio_poll(stream: &mut TcpStream) {
    let st = state::STATE.lock().unwrap();
    let s = &st.settings;
    let gpio_avail = st.gpio_available;
    let gpio_err = st.gpio_error.clone();

    let sp2_json = match s.speaker_pin2 {
        Some(v) => v.to_string(),
        None => "null".into(),
    };
    let gp_json = match s.ground_pin {
        Some(v) => v.to_string(),
        None => "null".into(),
    };
    let grounded_json: Vec<String> = s.grounded_pins.iter().map(|g| g.to_string()).collect();
    let gpio_err_json = match &gpio_err {
        Some(e) => format!("\"{}\"", escape_json(e)),
        None => "null".into(),
    };

    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);

    let header = format!(
        r#"{{"gpio_available":{},"gpio_error":{},"pin_mode":"{}","output_type":"{}","data_pin":{},"dot_pin":{},"dash_pin":{},"speaker_pin":{},"speaker_pin2":{},"speaker_gnd_mode":"{}","ground_pin":{},"grounded_pins":[{}],"#,
        gpio_avail,
        gpio_err_json,
        escape_json(&s.pin_mode),
        escape_json(&s.output_type),
        s.data_pin,
        s.dot_pin,
        s.dash_pin,
        s.speaker_pin,
        sp2_json,
        escape_json(&s.speaker_gnd_mode),
        gp_json,
        grounded_json.join(","),
    );
    drop(st);

    let states_json = gpio::pin_states_json();
    let power_json = gpio::power_pins_json();

    let json = format!(
        r#"{}"states":{},"power_pins":{},"errors":[],"timestamp":{:.3}}}"#,
        header, states_json, power_json, ts,
    );
    send_json(stream, &json);
}

fn handle_net_status(stream: &mut TcpStream) {
    // Build response from peers_json() (contains self + peers), then append inbox
    let mut base = network::peers_json();

    let st = state::STATE.lock().unwrap();
    let inbox: Vec<String> = st.net_inbox.iter().rev().map(|msg| {
        format!(
            r#"{{"sender":"{}","text":"{}","morse":"{}","ts":{}}}"#,
            escape_json(&msg.sender),
            escape_json(&msg.text),
            escape_json(&msg.morse),
            msg.ts,
        )
    }).collect();
    drop(st);

    // peers_json() ends with "}" — strip it and append inbox
    if base.ends_with('}') {
        base.pop();
    }
    base.push_str(&format!(r#","inbox":[{}]}}"#, inbox.join(",")));
    send_json(stream, &base);
}

fn handle_kb_status(stream: &mut TcpStream) {
    keyboard::check_usb_hid();
    let st = state::STATE.lock().unwrap();
    let json = format!(
        r#"{{"kb_enabled":{},"kb_mode":"{}","kb_dot_key":"{}","kb_dash_key":"{}","kb_output":"{}","usb_hid_available":{}}}"#,
        st.settings.kb_enabled,
        escape_json(&st.settings.kb_mode),
        escape_json(&st.settings.kb_dot_key),
        escape_json(&st.settings.kb_dash_key),
        escape_json(&st.kb_output),
        keyboard::USB_HID_AVAILABLE.load(std::sync::atomic::Ordering::Relaxed),
    );
    send_json(stream, &json);
}

// ════════════════════════════════════════════════════════════════════════════
//  POST HANDLERS
// ════════════════════════════════════════════════════════════════════════════

fn handle_set_mode(stream: &mut TcpStream, body: &str) {
    let mode_str = match json_str(body, "mode") {
        Some(m) => m.to_string(),
        None => { send_state_json(stream); return; }
    };
    let valid_modes = ["send", "encode", "decode", "speed", "settings", "stats", "network"];
    if !valid_modes.contains(&mode_str.as_str()) {
        send_state_json(stream);
        return;
    }

    {
        let mut st = state::STATE.lock().unwrap();
        st.mode = mode_str.clone();
    }

    if mode_str == "decode" {
        let diff = state::STATE.lock().unwrap().settings.difficulty.clone();
        let phrase = morse::random_phrase(&diff);
        let mut st = state::STATE.lock().unwrap();
        st.current_phrase = phrase;
        st.decode_result.clear();
    } else if mode_str == "speed" {
        let diff = state::STATE.lock().unwrap().settings.difficulty.clone();
        let phrase = morse::random_phrase(&diff);
        {
            let mut st = state::STATE.lock().unwrap();
            st.speed_phrase = phrase;
            st.speed_result.clear();
            st.speed_morse_buffer.clear();
            st.speed_morse_output.clear();
        }
        sound::recreate_gpio();
    } else if mode_str == "send" {
        sound::recreate_gpio();
    }
    send_state_json(stream);
}

fn handle_encode(stream: &mut TcpStream, body: &str) {
    let text = json_str(body, "text").unwrap_or("");
    let encoded = morse::encode(text);
    {
        let mut st = state::STATE.lock().unwrap();
        st.encode_input = text.to_string();
        st.encode_output = encoded.clone();
    }
    let json = format!(r#"{{"morse":"{}"}}"#, escape_json(&encoded));
    send_json(stream, &json);
}

fn handle_play(stream: &mut TcpStream) {
    let text = state::STATE.lock().unwrap().encode_input.clone();
    thread::spawn(move || {
        sound::play_morse_string(&text);
    });
    send_json(stream, r#"{"status":"playing"}"#);
}

fn handle_play_phrase(stream: &mut TcpStream) {
    let text = state::STATE.lock().unwrap().current_phrase.clone();
    thread::spawn(move || {
        sound::play_morse_string(&text);
    });
    send_json(stream, r#"{"status":"playing"}"#);
}

fn handle_wpm_test(stream: &mut TcpStream) {
    thread::spawn(|| {
        sound::play_morse_string("PARIS");
    });
    let (character_wpm, farnsworth_wpm) = {
        let st = state::STATE.lock().unwrap();
        (st.settings.wpm_target, st.settings.farnsworth_wpm)
    };
    let json = format!(
        r#"{{"status":"playing","wpm":{},"character_wpm":{},"farnsworth_wpm":{}}}"#,
        character_wpm,
        character_wpm,
        farnsworth_wpm,
    );
    send_json(stream, &json);
}

fn handle_save_settings(stream: &mut TcpStream, body: &str) {
    let mut st = state::STATE.lock().unwrap();
    if let Some(v) = json_int(body, "speaker_pin") { st.settings.speaker_pin = v as i32; }
    if let Some(v) = json_str(body, "speaker_pin2") {
        if v == "null" {
            st.settings.speaker_pin2 = None;
        } else if let Ok(n) = v.parse::<i32>() {
            st.settings.speaker_pin2 = Some(n);
        }
    }
    for &(json_key, field) in &[
        ("speaker_gnd_mode", "speaker_gnd_mode"), ("output_type", "output_type"),
        ("pin_mode", "pin_mode"), ("theme", "theme"), ("difficulty", "difficulty"),
        ("device_name", "device_name"), ("kb_mode", "kb_mode"),
        ("kb_dot_key", "kb_dot_key"), ("kb_dash_key", "kb_dash_key"),
        ("practice_chars", "practice_chars"),
    ] {
        if let Some(v) = json_str(body, json_key) {
            match field {
                "speaker_gnd_mode" => st.settings.speaker_gnd_mode = v.into(),
                "output_type" => st.settings.output_type = v.into(),
                "pin_mode" => st.settings.pin_mode = v.into(),
                "theme" => st.settings.theme = v.into(),
                "difficulty" => st.settings.difficulty = v.into(),
                "device_name" => st.settings.device_name = v.into(),
                "kb_mode" => st.settings.kb_mode = v.into(),
                "kb_dot_key" => st.settings.kb_dot_key = v.into(),
                "kb_dash_key" => st.settings.kb_dash_key = v.into(),
                "practice_chars" => st.settings.practice_chars = v.into(),
                _ => {}
            }
        }
    }
    for &(json_key, field) in &[
        ("data_pin", "data_pin"), ("dot_pin", "dot_pin"), ("dash_pin", "dash_pin"),
        ("dot_freq", "dot_freq"), ("dash_freq", "dash_freq"), ("wpm_target", "wpm_target"),
        ("farnsworth_wpm", "farnsworth_wpm"),
    ] {
        if let Some(v) = json_int(body, json_key) {
            match field {
                "data_pin" => st.settings.data_pin = v as i32,
                "dot_pin" => st.settings.dot_pin = v as i32,
                "dash_pin" => st.settings.dash_pin = v as i32,
                "dot_freq" => st.settings.dot_freq = v as i32,
                "dash_freq" => st.settings.dash_freq = v as i32,
                "wpm_target" => st.settings.wpm_target = v as i32,
                "farnsworth_wpm" => st.settings.farnsworth_wpm = v as i32,
                _ => {}
            }
        }
    }
    if let Some(v) = json_str(body, "ground_pin") {
        if v == "null" {
            st.settings.ground_pin = None;
        } else if let Ok(n) = v.parse::<i32>() {
            st.settings.ground_pin = Some(n);
        }
    }
    if let Some(v) = json_float(body, "volume") { st.settings.volume = v; }
    if let Some(v) = json_bool(body, "use_external_switch") { st.settings.use_external_switch = v; }
    if let Some(v) = json_bool(body, "kb_enabled") { st.settings.kb_enabled = v; }

    // Legacy Farnsworth compatibility for older frontends that still post toggle/multiplier settings.
    let legacy_enabled = json_bool(body, "farnsworth_enabled");
    let legacy_letter_mult = json_float(body, "farnsworth_letter_mult");
    let legacy_word_mult = json_float(body, "farnsworth_word_mult");
    if legacy_enabled.is_some() || legacy_letter_mult.is_some() || legacy_word_mult.is_some() {
        st.settings.farnsworth_enabled = legacy_enabled.unwrap_or(st.settings.farnsworth_enabled);
        if let Some(v) = legacy_letter_mult { st.settings.farnsworth_letter_mult = v; }
        if let Some(v) = legacy_word_mult { st.settings.farnsworth_word_mult = v; }

        if json_int(body, "farnsworth_wpm").is_none() {
            if st.settings.farnsworth_enabled {
                let legacy_mult = st
                    .settings
                    .farnsworth_letter_mult
                    .max(st.settings.farnsworth_word_mult)
                    .max(1.0);
                st.settings.farnsworth_wpm = ((st.settings.wpm_target.max(5) as f64) / legacy_mult).round() as i32;
            } else {
                st.settings.farnsworth_wpm = st.settings.wpm_target;
            }
        }
    }

    st.settings.wpm_target = st.settings.wpm_target.max(5);
    st.settings.farnsworth_wpm = st.settings.farnsworth_wpm.max(5).min(st.settings.wpm_target);

    st.save_settings();
    let json = st.settings_json();
    drop(st);
    sound::recreate_gpio();
    send_json(stream, &json);
}

fn handle_preview_tone(stream: &mut TcpStream, body: &str) {
    let freq = json_int(body, "freq").unwrap_or_else(|| {
        state::STATE.lock().unwrap().settings.dot_freq as i64
    }) as u32;
    let dur_secs = json_float(body, "duration").unwrap_or_else(|| {
        sound::get_dot_unit_secs(state::STATE.lock().unwrap().settings.wpm_target)
    });
    let dur = Duration::from_secs_f64(dur_secs);
    thread::spawn(move || {
        sound::play_tone(freq, Some(dur));
        sound::stop_tone();
    });
    send_json(stream, r#"{"status":"previewed"}"#);
}

fn handle_decode_submit(stream: &mut TcpStream, body: &str) {
    let answer = json_str(body, "answer").unwrap_or("").to_string();
    let mut st = state::STATE.lock().unwrap();
    let correct_phrase = st.current_phrase.clone();

    let ans_upper = answer.trim().to_uppercase();
    let phrase_upper = correct_phrase.trim().to_uppercase();

    let correct = ans_upper == phrase_upper;
    st.stats.total_attempts += 1;
    if correct {
        st.stats.correct += 1;
        st.stats.streak += 1;
        if st.stats.streak > st.stats.best_streak {
            st.stats.best_streak = st.stats.streak;
        }
    } else {
        st.stats.streak = 0;
    }
    st.decode_result = if correct { "correct".into() } else { "wrong".into() };
    st.decode_correct_answer = phrase_upper.clone();
    st.save_stats();

    let stats_json = st.stats_json();
    drop(st);

    let json = format!(
        r#"{{"result":"{}","correct_answer":"{}","stats":{}}}"#,
        if correct { "correct" } else { "wrong" },
        escape_json(&phrase_upper),
        stats_json,
    );
    send_json(stream, &json);
}

fn handle_submit_test(stream: &mut TcpStream, body: &str) {
    let elapsed = json_float(body, "elapsed").unwrap_or(1.0);
    let mut st = state::STATE.lock().unwrap();
    let input_morse = st.speed_morse_output.trim().to_string();

    if input_morse.is_empty() {
        st.speed_result = "no_input".into();
        drop(st);
        send_json(stream, r#"{"result":"no_input"}"#);
        return;
    }

    let decoded = morse::decode(&input_morse);
    let decoded_upper = decoded.to_uppercase();
    let expected = st.speed_phrase.clone();
    let expected_upper = expected.to_uppercase();

    let max_len = expected_upper.len().max(decoded_upper.len());
    let expected_chars: Vec<char> = expected_upper.chars().collect();
    let decoded_chars: Vec<char> = decoded_upper.chars().collect();
    let mut correct_count: usize = 0;
    for i in 0..max_len {
        let exp_c = expected_chars.get(i).copied().unwrap_or('\0');
        let got_c = decoded_chars.get(i).copied().unwrap_or('\0');
        if exp_c == got_c && exp_c != '\0' {
            correct_count += 1;
        }
    }
    let accuracy = if !expected_upper.is_empty() {
        (correct_count * 100) / expected_upper.len()
    } else {
        0
    };
    let perfect = decoded_upper == expected_upper;

    let chars_typed: usize = input_morse.chars().filter(|&c| c != ' ' && c != '/').count();
    let wpm = if elapsed > 0.0 {
        (chars_typed as f64) / 5.0 / (elapsed / 60.0)
    } else {
        0.0
    };

    st.stats.total_attempts += 1;
    if perfect {
        st.stats.correct += 1;
        st.stats.streak += 1;
        if st.stats.streak > st.stats.best_streak {
            st.stats.best_streak = st.stats.streak;
        }
    } else {
        st.stats.streak = 0;
    }
    st.save_stats();

    // char_results
    let mut char_results = String::from("[");
    for i in 0..max_len {
        if i > 0 { char_results.push(','); }
        let exp_c = expected_chars.get(i).copied().unwrap_or(' ');
        let got_c = decoded_chars.get(i).copied().unwrap_or(' ');
        let is_match = exp_c == got_c && exp_c != '\0';
        char_results.push_str(&format!(
            r#"{{"expected":"{}","got":"{}","correct":{}}}"#,
            if exp_c != '\0' { exp_c } else { ' ' },
            if got_c != '\0' { got_c } else { ' ' },
            is_match,
        ));
    }
    char_results.push(']');

    let stats_json = st.stats_json();
    st.speed_morse_output.clear();
    st.speed_morse_buffer.clear();
    drop(st);

    let json = format!(
        r#"{{"result":"{}","decoded":"{}","expected":"{}","accuracy":{},"wpm":{:.1},"char_results":{},"stats":{}}}"#,
        if perfect { "correct" } else { "wrong" },
        escape_json(&decoded_upper),
        escape_json(&expected_upper),
        accuracy,
        wpm,
        char_results,
        stats_json,
    );
    send_json(stream, &json);
}

fn handle_clear(stream: &mut TcpStream) {
    {
        let mut st = state::STATE.lock().unwrap();
        st.send_output.clear();
        st.encode_output.clear();
        st.encode_input.clear();
        st.current_morse_buffer.clear();
        st.speed_morse_buffer.clear();
        st.speed_morse_output.clear();
    }
    sound::clear_send_buffers();
    send_state_json(stream);
}

fn handle_toggle_cheat_sheet(stream: &mut TcpStream) {
    let mut st = state::STATE.lock().unwrap();
    st.cheat_sheet = !st.cheat_sheet;
    let json = format!(r#"{{"cheat_sheet":{}}}"#, st.cheat_sheet);
    send_json(stream, &json);
}

fn handle_receive_morse(stream: &mut TcpStream, body: &str) {
    let sender_name = json_str(body, "sender_name").unwrap_or("Unknown").to_string();
    let text = json_str(body, "text").unwrap_or("").to_string();
    let morse_str_raw = json_str(body, "morse").unwrap_or("").to_string();

    let text_upper = text.to_uppercase();
    let m = if text_upper.is_empty() || !morse_str_raw.is_empty() {
        morse_str_raw.clone()
    } else {
        morse::encode(&text_upper)
    };

    if text_upper.is_empty() && m.is_empty() {
        send_json(stream, r#"{"ok":false,"error":"no content"}"#);
        return;
    }

    state::STATE.lock().unwrap().add_inbox_message(&sender_name, &text_upper, &m);

    if !text_upper.is_empty() {
        let text_copy = text_upper.clone();
        thread::spawn(move || {
            sound::play_morse_string(&text_copy);
        });
    }

    let json = format!(r#"{{"ok":true,"received":"{}"}}"#, escape_json(&text_upper));
    send_json(stream, &json);
}

fn handle_send_to_peer(stream: &mut TcpStream, body: &str) {
    let ip = json_str(body, "ip").unwrap_or("").to_string();
    let port_val = json_int(body, "port").unwrap_or(5000) as u16;
    let text = json_str(body, "text").unwrap_or("").to_string();

    if ip.is_empty() || text.is_empty() {
        send_json(stream, r#"{"ok":false,"error":"missing ip or text"}"#);
        return;
    }

    let text_upper = text.to_uppercase();
    let encoded = morse::encode(&text_upper);
    let device_name = state::STATE.lock().unwrap().settings.device_name.clone();

    let payload = format!(
        r#"{{"sender_name":"{}","text":"{}","morse":"{}"}}"#,
        escape_json(&device_name),
        escape_json(&text_upper),
        escape_json(&encoded),
    );

    match network::send_to_peer_http(&ip, port_val, &payload) {
        Ok(_) => send_json(stream, r#"{"ok":true,"result":{"ok":true}}"#),
        Err(e) => {
            let json = format!(r#"{{"ok":false,"error":"{}"}}"#, escape_json(&e));
            send_json(stream, &json);
        }
    }
}

fn handle_clear_inbox(stream: &mut TcpStream) {
    state::STATE.lock().unwrap().clear_inbox();
    send_json(stream, r#"{"ok":true}"#);
}

fn handle_assign_gpio(stream: &mut TcpStream, body: &str) {
    let bcm = match json_int(body, "bcm") {
        Some(v) => v as i32,
        None => { send_json(stream, r#"{"ok":false,"error":"missing bcm"}"#); return; }
    };
    let role = match json_str(body, "role") {
        Some(r) => r.to_string(),
        None => { send_json(stream, r#"{"ok":false,"error":"missing role"}"#); return; }
    };

    let actual_role = match role.as_str() {
        "dot" => "dot_pin",
        "dash" => "dash_pin",
        "straight" | "data" => "data_pin",
        "speaker" | "led" => "speaker_pin",
        "speaker2" => "speaker_pin2",
        other => other,
    };

    let mut st = state::STATE.lock().unwrap();

    match actual_role {
        "ground" => {
            if bcm == st.settings.speaker_pin {
                send_json(stream, r#"{"ok":false,"error":"Cannot ground the speaker pin"}"#);
                return;
            }
            if !st.settings.grounded_pins.contains(&bcm) {
                st.settings.grounded_pins.push(bcm);
            }
        }
        "clear" => {
            if st.settings.speaker_pin == bcm { st.settings.speaker_pin = 18; }
            if st.settings.speaker_pin2 == Some(bcm) { st.settings.speaker_pin2 = None; }
            if st.settings.data_pin == bcm { st.settings.data_pin = 17; }
            if st.settings.dot_pin == bcm { st.settings.dot_pin = 22; }
            if st.settings.dash_pin == bcm { st.settings.dash_pin = 27; }
            if st.settings.ground_pin == Some(bcm) { st.settings.ground_pin = None; }
            st.settings.grounded_pins.retain(|&gp| gp != bcm);
        }
        "speaker_pin" => { st.settings.speaker_pin = bcm; }
        "speaker_pin2" => {
            if bcm == st.settings.speaker_pin {
                send_json(stream, r#"{"ok":false,"error":"Pin 2 cannot be the same as Pin 1"}"#);
                return;
            }
            st.settings.speaker_pin2 = Some(bcm);
        }
        "data_pin" => { st.settings.data_pin = bcm; }
        "dot_pin" => {
            if bcm == st.settings.dash_pin {
                send_json(stream, r#"{"ok":false,"error":"Dot and dash pins cannot be the same"}"#);
                return;
            }
            st.settings.dot_pin = bcm;
        }
        "dash_pin" => {
            if bcm == st.settings.dot_pin {
                send_json(stream, r#"{"ok":false,"error":"Dot and dash pins cannot be the same"}"#);
                return;
            }
            st.settings.dash_pin = bcm;
        }
        _ => {
            let err = format!(r#"{{"ok":false,"error":"Unknown role: {}"}}"#, escape_json(actual_role));
            send_json(stream, &err);
            return;
        }
    }

    st.save_settings();
    let settings_json = st.settings_json();
    drop(st);
    sound::recreate_gpio();
    let json = format!(r#"{{"ok":true,"settings":{}}}"#, settings_json);
    send_json(stream, &json);
}

fn handle_net_key_mode(stream: &mut TcpStream, body: &str) {
    let enabled = json_bool(body, "enabled").unwrap_or(false);
    {
        let mut st = state::STATE.lock().unwrap();
        st.net_key_mode_enabled = enabled;
        if !enabled {
            st.net_morse_buffer_str.clear();
            st.net_morse_output_str.clear();
        }
    }
    // Drop lock before clear_net_morse_buffers to avoid ABBA deadlock with net_key_released
    if !enabled {
        sound::clear_net_morse_buffers();
    }
    let json = format!(r#"{{"ok":true,"net_key_mode":{}}}"#, enabled);
    send_json(stream, &json);
}

fn handle_net_key_press(stream: &mut TcpStream, body: &str) {
    let pressed = json_bool(body, "pressed").unwrap_or(false);
    if pressed { sound::net_key_pressed(); } else { sound::net_key_released(); }
    send_json(stream, r#"{"ok":true}"#);
}

fn handle_net_clear_morse(stream: &mut TcpStream) {
    {
        let mut st = state::STATE.lock().unwrap();
        st.net_morse_buffer_str.clear();
        st.net_morse_output_str.clear();
    }
    sound::clear_net_morse_buffers();
    send_json(stream, r#"{"ok":true}"#);
}

fn handle_net_send_morse(stream: &mut TcpStream, body: &str) {
    let ip = json_str(body, "ip").unwrap_or("").to_string();
    let port_val = json_int(body, "port").unwrap_or(5000) as u16;
    let text = state::STATE.lock().unwrap().net_morse_output_str.clone();

    if ip.is_empty() || text.is_empty() {
        send_json(stream, r#"{"ok":false,"error":"missing ip or no message composed"}"#);
        return;
    }

    let text_upper = text.to_uppercase();
    let encoded = morse::encode(&text_upper);
    let device_name = state::STATE.lock().unwrap().settings.device_name.clone();

    let payload = format!(
        r#"{{"sender_name":"{}","text":"{}","morse":"{}"}}"#,
        escape_json(&device_name),
        escape_json(&text_upper),
        escape_json(&encoded),
    );

    match network::send_to_peer_http(&ip, port_val, &payload) {
        Ok(_) => {
            {
                let mut st = state::STATE.lock().unwrap();
                st.net_morse_buffer_str.clear();
                st.net_morse_output_str.clear();
            }
            // Drop lock before clear_net_morse_buffers to avoid ABBA deadlock
            sound::clear_net_morse_buffers();
            let resp = format!(r#"{{"ok":true,"result":{{"ok":true}},"sent_text":"{}"}}"#, escape_json(&text_upper));
            send_json(stream, &resp);
        }
        Err(_) => {
            send_json(stream, r#"{"ok":false,"error":"connection failed"}"#);
        }
    }
}

fn handle_net_live_transmit_set(stream: &mut TcpStream, body: &str) {
    let enabled = json_bool(body, "enabled").unwrap_or(false);
    let ip = json_str(body, "ip").unwrap_or("").to_string();
    let port = json_int(body, "port").unwrap_or(5000) as u16;
    
    {
        let mut st = state::STATE.lock().unwrap();
        st.net_live_transmit_enabled = enabled;
        if enabled {
            st.net_live_transmit_target_ip = ip;
            st.net_live_transmit_target_port = port;
        }
    }
    
    let json = format!(
        r#"{{"ok":true,"enabled":{},"ip":"{}","port":{}}}"#,
        enabled,
        json_str(body, "ip").unwrap_or(""),
        port,
    );
    send_json(stream, &json);
}

fn handle_net_live_transmit_symbol(stream: &mut TcpStream, body: &str) {
    let symbol = json_str(body, "symbol").unwrap_or("").to_string();
    
    if symbol != "." && symbol != "-" {
        send_json(stream, r#"{"ok":false,"error":"invalid symbol"}"#);
        return;
    }
    
    let (enabled, ip, port) = {
        let st = state::STATE.lock().unwrap();
        (
            st.net_live_transmit_enabled,
            st.net_live_transmit_target_ip.clone(),
            st.net_live_transmit_target_port,
        )
    };
    
    if !enabled || ip.is_empty() {
        send_json(stream, r#"{"ok":false,"error":"live transmit not enabled"}"#);
        return;
    }
    
    let device_name = state::STATE.lock().unwrap().settings.device_name.clone();
    let payload = format!(
        r#"{{"symbol":"{}","sender_name":"{}"}}"#,
        symbol,
        escape_json(&device_name),
    );
    
    thread::spawn(move || {
        let _ = network::send_to_peer_http_path(&ip, port, "/net_receive_live_symbol", &payload);
    });
    
    send_json(stream, r#"{"ok":true}"#);
}

fn handle_net_live_key(stream: &mut TcpStream, body: &str) {
    let pressed = json_bool(body, "pressed").unwrap_or(false);
    let sym = json_str(body, "sym").unwrap_or("single").to_string();

    // Play or stop tone locally
    if pressed {
        let freq = {
            let st = state::STATE.lock().unwrap();
            if sym == "dash" { st.settings.dash_freq as u32 } else { st.settings.dot_freq as u32 }
        };
        thread::spawn(move || { sound::play_tone(freq, None); });
        state::STATE.lock().unwrap().button_active = true;
    } else {
        sound::stop_tone();
        state::STATE.lock().unwrap().button_active = false;
    }

    // Forward to live transmit peer if enabled
    let (enabled, ip, port, dev_name) = {
        let st = state::STATE.lock().unwrap();
        (
            st.net_live_transmit_enabled,
            st.net_live_transmit_target_ip.clone(),
            st.net_live_transmit_target_port,
            st.settings.device_name.clone(),
        )
    };
    if enabled && !ip.is_empty() {
        thread::spawn(move || {
            network::send_live_key_http(&ip, port, pressed, &dev_name);
        });
    }

    send_json(stream, r#"{"ok":true}"#);
}

fn handle_net_receive_live_key(stream: &mut TcpStream, body: &str) {
    let pressed = json_bool(body, "pressed").unwrap_or(false);
    if pressed {
        thread::spawn(|| { sound::net_live_receive_key_down(); });
    } else {
        sound::net_live_receive_key_up();
    }
    send_json(stream, r#"{"ok":true}"#);
}

fn handle_net_receive_live_symbol(stream: &mut TcpStream, body: &str) {
    let symbol = json_str(body, "symbol").unwrap_or("").to_string();
    
    if symbol != "." && symbol != "-" {
        send_json(stream, r#"{"ok":false,"error":"invalid symbol"}"#);
        return;
    }
    
    // Play the symbol immediately
    thread::spawn(move || {
        sound::play_live_morse_symbol(&symbol);
    });
    
    send_json(stream, r#"{"ok":true}"#);
}

fn handle_kb_enable(stream: &mut TcpStream, body: &str) {
    let enabled = json_bool(body, "enabled").unwrap_or(false);
    keyboard::check_usb_hid();
    let mut st = state::STATE.lock().unwrap();
    st.settings.kb_enabled = enabled;
    st.save_settings();
    let hid_avail = keyboard::USB_HID_AVAILABLE.load(std::sync::atomic::Ordering::Relaxed);
    let warning = if enabled && !hid_avail {
        r#""Keyboard enabled but /dev/hidg0 not found. Try rebooting the Pi.""#
    } else {
        "null"
    };
    let json = format!(
        r#"{{"ok":true,"kb_enabled":{},"usb_hid_available":{},"warning":{}}}"#,
        st.settings.kb_enabled, hid_avail, warning,
    );
    send_json(stream, &json);
}

fn handle_kb_hid_setup(stream: &mut TcpStream) {
    if keyboard::check_usb_hid() {
        send_json(stream, r#"{"ok":true,"usb_hid_available":true,"message":"HID device already available."}"#);
        return;
    }
    let _ = Command::new("sudo").args(["systemctl", "start", "morse-pi-hid"]).output();
    keyboard::check_usb_hid();
    let avail = keyboard::USB_HID_AVAILABLE.load(std::sync::atomic::Ordering::Relaxed);
    if avail {
        send_json(stream, r#"{"ok":true,"usb_hid_available":true,"message":"HID gadget activated via service."}"#);
    } else {
        send_json(stream, r#"{"ok":false,"usb_hid_available":false,"error":"Could not activate HID gadget. Try rebooting."}"#);
    }
}

fn handle_kb_mode(stream: &mut TcpStream, body: &str) {
    let m = json_str(body, "mode").unwrap_or("letters").to_string();
    if m == "letters" || m == "custom" {
        let mut st = state::STATE.lock().unwrap();
        st.settings.kb_mode = m;
        st.save_settings();
    }
    let mode = state::STATE.lock().unwrap().settings.kb_mode.clone();
    let json = format!(r#"{{"ok":true,"kb_mode":"{}"}}"#, escape_json(&mode));
    send_json(stream, &json);
}

fn handle_kb_set_keys(stream: &mut TcpStream, body: &str) {
    {
        let mut st = state::STATE.lock().unwrap();
        if let Some(v) = json_str(body, "dot_key") { st.settings.kb_dot_key = v.into(); }
        if let Some(v) = json_str(body, "dash_key") { st.settings.kb_dash_key = v.into(); }
        st.save_settings();
    }
    let st = state::STATE.lock().unwrap();
    let json = format!(
        r#"{{"ok":true,"kb_dot_key":"{}","kb_dash_key":"{}"}}"#,
        escape_json(&st.settings.kb_dot_key),
        escape_json(&st.settings.kb_dash_key),
    );
    send_json(stream, &json);
}

fn handle_kb_clear(stream: &mut TcpStream) {
    state::STATE.lock().unwrap().kb_output.clear();
    send_json(stream, r#"{"ok":true,"kb_output":""}"#);
}

fn handle_kb_send_custom(stream: &mut TcpStream, body: &str) {
    let st = state::STATE.lock().unwrap();
    if !st.settings.kb_enabled {
        send_json(stream, r#"{"ok":false,"error":"Keyboard not enabled"}"#);
        return;
    }
    if st.settings.kb_mode != "custom" {
        send_json(stream, r#"{"ok":false,"error":"Not in custom mode"}"#);
        return;
    }
    let key_type = json_str(body, "type").unwrap_or("").to_string();
    let key_char = if key_type == "dot" {
        st.settings.kb_dot_key.clone()
    } else if key_type == "dash" {
        st.settings.kb_dash_key.clone()
    } else {
        send_json(stream, r#"{"ok":false,"error":"Invalid key type"}"#);
        return;
    };
    let kb_enabled = st.settings.kb_enabled;
    drop(st);

    let success = keyboard::send_custom_key(&key_char, kb_enabled);
    if success {
        let dc = if key_char == "space" { ' ' } else { key_char.chars().next().unwrap_or('?') };
        state::STATE.lock().unwrap().kb_output.push(dc);
    }
    let st = state::STATE.lock().unwrap();
    let json = format!(
        r#"{{"ok":{},"key_sent":"{}","kb_output":"{}"}}"#,
        success,
        escape_json(&key_char),
        escape_json(&st.kb_output),
    );
    send_json(stream, &json);
}

fn handle_key_press(stream: &mut TcpStream, body: &str) {
    let pressed = json_bool(body, "pressed").unwrap_or(false);
    let mode = state::STATE.lock().unwrap().mode.clone();
    if mode == "speed" {
        if pressed { sound::speed_button_pressed(); } else { sound::speed_button_released(); }
    } else {
        if pressed { sound::send_button_pressed(); } else { sound::send_button_released(); }
    }
    send_json(stream, r#"{"ok":true}"#);
}

fn handle_key_press_dual(stream: &mut TcpStream, body: &str) {
    let sym = json_str(body, "sym").unwrap_or("");
    let pressed = json_bool(body, "pressed").unwrap_or(false);
    if sym == "dot" {
        sound::VIRTUAL_DOT.store(pressed, std::sync::atomic::Ordering::Relaxed);
    } else if sym == "dash" {
        sound::VIRTUAL_DASH.store(pressed, std::sync::atomic::Ordering::Relaxed);
    }
    send_json(stream, r#"{"ok":true}"#);
}

fn handle_reset_stats(stream: &mut TcpStream) {
    let mut st = state::STATE.lock().unwrap();
    st.stats = state::Stats::default();
    st.save_stats();
    let json = st.stats_json();
    send_json(stream, &json);
}

fn handle_clear_speed(stream: &mut TcpStream) {
    {
        let mut st = state::STATE.lock().unwrap();
        st.speed_morse_buffer.clear();
        st.speed_morse_output.clear();
    }
    sound::clear_speed_buffers();
    send_state_json(stream);
}

fn handle_gpio_reinit(stream: &mut TcpStream) {
    let has_error = state::STATE.lock().unwrap().gpio_error.is_some();
    if has_error {
        state::STATE.lock().unwrap().gpio_error_log.push("Import error: GPIO not available".into());
    } else {
        sound::recreate_gpio();
    }
    send_json(stream, r#"{"ok":true,"errors":[]}"#);
}

// ── Helper ───────────────────────────────────────────────────────────────────

fn send_state_json(stream: &mut TcpStream) {
    let json = state::STATE.lock().unwrap().state_json();
    send_json(stream, &json);
}

// ════════════════════════════════════════════════════════════════════════════
//  MAIN
// ════════════════════════════════════════════════════════════════════════════

fn main() {
    // ── Initialise modules ──
    {
        let mut st = state::STATE.lock().unwrap();
        st.init();
    }
    morse::load_words();
    keyboard::check_usb_hid();
    gpio::init();
    sound::recreate_gpio();
    gpio::start_poll_thread();
    network::start_beacons();

    // ── Print startup banner ──
    let gpio_avail = state::STATE.lock().unwrap().gpio_available;
    let pin_mode = state::STATE.lock().unwrap().settings.pin_mode.clone();
    let hid_avail = keyboard::USB_HID_AVAILABLE.load(std::sync::atomic::Ordering::Relaxed);
    let local_ip = network::get_local_ip();
    println!("=== Morse-Pi (Rust) Starting ===");
    println!(" GPIO available:   {}", gpio_avail);
    println!(" Pin mode:         {}", pin_mode);
    println!(" USB HID:          {}", if hid_avail { "AVAILABLE" } else { "NOT AVAILABLE" });
    println!(" Local IP:         {}", local_ip);
    println!(" Listening on:     http://0.0.0.0:5000");
    println!("================================");

    // ── Start HTTP server ──
    // Use 256KB stack per handler thread instead of the default 2MB (Pi Zero only has 512MB RAM).
    let listener = TcpListener::bind("0.0.0.0:5000").expect("Failed to bind to port 5000");
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                if let Err(e) = thread::Builder::new()
                    .stack_size(256 * 1024)
                    .spawn(move || {
                        handle_connection(stream);
                    })
                {
                    eprintln!("thread spawn error: {}", e);
                }
            }
            Err(e) => {
                eprintln!("accept error: {}", e);
            }
        }
    }
}
