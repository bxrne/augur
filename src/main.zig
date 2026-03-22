const std = @import("std");
const harness = @import("harness.zig");

const Ansi = struct {
    const reset = "\x1b[0m";
    const prompt = "\x1b[1;36m";
    const assistant = "\x1b[1;32m";
    const spinner = "\x1b[1;33m";
    const status = "\x1b[1;35m";
    const label = "\x1b[1;37m";
    const border = "\x1b[38;5;244m";
    const dim = "\x1b[2m";
    const mode_plan = "\x1b[1;34m";
    const mode_build = "\x1b[1;32m";
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

    // REPL sessions always start in planning mode.
    try session.setMode(.plan);
    try writeReplHeader(stdout_file, use_color, session, streaming);

    while (true) {
        try writePrompt(stdout_file, use_color, session.getMode());
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
        if (trimmed[0] == '/') {
            switch (try handleSlashCommand(session, trimmed, stdout_file, use_color)) {
                .handled => continue,
                .quit => break,
            }
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

const SlashCommandResult = enum {
    handled,
    quit,
};

fn handleSlashCommand(
    session: *harness.Harness,
    line: []const u8,
    stdout_file: std.fs.File,
    use_color: bool,
) !SlashCommandResult {
    if (line.len == 0 or line[0] != '/') return .handled;

    var iter = std.mem.tokenizeScalar(u8, line[1..], ' ');
    const cmd = iter.next() orelse {
        try writeStatusLine(stdout_file, use_color, "Commands: /plan /build /model /quit /help");
        return .handled;
    };

    if (std.mem.eql(u8, cmd, "plan")) {
        try session.setMode(.plan);
        try writeStatusLine(stdout_file, use_color, "Mode set to plan.");
        return .handled;
    }

    if (std.mem.eql(u8, cmd, "build")) {
        try session.setMode(.build);
        try writeStatusLine(stdout_file, use_color, "Mode set to build.");
        return .handled;
    }

    if (std.mem.eql(u8, cmd, "model")) {
        if (iter.next()) |model| {
            try session.setModel(model);
            var buffer: [256]u8 = undefined;
            const line_out = try std.fmt.bufPrint(&buffer, "Model set to {s}.", .{model});
            try writeStatusLine(stdout_file, use_color, line_out);
        } else {
            var buffer: [256]u8 = undefined;
            const line_out = try std.fmt.bufPrint(&buffer, "Current model: {s}", .{session.getModel()});
            try writeStatusLine(stdout_file, use_color, line_out);
        }
        return .handled;
    }

    if (std.mem.eql(u8, cmd, "quit")) {
        return .quit;
    }

    if (std.mem.eql(u8, cmd, "help")) {
        try writeStatusLine(stdout_file, use_color, "Slash commands:");
        try writeStatusLine(stdout_file, use_color, "  /plan        - planning mode (no code)");
        try writeStatusLine(stdout_file, use_color, "  /build       - build mode (implementation)");
        try writeStatusLine(stdout_file, use_color, "  /model       - show current OpenRouter model");
        try writeStatusLine(stdout_file, use_color, "  /model <id>  - switch OpenRouter model");
        try writeStatusLine(stdout_file, use_color, "  /quit        - leave the REPL");
        return .handled;
    }

    var buffer: [256]u8 = undefined;
    const line_out = try std.fmt.bufPrint(&buffer, "Unknown command: /{s}. Try /help.", .{cmd});
    try writeStatusLine(stdout_file, use_color, line_out);
    return .handled;
}

fn writeStatusLine(stdout_file: std.fs.File, use_color: bool, message: []const u8) !void {
    if (use_color) {
        try stdout_file.writeAll(Ansi.status);
    }
    try stdout_file.writeAll(message);
    if (use_color) {
        try stdout_file.writeAll(Ansi.reset);
    }
    try stdout_file.writeAll("\n");
}

fn writeReplHeader(
    stdout_file: std.fs.File,
    use_color: bool,
    session: *const harness.Harness,
    streaming: bool,
) !void {
    if (use_color) {
        try stdout_file.writeAll(Ansi.border);
    }
    try stdout_file.writeAll("┌ zip REPL\n");
    if (use_color) {
        try stdout_file.writeAll(Ansi.reset);
    }

    try writeHeaderField(stdout_file, use_color, "mode", harness.modeLabel(session.getMode()), session.getMode());
    try writeHeaderField(stdout_file, use_color, "model", session.getModel(), null);
    try writeHeaderField(stdout_file, use_color, "streaming", if (streaming) "on" else "off", null);

    if (use_color) {
        try stdout_file.writeAll(Ansi.border);
    }
    try stdout_file.writeAll("└ /help for commands • /quit to leave\n\n");
    if (use_color) {
        try stdout_file.writeAll(Ansi.reset);
    }
}

fn writeHeaderField(
    stdout_file: std.fs.File,
    use_color: bool,
    label: []const u8,
    value: []const u8,
    mode_opt: ?harness.Mode,
) !void {
    if (use_color) {
        try stdout_file.writeAll(Ansi.border);
    }
    try stdout_file.writeAll("│ ");
    if (use_color) {
        try stdout_file.writeAll(Ansi.dim);
    }
    try stdout_file.writeAll(label);
    try stdout_file.writeAll(": ");
    if (use_color) {
        try stdout_file.writeAll(Ansi.reset);
        if (mode_opt) |mode| {
            try stdout_file.writeAll(modeColor(mode));
        } else {
            try stdout_file.writeAll(Ansi.label);
        }
    }
    try stdout_file.writeAll(value);
    if (use_color) {
        try stdout_file.writeAll(Ansi.border);
    }
    try stdout_file.writeAll("\n");
}

fn modeColor(mode: harness.Mode) []const u8 {
    return switch (mode) {
        .plan => Ansi.mode_plan,
        .build => Ansi.mode_build,
    };
}

fn writePrompt(stdout_file: std.fs.File, use_color: bool, mode: harness.Mode) !void {
    if (use_color) {
        try stdout_file.writeAll(modeColor(mode));
    }
    try stdout_file.writeAll(harness.modeLabel(mode));
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
    try stdout_file.writeAll("> ");
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
