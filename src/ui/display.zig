/// Terminal output helpers: ANSI colours, prompt rendering,
/// and status-line writing.
const std = @import("std");
const types = @import("../core/types.zig");

pub const Ansi = struct {
    pub const reset = "\x1b[0m";
    pub const prompt = "\x1b[1;36m";
    pub const assistant = "\x1b[1;32m";
    pub const spinner = "\x1b[1;33m";
    pub const status = "\x1b[1;35m";
    pub const label = "\x1b[1;37m";
    pub const border = "\x1b[38;5;244m";
    pub const dim = "\x1b[2m";
    pub const mode_plan = "\x1b[1;34m";
    pub const mode_build = "\x1b[1;32m";
};

/// Write a single coloured status line to stdout.
pub fn write_status_line(
    file: std.fs.File,
    use_color: bool,
    message: []const u8,
) !void {
    std.debug.assert(message.len > 0);

    if (use_color) {
        try file.writeAll(Ansi.status);
    }
    try file.writeAll(message);
    if (use_color) {
        try file.writeAll(Ansi.reset);
    }
    try file.writeAll("\n");
}

/// Print the REPL banner with current session state.
pub fn write_repl_header(
    file: std.fs.File,
    use_color: bool,
    mode: types.Mode,
    model: []const u8,
    active_conversation: []const u8,
    streaming: bool,
) !void {
    try write_header_field(
        file,
        use_color,
        "zip • convo",
        active_conversation,
        null,
    );
    try write_header_field(
        file,
        use_color,
        "mode",
        types.mode_label(mode),
        mode,
    );
    try write_header_field(
        file,
        use_color,
        "model",
        model,
        null,
    );
    try write_header_field(
        file,
        use_color,
        "streaming",
        if (streaming) "on" else "off",
        null,
    );
    try write_header_field(
        file,
        use_color,
        "commands",
        "/help /quit",
        null,
    );
}

fn write_header_field(
    file: std.fs.File,
    use_color: bool,
    label_text: []const u8,
    value: []const u8,
    mode_opt: ?types.Mode,
) !void {
    if (use_color) {
        try file.writeAll(Ansi.border);
    }
    try file.writeAll("│ ");
    if (use_color) {
        try file.writeAll(Ansi.dim);
    }
    try file.writeAll(label_text);
    try file.writeAll(": ");
    if (use_color) {
        try file.writeAll(Ansi.reset);
        if (mode_opt) |mode| {
            try file.writeAll(mode_color(mode));
        } else {
            try file.writeAll(Ansi.label);
        }
    }
    try file.writeAll(value);
    if (use_color) {
        try file.writeAll(Ansi.reset);
    }
    try file.writeAll("\n");
}

/// Return the ANSI colour escape for a given mode.
pub fn mode_color(mode: types.Mode) []const u8 {
    return switch (mode) {
        .plan => Ansi.mode_plan,
        .build => Ansi.mode_build,
    };
}

/// Write the mode-coloured input prompt (e.g. "plan> ").
pub fn write_prompt(
    file: std.fs.File,
    use_color: bool,
    mode: types.Mode,
) !void {
    if (use_color) {
        try file.writeAll(mode_color(mode));
    }
    try file.writeAll(types.mode_label(mode));
    if (use_color) {
        try file.writeAll(Ansi.prompt);
    }
    try file.writeAll("> ");
    if (use_color) {
        try file.writeAll(Ansi.reset);
    }
}

/// Write the assistant response prefix ("> ").
pub fn write_assistant_prefix(
    file: std.fs.File,
    use_color: bool,
) !void {
    if (use_color) {
        try file.writeAll(Ansi.assistant);
    }
    try file.writeAll("> ");
    if (use_color) {
        try file.writeAll(Ansi.reset);
    }
}
