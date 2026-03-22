const std = @import("std");

pub const tools = std.StaticStringMap(*const fn ([]const u8, std.mem.Allocator) void).initComptime(.{
    .{ "read", &read },
});

fn read(args: []const u8, allocator: std.mem.Allocator) void {
    const parsed = std.json.parseFromSlice(
        struct { file_path: []const u8 },
        allocator,
        args,
        .{},
    ) catch |err| {
        std.debug.print("Failed to parse arguments: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    const file_path = parsed.value.file_path;

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("Failed to open '{s}': {}\n", .{ file_path, err });
        return;
    };
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch |err| {
        std.debug.print("Failed to read '{s}': {}\n", .{ file_path, err });
        return;
    };
    defer allocator.free(contents);

    const stdout = std.fs.File.stdout();
    stdout.writeAll(contents) catch {};
}
