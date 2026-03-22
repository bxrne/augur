const std = @import("std");
const harness = @import("harness.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const api_key = std.posix.getenv("OPENROUTER_API_KEY") orelse @panic("OPENROUTER_API_KEY is not set");
    const base_url = std.posix.getenv("OPENROUTER_BASE_URL") orelse "https://openrouter.ai/api/v1";

    var session = harness.Harness.init(allocator, api_key, base_url);
    defer session.deinit();

    if (args.len >= 3 and std.mem.eql(u8, args[1], "-p")) {
        const content = try session.send(args[2]);
        try std.fs.File.stdout().writeAll(content);
        return;
    }

    try runRepl(allocator, &session);
}

fn runRepl(allocator: std.mem.Allocator, session: *harness.Harness) !void {
    const stdin = std.fs.File.stdin().deprecatedReader();
    const stdout_file = std.fs.File.stdout();

    while (true) {
        try stdout_file.writeAll("zip> ");
        const line_opt = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024 * 1024);
        if (line_opt == null) {
            break;
        }
        const line = line_opt.?;
        defer allocator.free(line);

        const trimmed = std.mem.trimRight(u8, line, "\r\n");
        if (trimmed.len == 0) {
            continue;
        }
        if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) {
            break;
        }

        const response = try session.send(trimmed);
        try stdout_file.writeAll(response);
        try stdout_file.writeAll("\n");
    }
}
