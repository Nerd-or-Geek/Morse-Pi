# -*- coding: utf-8 -*-
"""Morse code translation, encoding / decoding, and word lists."""

import json
import os
import random

# ── Morse Code Mapping ────────────────────────────────────────────────────────
MORSE_CODE = {
    'A': '.-',   'B': '-...', 'C': '-.-.', 'D': '-..',  'E': '.',
    'F': '..-.', 'G': '--.',  'H': '....', 'I': '..',   'J': '.---',
    'K': '-.-',  'L': '.-..', 'M': '--',   'N': '-.',   'O': '---',
    'P': '.--.', 'Q': '--.-', 'R': '.-.',  'S': '...',  'T': '-',
    'U': '..-',  'V': '...-', 'W': '.--',  'X': '-..-', 'Y': '-.--',
    'Z': '--..',
    '0': '-----', '1': '.----', '2': '..---', '3': '...--', '4': '....-',
    '5': '.....', '6': '-....', '7': '--...', '8': '---..', '9': '----.',
    '.': '.-.-.-', ',': '--..--', '?': '..--..', "'": '.----.',
    '!': '-.-.--', '/': '-..-.', '(': '-.--.', ')': '-.--.-',
    '&': '.-...', ':': '---...', ';': '-.-.-.', '=': '-...-',
    '+': '.-.-.', '-': '-....-', '_': '..--.-', '"': '.-..-.',
    '$': '...-..-', '@': '.--.-.', ' ': '/',
}

# Pre-computed reverse lookup: morse code -> character
REVERSE_MORSE = {v: k for k, v in MORSE_CODE.items()}


def morse_encode(text):
    """Convert plain text to Morse code string."""
    return ' '.join(
        MORSE_CODE.get(c.upper(), '')
        for c in text
        if c.upper() in MORSE_CODE or c == ' '
    )


def morse_decode(morse_str):
    """Convert a Morse code string back to plain text."""
    return ''.join(REVERSE_MORSE.get(code, '?') for code in morse_str.split())


# ── Word lists ────────────────────────────────────────────────────────────────

def load_words():
    if os.path.exists("words.json"):
        with open("words.json", "r") as f:
            return json.load(f)
    return {
        "article":     ["the", "a", "an"],
        "adjective":   ["quick", "slow", "bright", "dark", "swift"],
        "noun":        ["fox", "dog", "cat", "bird", "tree"],
        "verb":        ["jumps", "runs", "flies", "sits", "leaps"],
        "adverb":      ["quickly", "slowly", "boldly"],
        "preposition": ["over", "under", "through", "past"],
    }


words = load_words()


def random_phrase(difficulty="medium"):
    parts = []
    if difficulty == "easy":
        candidates = words.get("nouns", []) + words.get("verbs", [])
        if candidates:
            return random.choice(candidates).upper()
        return "TEST"
    elif difficulty == "medium":
        for cat in ["adjectives", "nouns"]:
            if cat in words and words[cat]:
                parts.append(random.choice(words[cat]))
    else:   # hard
        for cat in ["articles", "adjectives", "nouns", "verbs", "adverbs"]:
            if cat in words and words[cat]:
                parts.append(random.choice(words[cat]))
    if not parts:
        return "THE QUICK FOX"
    return ' '.join(parts).upper()
