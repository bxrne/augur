/// REPL loop and single-prompt runner.
const std = @import("std");
const harness = @import("harness.zig");
const display = @import("../ui/display.zig");
const spinner_mod = @import("../ui/spinner.zig");
const slash = @import("slash_commands.zig");
const store_mod = @import("conversation_store.zig");
const limits = @import("../core/limits.zig");

pub const ReplOptions = struct {
    is_tty: bool,
    use_color: bool,
    streaming: bool,
};

/// Enter the interactive REPL loop.
pub fn run(
    allocator: std.mem.Allocator,
    session: *harness.Harness,
    stdout: std.fs.File,
    options: ReplOptions,
) !void {
    const stdin = std.fs.File.stdin().deprecatedReader();

    var store = try store_mod.ConversationStore.load_or_init(
        allocator,
    );
    defer store.deinit();

    try store.apply_active(session);

    // REPL sessions always start in planning mode.
    try session.setMode(.plan);
    try store.sync_active_from_session(session);
    try store.save();

    var turn: u32 = 0;
    while (turn < limits.max_repl_turns) : (turn += 1) {
        try display.write_prompt(
            stdout,
            options.use_color,
            session.getMode(),
        );

        const line = try stdin.readUntilDelimiterOrEofAlloc(
            allocator,
            '\n',
            limits.max_prompt_bytes,
        ) orelse break;
        defer allocator.free(line);

        const trimmed = std.mem.trimRight(u8, line, "\r\n");
        if (trimmed.len == 0) continue;

        if (trimmed[0] == '/') {
            const result = try slash.dispatch(
                &store,
                session,
                trimmed,
                stdout,
                options.use_color,
            );
            switch (result) {
                .handled => {
                    try store.sync_active_from_session(session);
                    try store.save();
                    continue;
                },
                .quit => break,
                .send_prompt => |prompt| {
                    try run_prompt(
                        session,
                        prompt,
                        stdout,
                        options,
                        true,
                    );
                    try store.sync_active_from_session(session);
                    try store.save();
                    continue;
                },
            }
        }

        try run_prompt(
            session,
            trimmed,
            stdout,
            options,
            true,
        );
        try store.sync_active_from_session(session);
        try store.save();
    }
}

/// Send a single prompt and display the response.
pub fn run_prompt(
    session: *harness.Harness,
    prompt: []const u8,
    stdout: std.fs.File,
    options: ReplOptions,
    show_prefix: bool,
) !void {
    std.debug.assert(prompt.len > 0);

    if (options.streaming) {
        return run_prompt_streaming(
            session,
            prompt,
            stdout,
            options.use_color,
            show_prefix,
        );
    }

    return run_prompt_buffered(
        session,
        prompt,
        stdout,
        options.is_tty,
        options.use_color,
        show_prefix,
    );
}

fn run_prompt_streaming(
    session: *harness.Harness,
    prompt: []const u8,
    stdout: std.fs.File,
    use_color: bool,
    show_prefix: bool,
) !void {
    if (show_prefix) {
        try display.write_assistant_prefix(
            stdout,
            use_color,
            session.getModel(),
        );
    }
    _ = try session.send(prompt, .{
        .streaming = true,
        .stream_output = stdout,
    });
    if (show_prefix) {
        try stdout.writeAll("\n");
    }
}

fn run_prompt_buffered(
    session: *harness.Harness,
    prompt: []const u8,
    stdout: std.fs.File,
    is_tty: bool,
    use_color: bool,
    show_prefix: bool,
) !void {
    var s = spinner_mod.Spinner.init();

    if (is_tty) {
        const phrase = spinner_mod.pick_status_phrase();
        try s.start(stdout, phrase, use_color);
    }
    defer s.stop();

    const response = try session.send(prompt, .{});

    s.stop();

    if (show_prefix) {
        try display.write_assistant_prefix(
            stdout,
            use_color,
            session.getModel(),
        );
    }
    try stdout.writeAll(response);
    if (show_prefix) {
        try stdout.writeAll("\n");
    }
}
