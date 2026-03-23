/// Slash-command dispatcher for the REPL.
///
/// Each command is a small function so the dispatcher stays well
/// under the 70-line limit.
const std = @import("std");
const harness = @import("harness.zig");
const display = @import("../ui/display.zig");
const store_mod = @import("conversation_store.zig");

pub const Result = enum {
    handled,
    quit,
};

/// Dispatch a "/" command. Returns `.quit` when the user wants
/// to leave the REPL.
pub fn dispatch(
    store: *store_mod.ConversationStore,
    session: *harness.Harness,
    line: []const u8,
    stdout: std.fs.File,
    use_color: bool,
) !Result {
    std.debug.assert(line.len > 0);
    if (line[0] != '/') return .handled;

    var iter = std.mem.tokenizeScalar(u8, line[1..], ' ');
    const cmd = iter.next() orelse {
        try display.write_status_line(
            stdout,
            use_color,
            "Commands: /plan /build /model"
                ++ " /new /switch /convos /quit /help",
        );
        return .handled;
    };

    if (std.mem.eql(u8, cmd, "plan")) {
        return handle_mode(session, stdout, use_color, .plan);
    }
    if (std.mem.eql(u8, cmd, "build")) {
        return handle_mode(session, stdout, use_color, .build);
    }
    if (std.mem.eql(u8, cmd, "model")) {
        return handle_model(session, &iter, stdout, use_color);
    }
    if (std.mem.eql(u8, cmd, "new")) {
        return handle_new(store, session, &iter, stdout, use_color);
    }
    if (std.mem.eql(u8, cmd, "switch")) {
        return handle_switch(
            store,
            session,
            &iter,
            stdout,
            use_color,
        );
    }
    if (std.mem.eql(u8, cmd, "convos")) {
        return handle_convos(store, stdout, use_color);
    }
    if (std.mem.eql(u8, cmd, "quit")) return .quit;
    if (std.mem.eql(u8, cmd, "help")) {
        return handle_help(stdout, use_color);
    }

    var buf: [256]u8 = undefined;
    const out = try std.fmt.bufPrint(
        &buf,
        "Unknown command: /{s}. Try /help.",
        .{cmd},
    );
    try display.write_status_line(stdout, use_color, out);
    return .handled;
}

fn handle_mode(
    session: *harness.Harness,
    stdout: std.fs.File,
    use_color: bool,
    mode: harness.Mode,
) !Result {
    try session.setMode(mode);
    const label = switch (mode) {
        .plan => "Mode set to plan.",
        .build => "Mode set to build.",
    };
    try display.write_status_line(stdout, use_color, label);
    return .handled;
}

const TokenIterator = std.mem.TokenIterator(u8, .scalar);

fn handle_model(
    session: *harness.Harness,
    iter: *TokenIterator,
    stdout: std.fs.File,
    use_color: bool,
) !Result {
    var buf: [256]u8 = undefined;

    if (iter.next()) |model| {
        try session.setModel(model);
        const out = try std.fmt.bufPrint(
            &buf,
            "Model set to {s}.",
            .{model},
        );
        try display.write_status_line(stdout, use_color, out);
    } else {
        const out = try std.fmt.bufPrint(
            &buf,
            "Current model: {s}",
            .{session.getModel()},
        );
        try display.write_status_line(stdout, use_color, out);
    }
    return .handled;
}

fn handle_new(
    store: *store_mod.ConversationStore,
    session: *harness.Harness,
    iter: *TokenIterator,
    stdout: std.fs.File,
    use_color: bool,
) !Result {
    const requested = iter.next();
    const name = store.create_and_switch(
        session,
        requested,
    ) catch |err| {
        if (err == error.ConversationAlreadyExists) {
            try display.write_status_line(
                stdout,
                use_color,
                "Conversation already exists."
                    ++ " Use /switch <name>.",
            );
            return .handled;
        }
        return err;
    };

    var buf: [256]u8 = undefined;
    const count = store_mod.context_message_count(
        session.messagesSlice(),
    );
    const out = try std.fmt.bufPrint(
        &buf,
        "Switched to new conversation:"
            ++ " {s} (loaded {d} messages)",
        .{ name, count },
    );
    try display.write_status_line(stdout, use_color, out);
    return .handled;
}

fn handle_switch(
    store: *store_mod.ConversationStore,
    session: *harness.Harness,
    iter: *TokenIterator,
    stdout: std.fs.File,
    use_color: bool,
) !Result {
    const name = iter.next() orelse {
        try display.write_status_line(
            stdout,
            use_color,
            "Usage: /switch <name>",
        );
        return .handled;
    };

    const switched = try store.switch_conversation(session, name);
    if (!switched) {
        try display.write_status_line(
            stdout,
            use_color,
            "Conversation not found. Try /convos.",
        );
        return .handled;
    }

    var buf: [256]u8 = undefined;
    const count = store_mod.context_message_count(
        session.messagesSlice(),
    );
    const out = try std.fmt.bufPrint(
        &buf,
        "Switched to conversation:"
            ++ " {s} (loaded {d} messages)",
        .{ store.active_name(), count },
    );
    try display.write_status_line(stdout, use_color, out);
    return .handled;
}

fn handle_convos(
    store: *store_mod.ConversationStore,
    stdout: std.fs.File,
    use_color: bool,
) !Result {
    try display.write_status_line(
        stdout,
        use_color,
        "Conversations:",
    );

    for (store.conversations.items, 0..) |conv, i| {
        var buf: [512]u8 = undefined;
        const marker = if (i == store.active_index) "*" else " ";
        const out = try std.fmt.bufPrint(
            &buf,
            " {s} {s} (mode={s}, model={s}, messages={d})",
            .{
                marker,
                conv.name,
                harness.mode_label(conv.mode),
                conv.model,
                conv.messages.items.len,
            },
        );
        try display.write_status_line(stdout, use_color, out);
    }
    return .handled;
}

fn handle_help(
    stdout: std.fs.File,
    use_color: bool,
) !Result {
    const lines = [_][]const u8{
        "Slash commands:",
        "  /plan          - planning mode (no code)",
        "  /build         - build mode (implementation)",
        "  /model         - show current OpenRouter model",
        "  /model <id>    - switch OpenRouter model",
        "  /new [name]    - create + switch conversation",
        "  /switch <name> - switch conversation",
        "  /convos        - list conversations",
        "  /quit          - leave the REPL",
    };
    for (lines) |l| {
        try display.write_status_line(stdout, use_color, l);
    }
    return .handled;
}
