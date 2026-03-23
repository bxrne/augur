/// CLI entry: parse args, wire OpenRouter credentials into `Harness`, then
/// either run queued `-p` prompts or the interactive REPL.
const std = @import("std");
const cli_args = @import("cli/args.zig");
const harness = @import("lib/harness.zig");
const repl = @import("cli/repl.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const api_key = std.posix.getenv("OPENROUTER_API_KEY") orelse {
        std.debug.print("Error: OPENROUTER_API_KEY environment variable is not set\n", .{});
        return error.MissingApiKey;
    };
    const base_url = std.posix.getenv("OPENROUTER_BASE_URL") orelse
        "https://openrouter.ai/api/v1";

    var session = try harness.Harness.init(
        allocator,
        api_key,
        base_url,
    );
    defer session.deinit();

    const options = try cli_args.parse(args);
    const stdout = std.fs.File.stdout();
    const is_tty = stdout.isTty();

    const ropts = repl.ReplOptions{
        .is_tty = is_tty,
        .use_color = is_tty,
    };

    if (options.has_prompts()) {
        const prompts = options.prompt_slice();
        const show_prefix = prompts.len > 1;

        for (prompts) |prompt| {
            try repl.run_prompt(
                &session,
                prompt,
                stdout,
                ropts,
                show_prefix,
            );
        }
        return;
    }

    try repl.run(allocator, &session, stdout, ropts);
}
