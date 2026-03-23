/// Command-line argument parsing for the augur CLI.
const std = @import("std");
const limits = @import("../core/limits.zig");

pub const CliOptions = struct {
    prompt: ?[]const u8 = null,
    streaming: bool = true,
};

/// Parse command-line arguments into `CliOptions`.
///
/// Accepts `-p <prompt>`, `--stream`, and `--no-stream`.
/// Returns `error.MissingPrompt` when `-p` has no following
/// argument, and `error.TooManyArgs` when `args` exceeds the
/// safety limit.
pub fn parse(args: []const [:0]u8) !CliOptions {
    std.debug.assert(args.len > 0);
    if (args.len > limits.max_args) {
        return error.TooManyArgs;
    }

    var options = CliOptions{};
    var idx: usize = 1;

    while (idx < args.len) : (idx += 1) {
        const arg = std.mem.sliceTo(args[idx], 0);

        if (std.mem.eql(u8, arg, "-p")) {
            if (idx + 1 >= args.len) return error.MissingPrompt;
            idx += 1;
            options.prompt = std.mem.sliceTo(args[idx], 0);
        } else if (std.mem.eql(u8, arg, "--stream")) {
            options.streaming = true;
        } else if (std.mem.eql(u8, arg, "--no-stream")) {
            options.streaming = false;
        }
    }

    return options;
}
