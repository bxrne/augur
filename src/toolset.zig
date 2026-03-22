const std = @import("std");

pub const ToolFn = *const fn (std.mem.Allocator, []const u8) anyerror![]u8;

pub const tools = std.StaticStringMap(ToolFn).initComptime(.{
    .{ "read", &read },
    .{ "write", &write },
    .{ "bash", &bash },
});

pub fn callTool(name: []const u8, args: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (tools.get(name)) |func| {
        return func(allocator, args) catch |err| {
            return std.fmt.allocPrint(allocator, "Tool '{s}' failed: {}", .{ name, err });
        };
    }
    return std.fmt.allocPrint(allocator, "Tool '{s}' not found", .{name});
}

pub fn writeToolDefinitions(jw: *std.json.Stringify) !void {
    try writeReadDefinition(jw);
    try writeWriteDefinition(jw);
    try writeBashDefinition(jw);
}

fn writeReadDefinition(jw: *std.json.Stringify) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("function");
    try jw.objectField("function");
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write("read");
    try jw.objectField("description");
    try jw.write("Read and return the contents of a file");
    try jw.objectField("parameters");
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("object");
    try jw.objectField("properties");
    try jw.beginObject();
    try jw.objectField("file_path");
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("string");
    try jw.objectField("description");
    try jw.write("The path to the file to read");
    try jw.endObject();
    try jw.endObject();
    try jw.objectField("required");
    try jw.beginArray();
    try jw.write("file_path");
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
    try jw.endObject();
}

fn writeWriteDefinition(jw: *std.json.Stringify) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("function");
    try jw.objectField("function");
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write("write");
    try jw.objectField("description");
    try jw.write("Write contents to a file, overwriting if it exists");
    try jw.objectField("parameters");
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("object");
    try jw.objectField("properties");
    try jw.beginObject();
    try jw.objectField("file_path");
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("string");
    try jw.objectField("description");
    try jw.write("The path to the file to write");
    try jw.endObject();
    try jw.objectField("content");
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("string");
    try jw.objectField("description");
    try jw.write("The content to write to the file");
    try jw.endObject();
    try jw.endObject();
    try jw.objectField("required");
    try jw.beginArray();
    try jw.write("file_path");
    try jw.write("content");
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
    try jw.endObject();
}

fn writeBashDefinition(jw: *std.json.Stringify) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("function");
    try jw.objectField("function");
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write("bash");
    try jw.objectField("description");
    try jw.write("Run a shell command and return stdout/stderr");
    try jw.objectField("parameters");
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("object");
    try jw.objectField("properties");
    try jw.beginObject();
    try jw.objectField("command");
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("string");
    try jw.objectField("description");
    try jw.write("The command to run");
    try jw.endObject();
    try jw.endObject();
    try jw.objectField("required");
    try jw.beginArray();
    try jw.write("command");
    try jw.endArray();
    try jw.endObject();
    try jw.endObject();
    try jw.endObject();
}

fn read(allocator: std.mem.Allocator, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(
        struct { file_path: []const u8 },
        allocator,
        args,
        .{},
    );
    defer parsed.deinit();

    const file_path = parsed.value.file_path;

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    return file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

fn write(allocator: std.mem.Allocator, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(
        struct { file_path: []const u8, content: []const u8 },
        allocator,
        args,
        .{},
    );
    defer parsed.deinit();

    const file_path = parsed.value.file_path;
    const contents = parsed.value.content;

    const file = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(contents);

    return allocator.dupe(u8, "OK");
}

fn bash(allocator: std.mem.Allocator, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(
        struct { command: []const u8 },
        allocator,
        args,
        .{},
    );
    defer parsed.deinit();

    const command = parsed.value.command;
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "bash", "-lc", command },
        .max_output_bytes = 200 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    if (result.stdout.len > 0) {
        try output.appendSlice(allocator, result.stdout);
    }

    if (result.stderr.len > 0) {
        if (output.items.len > 0) {
            try output.appendSlice(allocator, "\n");
        }
        try output.appendSlice(allocator, result.stderr);
    }

    const exit_code: u8 = switch (result.term) {
        .Exited => |code| code,
        .Signal, .Stopped, .Unknown => 1,
    };

    if (exit_code != 0) {
        if (output.items.len > 0) {
            try output.appendSlice(allocator, "\n");
        }
        try output.writer(allocator).print("exit code: {d}", .{exit_code});
    }

    return output.toOwnedSlice(allocator);
}
