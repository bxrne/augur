const std = @import("std");
const harness = @import("harness.zig");

const Ansi = struct {
    const reset = "\x1b[0m";
    const prompt = "\x1b[1;36m";
    const assistant = "\x1b[1;32m";
    const spinner = "\x1b[1;33m";
};

const CliOptions = struct {
    prompt: ?[]const u8 = null,
    streaming: bool = true,
};

const Spinner = struct {
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    stdout: std.fs.File = undefined,
    message: []const u8 = "",
    use_color: bool = false,
    active: bool = false,

    pub fn start(self: *Spinner, stdout: std.fs.File, message: []const u8, use_color: bool) !void {
        self.stop_flag = std.atomic.Value(bool).init(false);
        self.stdout = stdout;
        self.message = message;
        self.use_color = use_color;
        self.active = true;
        self.thread = try std.Thread.spawn(.{}, spinnerLoop, .{self});
    }

    pub fn stop(self: *Spinner) void {
        if (!self.active) return;
        self.stop_flag.store(true, .release);
        if (self.thread) |thread| {
            thread.join();
        }
        _ = self.stdout.writeAll("\r\x1b[2K") catch {};
        self.active = false;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const api_key = std.posix.getenv("OPENROUTER_API_KEY") orelse @panic("OPENROUTER_API_KEY is not set");
    const base_url = std.posix.getenv("OPENROUTER_BASE_URL") orelse "https://openrouter.ai/api/v1";

    var session = harness.Harness.init(allocator, api_key, base_url);
    defer session.deinit();

    const options = try parseArgs(args);
    const stdout_file = std.fs.File.stdout();
    const is_tty = stdout_file.isTty();
    const use_color = is_tty;

    if (options.prompt) |prompt| {
        try runPrompt(&session, prompt, stdout_file, is_tty, use_color, options.streaming, false);
        return;
    }

    try runRepl(allocator, &session, stdout_file, is_tty, use_color, options.streaming);
}

fn parseArgs(args: []const [:0]u8) !CliOptions {
    var options = CliOptions{};
    var idx: usize = 1;

    while (idx < args.len) : (idx += 1) {
        const arg = std.mem.sliceTo(args[idx], 0);
        if (std.mem.eql(u8, arg, "-p")) {
            if (idx + 1 >= args.len) return error.MissingPrompt;
            options.prompt = std.mem.sliceTo(args[idx + 1], 0);
            idx += 1;
        } else if (std.mem.eql(u8, arg, "--stream")) {
            options.streaming = true;
        } else if (std.mem.eql(u8, arg, "--no-stream")) {
            options.streaming = false;
        }
    }

    return options;
}

fn runRepl(
    allocator: std.mem.Allocator,
    session: *harness.Harness,
    stdout_file: std.fs.File,
    is_tty: bool,
    use_color: bool,
    streaming: bool,
) !void {
    const stdin = std.fs.File.stdin().deprecatedReader();

    while (true) {
        try writePrompt(stdout_file, use_color);
        const line_opt = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024 * 1024);
        if (line_opt == null) {
            break;
        }
        const line = line_opt.?;
        defer allocator.free(line);

        const trimmed = std.mem.trimRight(u8, line, "\r\n");
        if (trimmed.len == 0) {
            continue;
        }
        if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) {
            break;
        }

        try runPrompt(session, trimmed, stdout_file, is_tty, use_color, streaming, true);
    }
}

fn runPrompt(
    session: *harness.Harness,
    prompt: []const u8,
    stdout_file: std.fs.File,
    is_tty: bool,
    use_color: bool,
    streaming: bool,
    show_prefix: bool,
) !void {
    if (streaming) {
        if (show_prefix) {
            try writeAssistantPrefix(stdout_file, use_color);
        }
        _ = try session.send(prompt, .{ .streaming = true, .stream_output = stdout_file });
        if (show_prefix) {
            try stdout_file.writeAll("\n");
        }
        return;
    }

    var spinner: Spinner = undefined;
    var spinner_active = false;
    if (is_tty) {
        const phrase = pickStatusPhrase();
        try spinner.start(stdout_file, phrase, use_color);
        spinner_active = true;
    }

    const response = session.send(prompt, .{}) catch |err| {
        if (spinner_active) spinner.stop();
        return err;
    };

    if (spinner_active) spinner.stop();

    if (show_prefix) {
        try writeAssistantPrefix(stdout_file, use_color);
    }
    try stdout_file.writeAll(response);
    if (show_prefix) {
        try stdout_file.writeAll("\n");
    }
}

fn writePrompt(stdout_file: std.fs.File, use_color: bool) !void {
    if (use_color) {
        try stdout_file.writeAll(Ansi.prompt);
    }
    try stdout_file.writeAll("> ");
    if (use_color) {
        try stdout_file.writeAll(Ansi.reset);
    }
}

fn writeAssistantPrefix(stdout_file: std.fs.File, use_color: bool) !void {
    if (use_color) {
        try stdout_file.writeAll(Ansi.assistant);
    }
    try stdout_file.writeAll("zip> ");
    if (use_color) {
        try stdout_file.writeAll(Ansi.reset);
    }
}

fn pickStatusPhrase() []const u8 {
    const phrases = [_][]const u8{
        "compiling response",
        "building reply",
        "shipping bytes",
        "warming the model",
        "linking thoughts",
    };
    const now = std.time.nanoTimestamp();
    const positive = if (now < 0) -now else now;
    const idx = @as(usize, @intCast(@mod(positive, @as(i128, phrases.len))));
    return phrases[idx];
}

fn spinnerLoop(spinner: *Spinner) void {
    const frames = [_][]const u8{ "|", "/", "-", "\\" };
    var frame_index: usize = 0;

    while (!spinner.stop_flag.load(.acquire)) {
        _ = spinner.stdout.writeAll("\r\x1b[2K") catch {};
        if (spinner.use_color) {
            _ = spinner.stdout.writeAll(Ansi.spinner) catch {};
        }
        _ = spinner.stdout.writeAll(frames[frame_index]) catch {};
        _ = spinner.stdout.writeAll(" ") catch {};
        _ = spinner.stdout.writeAll(spinner.message) catch {};
        if (spinner.use_color) {
            _ = spinner.stdout.writeAll(Ansi.reset) catch {};
        }
        _ = spinner.stdout.writeAll("...") catch {};

        frame_index = (frame_index + 1) % frames.len;
        std.Thread.sleep(120 * std.time.ns_per_ms);
    }
}
