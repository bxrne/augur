/// Built-in tool implementations (read, write, bash) and their
/// JSON-schema definitions sent to the model.
const std = @import("std");

const max_tool_output_bytes: u32 = 200 * 1024;
const max_read_file_bytes: u32 = 10 * 1024 * 1024;

const dim = "\x1b[2m";
const reset = "\x1b[0m";

const ToolFn = *const fn (
    std.mem.Allocator,
    []const u8,
) anyerror![]u8;

const tools = std.StaticStringMap(ToolFn).initComptime(.{
    .{ "read", &tool_read },
    .{ "write", &tool_write },
    .{ "bash", &tool_bash },
});

/// Rejects paths that leave the cwd (absolute or `..`) so file tools stay sandboxed
/// to the user's working tree.
fn validate_path(file_path: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, file_path, "/")) return "Refused: absolute paths are not allowed";
    if (std.mem.indexOf(u8, file_path, "..") != null) return "Refused: path traversal is not allowed";
    return null;
}

/// Writes a dim, one-line status to stderr so tool activity is visible while the
/// assistant stream is still printing to stdout.
fn log_tool_call(name: []const u8, label: []const u8, value: []const u8) void {
    var file = std.fs.File.stderr();
    const use_color = file.isTty();
    var w = file.writer(&.{});
    const iface = &w.interface;
    if (use_color) iface.writeAll(dim) catch return;
    iface.print(" ({s} {s}={s}) ", .{ name, label, value }) catch return;
    if (use_color) iface.writeAll(reset) catch return;
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
        return std.fmt.allocPrint(allocator, "Tool '{s}' not found", .{name});
    };

    return func(allocator, args) catch |err| {
        return std.fmt.allocPrint(allocator, "Tool '{s}' failed: {}", .{ name, err });
    };
}

const ParamDef = struct {
    name: []const u8,
    type_name: []const u8,
    description: []const u8,
};

const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    params: []const ParamDef,
};

const tool_defs = [_]ToolDef{
    .{
        .name = "read",
        .description = "Read and return the contents of a file",
        .params = &.{.{
            .name = "file_path",
            .type_name = "string",
            .description = "The path to the file to read",
        }},
    },
    .{
        .name = "write",
        .description = "Write contents to a file, overwriting if it exists",
        .params = &.{
            .{ .name = "file_path", .type_name = "string", .description = "The path to the file to write" },
            .{ .name = "content", .type_name = "string", .description = "The content to write to the file" },
        },
    },
    .{
        .name = "bash",
        .description = "Run a shell command and return stdout/stderr",
        .params = &.{.{
            .name = "command",
            .type_name = "string",
            .description = "The command to run",
        }},
    },
};

/// Serializes tool schemas into the request payload shape the provider expects
/// (`tools` array of function definitions); without this the model cannot call tools.
pub fn write_tool_definitions(jw: *std.json.Stringify) !void {
    for (tool_defs) |def| {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("function");
        try jw.objectField("function");
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(def.name);
        try jw.objectField("description");
        try jw.write(def.description);
        try jw.objectField("parameters");
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("object");
        try jw.objectField("properties");
        try jw.beginObject();
        for (def.params) |p| {
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
        for (def.params) |p| try jw.write(p.name);
        try jw.endArray();
        try jw.endObject();
        try jw.endObject();
        try jw.endObject();
    }
}

fn tool_read(allocator: std.mem.Allocator, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(
        struct { file_path: []const u8 },
        allocator, args, .{},
    );
    defer parsed.deinit();

    const file_path = parsed.value.file_path;
    if (validate_path(file_path)) |refusal| return allocator.dupe(u8, refusal);
    std.debug.assert(file_path.len > 0);
    log_tool_call("read", "file", file_path);

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_read_file_bytes);
}

fn tool_write(allocator: std.mem.Allocator, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(
        struct { file_path: []const u8, content: []const u8 },
        allocator, args, .{},
    );
    defer parsed.deinit();

    const file_path = parsed.value.file_path;
    if (validate_path(file_path)) |refusal| return allocator.dupe(u8, refusal);
    const contents = parsed.value.content;
    std.debug.assert(file_path.len > 0);
    log_tool_call("write", "file", file_path);

    const file = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
    return allocator.dupe(u8, "OK");
}

fn tool_bash(allocator: std.mem.Allocator, args: []const u8) anyerror![]u8 {
    const parsed = try std.json.parseFromSlice(
        struct { command: []const u8 },
        allocator, args, .{},
    );
    defer parsed.deinit();

    const command = parsed.value.command;
    std.debug.assert(command.len > 0);
    log_tool_call("bash", "command", command);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "bash", "-lc", command },
        .max_output_bytes = max_tool_output_bytes,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return format_bash_output(allocator, result);
}

/// Concatenates stdout and stderr for the model; appends exit code only on failure
/// so success stays clean while errors still carry diagnostics.
fn format_bash_output(allocator: std.mem.Allocator, result: std.process.Child.RunResult) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    if (result.stdout.len > 0) try output.appendSlice(allocator, result.stdout);
    if (result.stderr.len > 0) {
        if (output.items.len > 0) try output.appendSlice(allocator, "\n");
        try output.appendSlice(allocator, result.stderr);
    }

    const exit_code: u8 = switch (result.term) {
        .Exited => |code| code,
        .Signal, .Stopped, .Unknown => 1,
    };

    if (exit_code != 0) {
        if (output.items.len > 0) try output.appendSlice(allocator, "\n");
        try output.writer(allocator).print("exit code: {d}", .{exit_code});
    }

    return output.toOwnedSlice(allocator);
}
