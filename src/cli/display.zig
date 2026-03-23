/// Terminal colouring for CLI output: centralises escapes so prompts, status
/// lines, and streamed assistant text stay visually distinct without scattering
/// literals through call sites.
const std = @import("std");
const types = @import("../lib/types.zig");

/// Namespace for escape sequences so reads like `display.ansi.dim` stay obvious
/// at the call site without importing a separate ANSI module.
pub const ansi = struct {
    pub const reset = "\x1b[0m";
    pub const prompt = "\x1b[1;36m";
    pub const assistant = "\x1b[1;32m";
    pub const spinner = "\x1b[1;33m";
    pub const status = "\x1b[1;35m";
    pub const label = "\x1b[1;37m";
    pub const border = "\x1b[38;5;244m";
    pub const dim = "\x1b[2m";
    pub const mode_plan = "\x1b[1;38;5;75m";
    pub const mode_build = "\x1b[1;38;5;42m";
    pub const mode_pair = "\x1b[1;38;5;208m";
};

fn write_colored(
    file: std.fs.File,
    text: []const u8,
    color: []const u8,
    use_color: bool,
    do_reset: bool,
) !void {
    if (use_color) {
        try file.writeAll(color);
    }
    try file.writeAll(text);
    if (use_color and do_reset) {
        try file.writeAll(ansi.reset);
    }
}

/// Write a single coloured status line to stdout.
pub fn write_status_line(
    file: std.fs.File,
    use_color: bool,
    message: []const u8,
) !void {
    std.debug.assert(message.len > 0);
    try write_colored(file, message, ansi.status, use_color, true);
    try file.writeAll("\n");
}

/// Return the ANSI colour escape for a given mode.
pub fn mode_color(mode: types.Mode) []const u8 {
    return switch (mode) {
        .plan => ansi.mode_plan,
        .build => ansi.mode_build,
        .pair => ansi.mode_pair,
    };
}

/// Write the mode-coloured input prompt (e.g. "plan> ").
pub fn write_prompt(
    file: std.fs.File,
    use_color: bool,
    mode: types.Mode,
) !void {
    try write_colored(file, types.mode_label(mode), mode_color(mode), use_color, false);
    try write_colored(file, "> ", ansi.prompt, use_color, false);
}

/// Write the assistant response prefix as "model> ", resetting colour
/// so the streamed response text appears in the default terminal colour.
pub fn write_assistant_prefix(
    file: std.fs.File,
    use_color: bool,
    model: []const u8,
) !void {
    try write_colored(file, model, ansi.assistant, use_color, false);
    try write_colored(file, "> ", ansi.prompt, use_color, true);
}
