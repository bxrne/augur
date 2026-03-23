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

/// Write the compact status bar shown above each prompt.
pub fn write_status_bar(
    file: std.fs.File,
    use_color: bool,
    active_conversation: []const u8,
    streaming: bool,
) !void {
    if (use_color) {
        try file.writeAll(Ansi.border);
    }
    try file.writeAll("[");
    if (use_color) {
        try file.writeAll(Ansi.label);
    }
    try file.writeAll(active_conversation);
    if (use_color) {
        try file.writeAll(Ansi.border);
    }
    try file.writeAll("] streaming=");
    if (use_color) {
        try file.writeAll(Ansi.label);
    }
    try file.writeAll(if (streaming) "on" else "off");
    if (use_color) {
        try file.writeAll(Ansi.border);
    }
    try file.writeAll(" /help /quit");
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

/// Write the assistant response prefix as "model@mode> ".
pub fn write_assistant_prefix(
    file: std.fs.File,
    use_color: bool,
    model: []const u8,
    mode: types.Mode,
) !void {
    if (use_color) {
        try file.writeAll(Ansi.assistant);
    }
    try file.writeAll(model);
    try file.writeAll("@");
    try file.writeAll(types.mode_label(mode));
    if (use_color) {
        try file.writeAll(Ansi.prompt);
    }
    try file.writeAll("> ");
    if (use_color) {
        try file.writeAll(Ansi.reset);
    }
}
