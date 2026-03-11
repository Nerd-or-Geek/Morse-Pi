// ============================================================================
//  Morse-Pi — Morse code translation, encoding / decoding, word lists.
// ============================================================================
const std = @import("std");
const state = @import("state.zig");

// ── Morse code lookup tables ─────────────────────────────────────────────────

pub const Entry = struct { char: u8, code: []const u8 };

pub const MORSE_TABLE = [_]Entry{
    .{ .char = 'A', .code = ".-" },
    .{ .char = 'B', .code = "-..." },
    .{ .char = 'C', .code = "-.-." },
    .{ .char = 'D', .code = "-.." },
    .{ .char = 'E', .code = "." },
    .{ .char = 'F', .code = "..-." },
    .{ .char = 'G', .code = "--." },
    .{ .char = 'H', .code = "...." },
    .{ .char = 'I', .code = ".." },
    .{ .char = 'J', .code = ".---" },
    .{ .char = 'K', .code = "-.-" },
    .{ .char = 'L', .code = ".-.." },
    .{ .char = 'M', .code = "--" },
    .{ .char = 'N', .code = "-." },
    .{ .char = 'O', .code = "---" },
    .{ .char = 'P', .code = ".--." },
    .{ .char = 'Q', .code = "--.-" },
    .{ .char = 'R', .code = ".-." },
    .{ .char = 'S', .code = "..." },
    .{ .char = 'T', .code = "-" },
    .{ .char = 'U', .code = "..-" },
    .{ .char = 'V', .code = "...-" },
    .{ .char = 'W', .code = ".--" },
    .{ .char = 'X', .code = "-..-" },
    .{ .char = 'Y', .code = "-.--" },
    .{ .char = 'Z', .code = "--.." },
    .{ .char = '0', .code = "-----" },
    .{ .char = '1', .code = ".----" },
    .{ .char = '2', .code = "..---" },
    .{ .char = '3', .code = "...--" },
    .{ .char = '4', .code = "....-" },
    .{ .char = '5', .code = "....." },
    .{ .char = '6', .code = "-...." },
    .{ .char = '7', .code = "--..." },
    .{ .char = '8', .code = "---.." },
    .{ .char = '9', .code = "----." },
    .{ .char = '.', .code = ".-.-.-" },
    .{ .char = ',', .code = "--..--" },
    .{ .char = '?', .code = "..--.." },
    .{ .char = '\'', .code = ".----." },
    .{ .char = '!', .code = "-.-.--" },
    .{ .char = '/', .code = "-..-." },
    .{ .char = '(', .code = "-.--." },
    .{ .char = ')', .code = "-.--.-" },
    .{ .char = '&', .code = ".-..." },
    .{ .char = ':', .code = "---..." },
    .{ .char = ';', .code = "-.-.-." },
    .{ .char = '=', .code = "-...-" },
    .{ .char = '+', .code = ".-.-." },
    .{ .char = '-', .code = "-....-" },
    .{ .char = '_', .code = "..--.-" },
    .{ .char = '"', .code = ".-..-." },
    .{ .char = '$', .code = "...-..-" },
    .{ .char = '@', .code = ".--.-." },
};

/// Look up Morse code for a character.
pub fn charToMorse(c: u8) ?[]const u8 {
    const upper = std.ascii.toUpper(c);
    if (upper == ' ') return "/";
    for (MORSE_TABLE) |e| {
        if (e.char == upper) return e.code;
    }
    return null;
}

/// Look up character for a Morse code string.
pub fn morseToChar(code: []const u8) u8 {
    if (std.mem.eql(u8, code, "/")) return ' ';
    for (MORSE_TABLE) |e| {
        if (std.mem.eql(u8, e.code, code)) return e.char;
    }
    return '?';
}

/// Encode plain text to Morse code string.
pub fn encode(text: []const u8) []u8 {
    var buf = std.ArrayList(u8).init(state.gpa);
    for (text) |c| {
        if (charToMorse(c)) |code| {
            if (buf.items.len > 0) buf.append(' ') catch {};
            buf.appendSlice(code) catch {};
        }
    }
    return buf.toOwnedSlice() catch &.{};
}

/// Decode Morse code string to plain text.
pub fn decode(morse_str: []const u8) []u8 {
    var buf = std.ArrayList(u8).init(state.gpa);
    var it = std.mem.splitScalar(u8, morse_str, ' ');
    while (it.next()) |code| {
        if (code.len == 0) continue;
        buf.append(morseToChar(code)) catch {};
    }
    return buf.toOwnedSlice() catch &.{};
}

