// ============================================================================
//  Morse-Pi — Morse code translation, encoding / decoding, word lists.
// ============================================================================
use rand::seq::SliceRandom;
use rand::thread_rng;
use std::fs;

// ── Morse code lookup table ──────────────────────────────────────────────────

pub static MORSE_TABLE: &[(char, &str)] = &[
    ('A', ".-"),    ('B', "-..."),  ('C', "-.-."),  ('D', "-.."),
    ('E', "."),     ('F', "..-."),  ('G', "--."),   ('H', "...."),
    ('I', ".."),    ('J', ".---"),  ('K', "-.-"),   ('L', ".-.."),
    ('M', "--"),    ('N', "-."),    ('O', "---"),    ('P', ".--."),
    ('Q', "--.-"),  ('R', ".-."),   ('S', "..."),    ('T', "-"),
    ('U', "..-"),   ('V', "...-"),  ('W', ".--"),    ('X', "-..-"),
    ('Y', "-.--"),  ('Z', "--.."),
    ('0', "-----"), ('1', ".----"), ('2', "..---"),  ('3', "...--"),
    ('4', "....-"), ('5', "....."), ('6', "-...."),  ('7', "--..."),
    ('8', "---.."), ('9', "----."),
    ('.', ".-.-.-"), (',', "--..--"), ('?', "..--.."), ('\'', ".----."),
    ('!', "-.-.--"), ('/', "-..-."), ('(', "-.--."),  (')', "-.--.-"),
    ('&', ".-..."),  (':', "---..."), (';', "-.-.-."), ('=', "-...-"),
    ('+', ".-.-."),  ('-', "-....-"), ('_', "..--.-"), ('"', ".-..-."),
    ('$', "...-..-"), ('@', ".--.-."),
];

/// Look up Morse code for a character.
pub fn char_to_morse(c: char) -> Option<&'static str> {
    let upper = c.to_ascii_uppercase();
    if upper == ' ' {
        return Some("/");
    }
    MORSE_TABLE.iter().find(|(ch, _)| *ch == upper).map(|(_, code)| *code)
}

/// Look up character for a Morse code string.
pub fn morse_to_char(code: &str) -> char {
    if code == "/" {
        return ' ';
    }
    MORSE_TABLE
        .iter()
        .find(|(_, c)| *c == code)
        .map(|(ch, _)| *ch)
        .unwrap_or('?')
}

/// Encode plain text to Morse code string.
pub fn encode(text: &str) -> String {
    let mut buf = String::new();
    for c in text.chars() {
        if let Some(code) = char_to_morse(c) {
            if !buf.is_empty() {
                buf.push(' ');
            }
            buf.push_str(code);
        }
    }
    buf
}

/// Decode Morse code string to plain text.
pub fn decode(morse_str: &str) -> String {
    let mut buf = String::new();
    for code in morse_str.split(' ') {
        if code.is_empty() {
            continue;
        }
        buf.push(morse_to_char(code));
    }
    buf
}

/// Write the Morse code lookup table as JSON string.
pub fn morse_table_json() -> String {
    let mut entries: Vec<String> = MORSE_TABLE
        .iter()
        .map(|(ch, code)| format!("\"{}\":\"{}\"", ch, code))
        .collect();
    entries.push("\" \":\"/\"".into());
    format!("{{{}}}", entries.join(","))
}

// ── Word lists ───────────────────────────────────────────────────────────────

pub struct WordLists {
    pub articles: Vec<String>,
    pub adjectives: Vec<String>,
    pub nouns: Vec<String>,
    pub verbs: Vec<String>,
    pub adverbs: Vec<String>,
}

impl Default for WordLists {
    fn default() -> Self {
        Self {
            articles: vec!["the".into(), "a".into(), "an".into()],
            adjectives: vec![
                "big".into(), "small".into(), "red".into(), "blue".into(),
                "happy".into(), "sad".into(), "fast".into(), "slow".into(),
            ],
            nouns: vec![
                "dog".into(), "cat".into(), "house".into(), "car".into(),
                "apple".into(), "book".into(), "tree".into(), "river".into(),
            ],
            verbs: vec![
                "run".into(), "jump".into(), "eat".into(), "sleep".into(),
                "read".into(), "write".into(), "think".into(),
            ],
            adverbs: vec!["quickly".into(), "slowly".into(), "loudly".into(), "quietly".into()],
        }
    }
}

static WORDS: once_cell::sync::Lazy<std::sync::Mutex<WordLists>> =
    once_cell::sync::Lazy::new(|| std::sync::Mutex::new(WordLists::default()));

pub fn load_words() {
    let data = match fs::read_to_string("words.json") {
        Ok(d) => d,
        Err(_) => return,
    };
    let parsed: serde_json::Value = match serde_json::from_str(&data) {
        Ok(v) => v,
        Err(_) => return,
    };
    let obj = match parsed.as_object() {
        Some(o) => o,
        None => return,
    };

    let mut w = WORDS.lock().unwrap();

    fn extract_strings(obj: &serde_json::Map<String, serde_json::Value>, key: &str) -> Option<Vec<String>> {
        obj.get(key)?.as_array().map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect()
        })
    }

    if let Some(v) = extract_strings(obj, "articles") { w.articles = v; }
    if let Some(v) = extract_strings(obj, "adjectives") { w.adjectives = v; }
    if let Some(v) = extract_strings(obj, "nouns") { w.nouns = v; }
    if let Some(v) = extract_strings(obj, "verbs") { w.verbs = v; }
    if let Some(v) = extract_strings(obj, "adverbs") { w.adverbs = v; }
}

fn pick_random(list: &[String]) -> &str {
    let mut rng = thread_rng();
    list.choose(&mut rng).map(|s| s.as_str()).unwrap_or("TEST")
}

/// Generate a random phrase based on difficulty.
pub fn random_phrase(difficulty: &str) -> String {
    let w = WORDS.lock().unwrap();
    let mut rng = thread_rng();

    match difficulty {
        "easy" => {
            // Single noun or verb
            let mut all: Vec<&str> = Vec::new();
            for s in &w.nouns { all.push(s); }
            for s in &w.verbs { all.push(s); }
            let picked = all.choose(&mut rng).map(|s| *s).unwrap_or("TEST");
            picked.to_uppercase()
        }
        "hard" => {
            // article + adjective + noun + verb + adverb
            let parts: Vec<&[String]> = vec![
                &w.articles, &w.adjectives, &w.nouns, &w.verbs, &w.adverbs,
            ];
            let mut result = String::new();
            for list in parts {
                if list.is_empty() { continue; }
                if !result.is_empty() { result.push(' '); }
                result.push_str(&pick_random(list).to_uppercase());
            }
            if result.is_empty() { "THE QUICK FOX".into() } else { result }
        }
        _ => {
            // medium: adjective + noun
            let mut result = String::new();
            if !w.adjectives.is_empty() {
                result.push_str(&pick_random(&w.adjectives).to_uppercase());
            }
            if !w.nouns.is_empty() {
                if !result.is_empty() { result.push(' '); }
                result.push_str(&pick_random(&w.nouns).to_uppercase());
            }
            if result.is_empty() { "THE QUICK FOX".into() } else { result }
        }
    }
}
