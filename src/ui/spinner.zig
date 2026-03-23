/// Animated wait indicator for non-streaming waits.
///
/// The loop is bounded by `limits.max_spinner_ticks` so it
/// cannot run forever even if the caller forgets to stop it.
const std = @import("std");
const limits = @import("../core/limits.zig");
const display = @import("display.zig");

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

    /// Begin the animation on a background thread.
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

    /// Join the background thread and clear the animation line.
    pub fn stop(self: *Spinner) void {
        if (!self.active) return;

        self.stop_flag.store(true, .release);
        if (self.thread) |thread| {
            thread.join();
        }
        self.stdout.writeAll("\r\x1b[2K") catch {
            // Terminal write failed; nothing useful to do.
        };
        self.active = false;
    }
};

/// Pick a deterministic status phrase based on wall-clock time.
pub fn pick_status_phrase() []const u8 {
    const phrases = [_][]const u8{
        "compiling response",
        "warming the model",
        "brewing deterministic magic",
        "taming flaky electrons",
        "turning coffee into tokens",
    };
    const now = std.time.nanoTimestamp();
    const positive: u128 = @intCast(if (now < 0) -now else now);
    const idx: usize = @intCast(positive % phrases.len);
    return phrases[idx];
}

const rotating_phrases = [_][]const u8{
    "burning tokens",
    "works on my machine",
    "compiling confidence",
    "waiting for next token",
};

const suffix_pulse = [_][]const u8{
    "",
    ".",
    "..",
    "...",
    "..",
    ".",
};

/// Bounded animation loop executed on a background thread.
fn spinner_loop(s: *Spinner) void {
    var tick: u32 = 0;

    while (tick < limits.max_spinner_ticks) : (tick += 1) {
        if (s.stop_flag.load(.acquire)) break;

        render_frame(s, tick) catch break;
        std.Thread.sleep(limits.spinner_frame_delay_ns);
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

fn phrase_hold_ticks() usize {
    const hold_ns: u64 = 3 * std.time.ns_per_s;
    const ticks =
        (hold_ns + limits.spinner_frame_delay_ns - 1) /
        limits.spinner_frame_delay_ns;
    return @intCast(if (ticks == 0) 1 else ticks);
}

fn pulse_suffix_for_tick(tick: u32) []const u8 {
    const idx: usize = @intCast(tick % suffix_pulse.len);
    return suffix_pulse[idx];
}

/// Render a single text pulse frame to stdout.
fn render_frame(s: *Spinner, tick: u32) !void {
    const phrase = phrase_for_tick(s.message, tick);
    const suffix = pulse_suffix_for_tick(tick);

    try s.stdout.writeAll("\r\x1b[2K");
    if (s.use_color and tick % 8 < 6) {
        try s.stdout.writeAll(display.Ansi.dim);
    }

    try s.stdout.writeAll(phrase);
    try s.stdout.writeAll(suffix);

    if (s.use_color) {
        try s.stdout.writeAll(display.Ansi.reset);
    }
}
