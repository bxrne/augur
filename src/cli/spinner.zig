/// Indeterminate progress UI: the animation runs on a background thread and
/// is meant to be attached to stderr so token streaming on stdout does not
/// interleave with spinner frames.
const std = @import("std");
const display = @import("display.zig");

/// ~120ms balances smooth motion against wakeups; shorter sleeps spin hot
/// without much perceptible gain on a TTY.
const frame_delay_ns: u64 = 120 * 1_000_000;

pub const Spinner = struct {
    stop_flag: std.atomic.Value(bool),
    thread: ?std.Thread,
    stdout: std.fs.File,
    message: []const u8,
    use_color: bool,
    active: bool,

    pub fn init() Spinner {
        return .{
            .stop_flag = std.atomic.Value(bool).init(false),
            .thread = null,
            .stdout = std.fs.File.stdout(),
            .message = "",
            .use_color = false,
            .active = false,
        };
    }

    pub fn start(
        self: *Spinner,
        stdout: std.fs.File,
        message: []const u8,
        use_color: bool,
    ) !void {
        std.debug.assert(!self.active);

        self.stop_flag = std.atomic.Value(bool).init(false);
        self.stdout = stdout;
        self.message = message;
        self.use_color = use_color;
        self.active = true;
        self.thread = try std.Thread.spawn(
            .{},
            spinner_loop,
            .{self},
        );
    }

    pub fn stop(self: *Spinner) void {
        if (!self.active) return;

        self.stop_flag.store(true, .release);
        if (self.thread) |thread| {
            thread.join();
        }
        self.stdout.writeAll("\r\x1b[2K") catch {};
        self.active = false;
    }
};

/// Picks from a fixed phrase list using the wall clock so the line changes
/// between runs without pulling in a RNG or storing state.
pub fn pick_status_phrase() []const u8 {
    const phrases = [_][]const u8{
        "compiling response",
        "warming the model",
        "brewing deterministic magic",
        "taming flaky electrons",
        "turning coffee into tokens",
    };
    const now = std.time.nanoTimestamp();
    const positive: u128 = @intCast(@as(i128, now));
    const idx: usize = @intCast(positive % phrases.len);
    return phrases[idx];
}

/// Secondary lines swapped in after the base message so long waits still feel
/// animated instead of frozen on one string.
const rotating_phrases = [_][]const u8{
    "burning tokens",
    "works on my machine",
    "compiling confidence",
    "waiting for next token",
};

/// Punctuation cycle on every frame: cheap motion when the phrase itself is
/// unchanged for several seconds.
const suffix_pulse = [_][]const u8{
    "",
    ".",
    "..",
    "...",
    "..",
    ".",
};

fn spinner_loop(s: *Spinner) void {
    var tick: u32 = 0;

    while (true) : (tick +%= 1) {
        if (s.stop_flag.load(.acquire)) break;

        render_frame(s, tick) catch break;
        std.Thread.sleep(frame_delay_ns);
    }
}

fn phrase_for_tick(base: []const u8, tick: u32) []const u8 {
    const step: usize = @intCast(tick);
    const hold: usize = phrase_hold_ticks();
    const slot = step / hold;

    if (base.len > 0) {
        const total = rotating_phrases.len + 1;
        const pos = slot % total;
        if (pos == 0) return base;
        return rotating_phrases[pos - 1];
    }

    return rotating_phrases[slot % rotating_phrases.len];
}

/// Maps a 3s "hold" preference into spinner ticks so phrase rotation stays
/// human-paced relative to `frame_delay_ns`.
fn phrase_hold_ticks() usize {
    const hold_ns: u64 = 3 * std.time.ns_per_s;
    const ticks =
        (hold_ns + frame_delay_ns - 1) /
        frame_delay_ns;
    return @intCast(if (ticks == 0) 1 else ticks);
}

fn pulse_suffix_for_tick(tick: u32) []const u8 {
    const idx: usize = @intCast(tick % suffix_pulse.len);
    return suffix_pulse[idx];
}

test "pick_status_phrase returns a non-empty string" {
    const phrase = pick_status_phrase();
    try std.testing.expect(phrase.len > 0);
}

test "phrase_for_tick returns base phrase at tick 0" {
    const result = phrase_for_tick("custom", 0);
    try std.testing.expectEqualStrings("custom", result);
}

test "phrase_for_tick without base uses rotating" {
    const result = phrase_for_tick("", 0);
    try std.testing.expect(result.len > 0);
}

test "pulse_suffix_for_tick cycles through suffixes" {
    const s0 = pulse_suffix_for_tick(0);
    const s1 = pulse_suffix_for_tick(1);
    const s3 = pulse_suffix_for_tick(3);
    try std.testing.expectEqualStrings("", s0);
    try std.testing.expectEqualStrings(".", s1);
    try std.testing.expectEqualStrings("...", s3);
}

test "phrase_hold_ticks is at least 1" {
    try std.testing.expect(phrase_hold_ticks() >= 1);
}

fn render_frame(s: *Spinner, tick: u32) !void {
    const phrase = phrase_for_tick(s.message, tick);
    const suffix = pulse_suffix_for_tick(tick);

    try s.stdout.writeAll("\r\x1b[2K");
    if (s.use_color and tick % 8 < 6) {
        try s.stdout.writeAll(display.ansi.dim);
    }

    try s.stdout.writeAll(phrase);
    try s.stdout.writeAll(suffix);

    if (s.use_color) {
        try s.stdout.writeAll(display.ansi.reset);
    }
}
