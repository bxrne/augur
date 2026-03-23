/// Command-line argument parsing for the augur CLI.
const std = @import("std");
const limits = @import("../core/limits.zig");

pub const CliOptions = struct {
    prompts: [limits.max_args][]const u8 = undefined,
    prompt_count: u32 = 0,
    streaming: bool = true,

    pub fn has_prompts(self: *const CliOptions) bool {
        return self.prompt_count > 0;
    }

    pub fn prompt_slice(
        self: *const CliOptions,
    ) []const []const u8 {
        const count: usize = @intCast(self.prompt_count);
        return self.prompts[0..count];
    }
};

/// Parse command-line arguments into `CliOptions`.
///
/// Accepts repeated `-p <prompt>` (queued in order), `--stream`,
/// and `--no-stream`. Returns `error.MissingPrompt` when `-p`
/// has no following argument, and `error.TooManyArgs` when `args`
/// exceeds the safety limit.
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

            if (options.prompt_count >= limits.max_args) {
                return error.TooManyPrompts;
            }

            const next: usize = @intCast(options.prompt_count);
            options.prompts[next] = std.mem.sliceTo(args[idx], 0);
            options.prompt_count += 1;
        } else if (std.mem.eql(u8, arg, "--stream")) {
            options.streaming = true;
        } else if (std.mem.eql(u8, arg, "--no-stream")) {
            options.streaming = false;
        }
    }

    return options;
}
