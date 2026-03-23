/// Animated spinner for non-streaming waits.
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

    /// Begin the spinner animation on a background thread.
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

    /// Join the background thread and clear the spinner line.
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
    "convincing the compiler",
    "chasing a race condition",
    "aligning semicolons",
    "rendering extra confidence",
};

const frames = [_][]const u8{ "|", "/", "-", "\\" };

/// Bounded animation loop executed on a background thread.
fn spinner_loop(s: *Spinner) void {
    var frame_index: u32 = 0;
    var tick: u32 = 0;

    while (tick < limits.max_spinner_ticks) : (tick += 1) {
        if (s.stop_flag.load(.acquire)) break;

        render_frame(s, frame_index, tick) catch break;
        frame_index = (frame_index + 1) % @as(u32, @intCast(frames.len));
        std.Thread.sleep(limits.spinner_frame_delay_ns);
    }
}

fn phrase_for_tick(base: []const u8, tick: u32) []const u8 {
    if (base.len > 0 and tick % 4 == 0) {
        return base;
    }
    const idx: usize = @intCast(tick % rotating_phrases.len);
    return rotating_phrases[idx];
}

/// Render a single spinner frame to stdout.
fn render_frame(
    s: *Spinner,
    frame_index: u32,
    tick: u32,
) !void {
    const phrase = phrase_for_tick(s.message, tick);

    try s.stdout.writeAll("\r\x1b[2K");
    if (s.use_color) {
        const color = switch (tick % 3) {
            0 => display.Ansi.spinner,
            1 => display.Ansi.status,
            else => display.Ansi.prompt,
        };
        try s.stdout.writeAll(color);
    }
    try s.stdout.writeAll(frames[frame_index]);
    try s.stdout.writeAll(" ");
    try s.stdout.writeAll(phrase);
    if (s.use_color) {
        try s.stdout.writeAll(display.Ansi.reset);
    }
    try s.stdout.writeAll("...");
}
