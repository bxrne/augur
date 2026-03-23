/// Command-line argument parsing for the augur CLI.
const std = @import("std");

/// Caps argv length and per-flag repetition so parsing stays bounded even if the
/// shell forwards an enormous argument list.
const max_args: u32 = 64;

/// CLI configuration options.
pub const CliOptions = struct {
    /// Array of prompt strings from `-p` arguments.
    prompts: [max_args][]const u8 = undefined,
    /// Number of prompts actually provided.
    prompt_count: u32 = 0,

    /// Returns true if any prompts were provided.
    pub fn has_prompts(self: *const CliOptions) bool {
        return self.prompt_count > 0;
    }

    /// Returns a slice containing only the provided prompts.
    pub fn prompt_slice(
        self: *const CliOptions,
    ) []const []const u8 {
        const count: usize = @intCast(self.prompt_count);
        return self.prompts[0..count];
    }
};

/// Parse command-line arguments into `CliOptions`.
///
/// Supported flags:
/// - `-p <text>`: Add a prompt to process (can be repeated)
pub fn parse(args: []const [:0]u8) !CliOptions {
    std.debug.assert(args.len > 0);
    if (args.len > max_args) {
        return error.TooManyArguments;
    }

    var options = CliOptions{};
    var idx: usize = 1;

    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];

        if (std.mem.eql(u8, arg, "-p")) {
            if (idx + 1 >= args.len) return error.MissingArgument;
            idx += 1;

            if (options.prompt_count >= max_args) {
                return error.TooManyArguments;
            }

            const next: usize = @intCast(options.prompt_count);
            options.prompts[next] = args[idx];
            options.prompt_count += 1;
        }
    }

    return options;
}
