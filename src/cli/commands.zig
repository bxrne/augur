/// Slash commands parsed from REPL input (`/plan`, `/switch`, …): thin dispatch
/// into session and conversation store updates.
const std = @import("std");
const harness = @import("../lib/harness.zig");
const types = @import("../lib/types.zig");
const display = @import("display.zig");
const conversation = @import("../lib/conversation.zig");

/// Outcome of handling a `/…` line: consume locally, exit the REPL, or hand a
/// synthetic user prompt to the model (`/init`).
pub const Result = union(enum) {
    handled,
    quit,
    send_prompt: []const u8,
};

/// Parsed command name; `switch_cmd` maps the user-visible `/switch` because
/// `switch` is reserved in Zig.
const Command = enum {
    plan,
    build,
    pair,
    model,
    new,
    switch_cmd,
    convos,
    init,
    quit,
    help,
    unknown,
};

fn parse_command(cmd: []const u8) Command {
    return std.meta.stringToEnum(Command, cmd) orelse .unknown;
}

pub fn dispatch(
    store: *conversation.ConversationStore,
    session: *harness.Harness,
    line: []const u8,
    stdout: std.fs.File,
    use_color: bool,
) !Result {
    std.debug.assert(line.len > 0);
    if (line[0] != '/') return .handled;

    var iter = std.mem.tokenizeScalar(u8, line[1..], ' ');
    const cmd_str = iter.next() orelse {
        try display.write_status_line(
            stdout,
            use_color,
            "Commands: /plan /build /pair /model /new /switch /convos /quit /help",
        );
        return .handled;
    };

    const cmd = parse_command(cmd_str);

    return switch (cmd) {
        .plan => handle_mode(session, stdout, use_color, .plan),
        .build => handle_mode(session, stdout, use_color, .build),
        .pair => handle_mode(session, stdout, use_color, .pair),
        .model => handle_model(session, &iter, stdout, use_color),
        .new => handle_new(store, session, &iter, stdout, use_color),
        .switch_cmd => handle_switch(store, session, &iter, stdout, use_color),
        .convos => handle_convos(store, stdout, use_color),
        .init => handle_init(),
        .quit => .quit,
        .help => handle_help(stdout, use_color),
        .unknown => {
            var buf: [256]u8 = @splat(0);
            const out = try std.fmt.bufPrint(
                &buf,
                "Unknown command: /{s}. Try /help.",
                .{cmd_str},
            );
            try display.write_status_line(stdout, use_color, out);
            return .handled;
        },
    };
}

fn handle_mode(
    session: *harness.Harness,
    stdout: std.fs.File,
    use_color: bool,
    mode: types.Mode,
) !Result {
    try session.set_mode(mode);
    const label = switch (mode) {
        .plan => "Mode set to plan.",
        .build => "Mode set to build.",
        .pair => "Mode set to pair.",
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
    var buf: [256]u8 = @splat(0);

    if (iter.next()) |model| {
        try session.set_model(model);
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
            .{session.get_model()},
        );
        try display.write_status_line(stdout, use_color, out);
    }
    return .handled;
}

fn handle_new(
    store: *conversation.ConversationStore,
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
                "Conversation already exists." ++ " Use /switch <name>.",
            );
            return .handled;
        }
        return err;
    };

    var buf: [256]u8 = @splat(0);
    const count = conversation.context_message_count(
        session.messages_slice(),
    );
    const out = try std.fmt.bufPrint(
        &buf,
        "Switched to new conversation:" ++ " {s} (loaded {d} messages)",
        .{ name, count },
    );
    try display.write_status_line(stdout, use_color, out);
    return .handled;
}

fn handle_switch(
    store: *conversation.ConversationStore,
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

    var buf: [256]u8 = @splat(0);
    const count = conversation.context_message_count(
        session.messages_slice(),
    );
    const out = try std.fmt.bufPrint(
        &buf,
        "Switched to conversation:" ++ " {s} (loaded {d} messages)",
        .{ store.active_name(), count },
    );
    try display.write_status_line(stdout, use_color, out);
    return .handled;
}

fn handle_convos(
    store: *conversation.ConversationStore,
    stdout: std.fs.File,
    use_color: bool,
) !Result {
    try display.write_status_line(
        stdout,
        use_color,
        "Conversations:",
    );

    for (store.conversations.items, 0..) |conv, i| {
        var buf: [512]u8 = @splat(0);
        const marker = if (i == store.active_index) "*" else " ";
        const out = try std.fmt.bufPrint(
            &buf,
            " {s} {s} (mode={s}, model={s}, messages={d})",
            .{
                marker,
                conv.name,
                types.mode_label(conv.mode),
                conv.model,
                conv.messages.items.len,
            },
        );
        try display.write_status_line(stdout, use_color, out);
    }
    return .handled;
}

fn handle_init() !Result {
    return .{
        .send_prompt = "Inspect this project (read key files, check " ++
            "the directory structure) and create an " ++
            "AGENTS.md in the repository root. It should " ++
            "document: the project purpose, language and " ++
            "framework conventions, code style notes, " ++
            "testing approach, and directory layout. " ++
            "Be concise and accurate based on what you find.",
    };
}

fn handle_help(
    stdout: std.fs.File,
    use_color: bool,
) !Result {
    const lines = [_][]const u8{
        "Slash commands:",
        "  /plan          - planning mode (no code)",
        "  /build         - build mode (implementation)",
        "  /pair          - pair mode (direction + code)",
        "  /model         - show current OpenRouter model",
        "  /model <id>    - switch OpenRouter model",
        "  /new [name]    - create + switch conversation",
        "  /switch <name> - switch conversation",
        "  /convos        - list conversations",
        "  /init          - create AGENTS.md",
        "  /quit          - leave the REPL",
    };
    for (lines) |l| {
        try display.write_status_line(stdout, use_color, l);
    }
    return .handled;
}
