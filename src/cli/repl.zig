/// REPL loop and single-prompt runner.
const std = @import("std");
const harness = @import("../lib/harness.zig");
const display = @import("display.zig");
const spinner = @import("spinner.zig");
const commands = @import("commands.zig");
const conversation = @import("../lib/conversation.zig");

/// One line of stdin is capped so a pasted or piped blob cannot grow without
/// bound in the REPL allocator.
const max_prompt_bytes: u32 = 1 * 1024 * 1024;

/// REPL configuration options.
pub const ReplOptions = struct {
    /// Whether stdout is a TTY (enables interactive features).
    is_tty: bool,
    /// Whether to use ANSI color codes.
    use_color: bool,
};

/// Enter the interactive REPL loop.
pub fn run(
    allocator: std.mem.Allocator,
    session: *harness.Harness,
    stdout: std.fs.File,
    options: ReplOptions,
) !void {
    const stdin = std.fs.File.stdin().deprecatedReader();

    var store = try conversation.ConversationStore.load_history(
        allocator,
    );
    defer store.deinit();

    _ = try store.new_branch_session(session.get_model());
    try store.apply_active(session);
    try store.save();

    while (true) {
        try display.write_prompt(
            stdout,
            options.use_color,
            session.get_mode(),
        );

        const line = stdin.readUntilDelimiterOrEofAlloc(
            allocator,
            '\n',
            max_prompt_bytes,
        ) catch break;
        const input = line orelse break;
        defer allocator.free(input);

        const trimmed = std.mem.trimRight(u8, input, "\r\n");
        if (trimmed.len == 0) continue;

        if (trimmed[0] == '/') {
            const result = try commands.dispatch(
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

    return run_prompt_streaming(
        session,
        prompt,
        stdout,
        options.is_tty,
        options.use_color,
        show_prefix,
    );
}

/// Shared across API rounds so the spinner stop is idempotent and
/// the prefix only appears before the first visible content token.
const SpinnerCtx = struct {
    spin: *spinner.Spinner,
};

/// Stops the spinner on the first delta of any kind (content or tool call)
/// so tool-call logs on stderr aren't overwritten by spinner frames.
fn on_delta(ctx_ptr: *anyopaque) void {
    const ctx: *SpinnerCtx = @ptrCast(@alignCast(ctx_ptr));
    ctx.spin.stop();
}

const PrefixCtx = struct {
    stdout: std.fs.File,
    use_color: bool,
    model: []const u8,
};

/// Writes the `model>` prefix just before the first visible content token
/// streams to the terminal, so tool-call-only rounds stay silent.
fn on_content(ctx_ptr: *anyopaque) void {
    const ctx: *PrefixCtx = @ptrCast(@alignCast(ctx_ptr));
    display.write_assistant_prefix(
        ctx.stdout,
        ctx.use_color,
        ctx.model,
    ) catch {};
}

/// Write usage statistics line with token counts and context percentage.
fn write_usage_line(
    stdout: std.fs.File,
    use_color: bool,
    usage: harness.TurnUsage,
) !void {
    var buf: [256]u8 = undefined;

    const line = if (usage.available)
        try std.fmt.bufPrint(
            &buf,
            "in={d} out={d} total={d} ctx_used={d}.{d}% ctx_left={d}.{d}% ({d}/{d})",
            .{
                usage.input_tokens,
                usage.output_tokens,
                usage.total_tokens,
                usage.context_used_tenths_pct / 10,
                usage.context_used_tenths_pct % 10,
                usage.context_left_tenths_pct / 10,
                usage.context_left_tenths_pct % 10,
                usage.input_tokens,
                usage.context_window_tokens,
            },
        )
    else
        try std.fmt.bufPrint(
            &buf,
            "tokens unavailable (provider usage missing; context-bound loop unavailable)",
            .{},
        );

    if (use_color) {
        try stdout.writeAll(display.ansi.dim);
    }
    try stdout.writeAll(line);
    if (use_color) {
        try stdout.writeAll(display.ansi.reset);
    }
    try stdout.writeAll("\n");
}

/// Run prompt with streaming response (token-by-token display).
fn run_prompt_streaming(
    session: *harness.Harness,
    prompt: []const u8,
    stdout: std.fs.File,
    is_tty: bool,
    use_color: bool,
    show_prefix: bool,
) !void {
    var spin = spinner.Spinner.init();
    var spin_ctx = SpinnerCtx{ .spin = &spin };
    var prefix_ctx = PrefixCtx{
        .stdout = stdout,
        .use_color = use_color,
        .model = session.get_model(),
    };

    var delta_cb: ?*const fn (*anyopaque) void = null;
    var delta_cb_ctx: ?*anyopaque = null;
    var content_cb: ?*const fn (*anyopaque) void = null;
    var content_cb_ctx: ?*anyopaque = null;

    if (is_tty) {
        const phrase = spinner.pick_status_phrase();
        const stderr = std.fs.File.stderr();
        const spinner_use_color = use_color and stderr.isTty();
        try spin.start(stderr, phrase, spinner_use_color);
        delta_cb = on_delta;
        delta_cb_ctx = @ptrCast(&spin_ctx);
        if (show_prefix) {
            content_cb = on_content;
            content_cb_ctx = @ptrCast(&prefix_ctx);
        }
    } else if (show_prefix) {
        try display.write_assistant_prefix(
            stdout,
            use_color,
            session.get_model(),
        );
    }
    defer spin.stop();

    _ = try session.send(prompt, .{
        .stream_output = stdout,
        .on_first_stream_delta = delta_cb,
        .on_first_stream_delta_ctx = delta_cb_ctx,
        .on_first_content = content_cb,
        .on_first_content_ctx = content_cb_ctx,
    });
    try stdout.writeAll("\n");

    try write_usage_line(stdout, use_color, session.latest_usage());
}
