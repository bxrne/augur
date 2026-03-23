/// Built-in tool implementations (read, write, bash) and their
/// JSON-schema definitions sent to the model.
const std = @import("std");
const limits = @import("../core/limits.zig");

const Ansi = struct {
    const dim = "\x1b[2m";
    const reset = "\x1b[0m";
};

pub const ToolFn = *const fn (
    std.mem.Allocator,
    []const u8,
) anyerror![]u8;

pub const tools = std.StaticStringMap(ToolFn).initComptime(.{
    .{ "read", &tool_read },
    .{ "write", &tool_write },
    .{ "bash", &tool_bash },
});

/// Log a tool invocation to stderr.
fn log_tool_call(
    name: []const u8,
    label: []const u8,
    value: []const u8,
) void {
    var file = std.fs.File.stderr();
    const use_color = file.isTty();
    var w = file.writer(&.{});
    const iface = &w.interface;

    if (use_color) iface.writeAll(Ansi.dim) catch return;
    iface.print(
        "tool call: {s} {s}={s}",
        .{ name, label, value },
    ) catch return;
    if (use_color) iface.writeAll(Ansi.reset) catch return;
    iface.writeAll("\n") catch return;
    iface.flush() catch return;
}

/// Dispatch a tool call by name.
pub fn call_tool(
    name: []const u8,
    args: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    std.debug.assert(name.len > 0);

    const func = tools.get(name) orelse {
        return std.fmt.allocPrint(
            allocator,
            "Tool '{s}' not found",
            .{name},
        );
    };

    return func(allocator, args) catch |err| {
        return std.fmt.allocPrint(
            allocator,
            "Tool '{s}' failed: {}",
            .{ name, err },
        );
    };
}

/// Emit all tool JSON-schema definitions into a JSON array.
pub fn write_tool_definitions(
    jw: *std.json.Stringify,
) !void {
    try write_read_definition(jw);
    try write_write_definition(jw);
    try write_bash_definition(jw);
}

fn write_read_definition(jw: *std.json.Stringify) !void {
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
    try write_params_object(jw, &.{"file_path"}, &.{.{
        .name = "file_path",
        .type_name = "string",
        .description = "The path to the file to read",
    }});
    try jw.endObject();
    try jw.endObject();
}

fn write_write_definition(jw: *std.json.Stringify) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("function");
    try jw.objectField("function");
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write("write");
    try jw.objectField("description");
    try jw.write(
        "Write contents to a file, overwriting if it exists",
    );
    try jw.objectField("parameters");
    try write_params_object(jw, &.{ "file_path", "content" }, &.{
        .{
            .name = "file_path",
            .type_name = "string",
            .description = "The path to the file to write",
        },
        .{
            .name = "content",
            .type_name = "string",
            .description = "The content to write to the file",
        },
    });
    try jw.endObject();
    try jw.endObject();
}

fn write_bash_definition(jw: *std.json.Stringify) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("function");
    try jw.objectField("function");
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write("bash");
    try jw.objectField("description");
    try jw.write(
        "Run a shell command and return stdout/stderr",
    );
    try jw.objectField("parameters");
    try write_params_object(jw, &.{"command"}, &.{.{
        .name = "command",
        .type_name = "string",
        .description = "The command to run",
    }});
    try jw.endObject();
    try jw.endObject();
}

const ParamDef = struct {
    name: []const u8,
    type_name: []const u8,
    description: []const u8,
};

/// Helper: emit a JSON-schema "parameters" object with
/// properties and required array.
fn write_params_object(
    jw: *std.json.Stringify,
    required: []const []const u8,
    params: []const ParamDef,
) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("object");
    try jw.objectField("properties");
    try jw.beginObject();
    for (params) |p| {
        try jw.objectField(p.name);
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(p.type_name);
        try jw.objectField("description");
        try jw.write(p.description);
        try jw.endObject();
    }
    try jw.endObject();
    try jw.objectField("required");
    try jw.beginArray();
    for (required) |r| {
        try jw.write(r);
    }
    try jw.endArray();
    try jw.endObject();
}

fn tool_read(
    allocator: std.mem.Allocator,
    args: []const u8,
) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(
        struct { file_path: []const u8 },
        allocator,
        args,
        .{},
    );
    defer parsed.deinit();

    const file_path = parsed.value.file_path;
    std.debug.assert(file_path.len > 0);
    log_tool_call("read", "file", file_path);

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    return file.readToEndAlloc(
        allocator,
        limits.max_read_file_bytes,
    );
}

fn tool_write(
    allocator: std.mem.Allocator,
    args: []const u8,
) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(
        struct { file_path: []const u8, content: []const u8 },
        allocator,
        args,
        .{},
    );
    defer parsed.deinit();

    const file_path = parsed.value.file_path;
    const contents = parsed.value.content;
    std.debug.assert(file_path.len > 0);
    log_tool_call("write", "file", file_path);

    const file = try std.fs.cwd().createFile(
        file_path,
        .{ .truncate = true },
    );
    defer file.close();

    try file.writeAll(contents);
    return allocator.dupe(u8, "OK");
}

fn tool_bash(
    allocator: std.mem.Allocator,
    args: []const u8,
) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(
        struct { command: []const u8 },
        allocator,
        args,
        .{},
    );
    defer parsed.deinit();

    const command = parsed.value.command;
    std.debug.assert(command.len > 0);
    log_tool_call("bash", "command", command);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "bash", "-lc", command },
        .max_output_bytes = limits.max_tool_output_bytes,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return format_bash_output(allocator, result);
}

fn format_bash_output(
    allocator: std.mem.Allocator,
    result: std.process.Child.RunResult,
) ![]u8 {
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
        try output.writer(allocator).print(
            "exit code: {d}",
            .{exit_code},
        );
    }

    return output.toOwnedSlice(allocator);
}
