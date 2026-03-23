/// Entry point for the augur CLI assistant.
const std = @import("std");
const cli_args = @import("app/cli_args.zig");
const harness = @import("app/harness.zig");
const repl = @import("app/repl.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const api_key = std.posix.getenv("OPENROUTER_API_KEY") orelse
        @panic("OPENROUTER_API_KEY is not set");
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
        .streaming = options.streaming,
    };

    if (options.prompt) |prompt| {
        try repl.run_prompt(
            &session,
            prompt,
            stdout,
            ropts,
            false,
        );
        return;
    }

    try repl.run(allocator, &session, stdout, ropts);
}