/// Write the Morse code lookup table as JSON (matches Python MORSE_CODE dict).
pub fn writeMorseTableJson(w: anytype) !void {
    try w.writeAll("{");
    var first = true;
    for (MORSE_TABLE) |e| {
        if (!first) try w.writeAll(",");
        first = false;
        try std.fmt.format(w, "\"{c}\":\"{s}\"", .{ e.char, e.code });
    }
    try w.writeAll(",\" \":\"/\"}");
}

// ── Word lists ───────────────────────────────────────────────────────────────

const WordCategory = struct {
    name: []const u8,
    words: []const []const u8,
};

// Fallback word lists (overridden if words.json is loaded)
const fallback_articles = [_][]const u8{ "the", "a", "an" };
const fallback_adjectives = [_][]const u8{ "big", "small", "red", "blue", "happy", "sad", "fast", "slow" };
const fallback_nouns = [_][]const u8{ "dog", "cat", "house", "car", "apple", "book", "tree", "river" };
const fallback_verbs = [_][]const u8{ "run", "jump", "eat", "sleep", "read", "write", "think" };
const fallback_adverbs = [_][]const u8{ "quickly", "slowly", "loudly", "quietly" };

var words_articles: []const []const u8 = &fallback_articles;
var words_adjectives: []const []const u8 = &fallback_adjectives;
var words_nouns: []const []const u8 = &fallback_nouns;
var words_verbs: []const []const u8 = &fallback_verbs;
var words_adverbs: []const []const u8 = &fallback_adverbs;

pub fn loadWords() void {
    const data = std.fs.cwd().readFileAlloc(state.gpa, "words.json", 1 << 20) catch return;
    defer state.gpa.free(data);

    const parsed = std.json.parseFromSlice(std.json.Value, state.gpa, data, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;
    const obj = parsed.value.object;

    inline for (.{
        .{ "articles", &words_articles },
        .{ "adjectives", &words_adjectives },
        .{ "nouns", &words_nouns },
        .{ "verbs", &words_verbs },
        .{ "adverbs", &words_adverbs },
    }) |pair| {
        if (obj.get(pair[0])) |arr| {
            if (arr == .array) {
                var list = std.ArrayList([]const u8).init(state.gpa);
                for (arr.array.items) |item| {
                    if (item == .string) {
                        list.append(state.gpa.dupe(u8, item.string) catch continue) catch {};
                    }
                }
                pair[1].* = list.toOwnedSlice() catch pair[1].*;
            }
        }
    }
}

var prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0);
var prng_seeded: bool = false;

fn getRandom() std.Random {
    if (!prng_seeded) {
        prng = std.Random.DefaultPrng.init(@as(u64, @bitCast(std.time.milliTimestamp())));
        prng_seeded = true;
    }
    return prng.random();
}

fn pickRandom(list: []const []const u8) []const u8 {
    if (list.len == 0) return "TEST";
    return list[getRandom().intRangeAtMost(usize, 0, list.len - 1)];
}

/// Generate a random phrase based on difficulty.
pub fn randomPhrase(difficulty: []const u8) []u8 {
    var buf = std.ArrayList(u8).init(state.gpa);

    if (std.mem.eql(u8, difficulty, "easy")) {
        // Single noun or verb
        const all = state.gpa.alloc([]const u8, words_nouns.len + words_verbs.len) catch
            return state.gpa.dupe(u8, "TEST") catch &.{};
        @memcpy(all[0..words_nouns.len], words_nouns);
        @memcpy(all[words_nouns.len..], words_verbs);
        const picked = pickRandom(all);
        state.gpa.free(all);
        for (picked) |c| buf.append(std.ascii.toUpper(c)) catch {};
    } else if (std.mem.eql(u8, difficulty, "hard")) {
        // article + adjective + noun + verb + adverb
        const parts = [_][]const []const u8{
            words_articles,
            words_adjectives,
            words_nouns,
            words_verbs,
            words_adverbs,
        };
        for (parts, 0..) |list, i| {
            if (list.len == 0) continue;
            if (i > 0 and buf.items.len > 0) buf.append(' ') catch {};
            for (pickRandom(list)) |c| buf.append(std.ascii.toUpper(c)) catch {};
        }
    } else {
        // medium: adjective + noun
        if (words_adjectives.len > 0) {
            for (pickRandom(words_adjectives)) |c| buf.append(std.ascii.toUpper(c)) catch {};
        }
        if (words_nouns.len > 0) {
            if (buf.items.len > 0) buf.append(' ') catch {};
            for (pickRandom(words_nouns)) |c| buf.append(std.ascii.toUpper(c)) catch {};
        }
    }

    if (buf.items.len == 0) buf.appendSlice("THE QUICK FOX") catch {};
    return buf.toOwnedSlice() catch state.gpa.dupe(u8, "TEST") catch &.{};
}
