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
            options.is_tty,
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

const StreamSpinnerCtx = struct {
    spinner: *spinner_mod.Spinner,
};

fn stop_stream_spinner(ctx_ptr: *anyopaque) void {
    const ctx: *StreamSpinnerCtx = @ptrCast(@alignCast(ctx_ptr));
    ctx.spinner.stop();
}

fn write_usage_line(
    stdout: std.fs.File,
    use_color: bool,
    usage: harness.TurnUsage,
) !void {
    var buf: [256]u8 = undefined;

    const line = if (usage.available)
        try std.fmt.bufPrint(
            &buf,
            "tokens in={d} out={d} total={d} ctx={d}.{d}% ({d}/{d}) turns<={d}",
            .{
                usage.input_tokens,
                usage.output_tokens,
                usage.total_tokens,
                usage.context_used_tenths_pct / 10,
                usage.context_used_tenths_pct % 10,
                usage.input_tokens,
                usage.context_window_tokens,
                usage.dynamic_turn_cap,
            },
        )
    else
        try std.fmt.bufPrint(
            &buf,
            "tokens unavailable (provider usage missing) turns<={d}",
            .{usage.dynamic_turn_cap},
        );

    if (use_color) {
        try stdout.writeAll(display.Ansi.dim);
    }
    try stdout.writeAll(line);
    if (use_color) {
        try stdout.writeAll(display.Ansi.reset);
    }
    try stdout.writeAll("\n");
}

fn run_prompt_streaming(
    session: *harness.Harness,
    prompt: []const u8,
    stdout: std.fs.File,
    is_tty: bool,
    use_color: bool,
    show_prefix: bool,
) !void {
    var s = spinner_mod.Spinner.init();
    var spinner_ctx = StreamSpinnerCtx{ .spinner = &s };

    var on_first_stream_delta: ?*const fn (*anyopaque) void = null;
    var on_first_stream_delta_ctx: ?*anyopaque = null;

    if (is_tty) {
        const phrase = spinner_mod.pick_status_phrase();
        const stderr = std.fs.File.stderr();
        const spinner_use_color = use_color and stderr.isTty();
        try s.start(stderr, phrase, spinner_use_color);
        on_first_stream_delta = stop_stream_spinner;
        on_first_stream_delta_ctx = @ptrCast(&spinner_ctx);
    }
    defer s.stop();

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
        .on_first_stream_delta = on_first_stream_delta,
        .on_first_stream_delta_ctx = on_first_stream_delta_ctx,
    });
    try stdout.writeAll("\n");

    try write_usage_line(
        stdout,
        use_color,
        session.latestUsage(),
    );
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
    try stdout.writeAll("\n");

    try write_usage_line(
        stdout,
        use_color,
        session.latestUsage(),
    );
}
