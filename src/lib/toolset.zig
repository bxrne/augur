/// Built-in tool implementations (read, write, bash, find, grep, tree, diff, git) and their
/// JSON-schema definitions sent to the model. Includes mode-based access control and
/// .env file protection.
const std = @import("std");
const types = @import("types.zig");

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
    .{ "find", &tool_find },
    .{ "grep", &tool_grep },
    .{ "tree", &tool_tree },
    .{ "diff", &tool_diff },
    .{ "git", &tool_git },
});

// Bash command allowlist
const bash_allowlist = &[_][]const u8{
    "cat", "ls", "ping", "curl", "sed", "awk", "jq",
    "zig", "uv", "python", "gcc", "go", "npm", "node", "bun", "pnpm",
    "podman", "docker", "tail",
};

/// Returns true if the tool is allowed in the given mode
fn is_tool_allowed(tool_name: []const u8, mode: types.Mode) bool {
    return switch (mode) {
        .plan => std.mem.eql(u8, tool_name, "read") or
            std.mem.eql(u8, tool_name, "tree"),
        .pair => std.mem.eql(u8, tool_name, "read") or
            std.mem.eql(u8, tool_name, "bash") or
            std.mem.eql(u8, tool_name, "find") or
            std.mem.eql(u8, tool_name, "grep") or
            std.mem.eql(u8, tool_name, "diff"),
        .build => true, // all tools allowed in build mode
    };
}

/// Returns true if a bash command should be allowed (checks allowlist and .env access)
fn is_bash_command_allowed(command: []const u8) bool {
    // Block any .env access patterns
    if (std.mem.indexOf(u8, command, ".env") != null) {
        return false;
    }

    // Extract the first word (the command being run)
    var words = std.mem.splitSequence(u8, command, " ");
    const first_word_opt = words.next();
    if (first_word_opt == null) return false;

    var first_word = first_word_opt.?;

    // Handle pipes and redirects: extract just the command name
    // e.g. "cat file.txt | grep pattern" -> first_word = "cat"
    // "command < file" -> first_word = "command"
    first_word = std.mem.trim(u8, first_word, "|<>&;");

    // Extract basename from paths (e.g. "/usr/bin/python" -> "python")
    if (std.mem.lastIndexOf(u8, first_word, "/")) |slash_idx| {
        first_word = first_word[slash_idx + 1 ..];
    }

    // Check if command is in allowlist
    for (bash_allowlist) |allowed| {
        if (std.mem.eql(u8, first_word, allowed)) {
            return true;
        }
    }

    return false;
}

/// Rejects paths that leave the cwd (absolute or `..`) or access .env files
/// so file tools stay sandboxed to the user's working tree.
fn validate_path(file_path: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, file_path, "/")) return "Refused: absolute paths are not allowed";
    if (std.mem.indexOf(u8, file_path, "..") != null) return "Refused: path traversal is not allowed";
    if (std.mem.eql(u8, file_path, ".env") or std.mem.endsWith(u8, file_path, "/.env")) {
        return "Refused: .env files are protected";
    }
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

/// Dispatch a tool call by name, with mode-based access control.
pub fn call_tool(
    name: []const u8,
    args: []const u8,
    allocator: std.mem.Allocator,
    mode: types.Mode,
) ![]u8 {
    std.debug.assert(name.len > 0);

    // Check if tool is allowed in this mode
    if (!is_tool_allowed(name, mode)) {
        return std.fmt.allocPrint(
            allocator,
            "Tool '{s}' is not available in {s} mode",
            .{ name, types.mode_label(mode) },
        );
    }

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
    required: bool = true,
};

const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    params: []const ParamDef,
};

/// Tool definitions filtered by mode
fn get_tool_defs(mode: types.Mode) []const ToolDef {
    return switch (mode) {
        .plan => &plan_tool_defs,
        .pair => &pair_tool_defs,
        .build => &all_tool_defs,
    };
}

const all_tool_defs = [_]ToolDef{
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
    .{
        .name = "find",
        .description = "Search for files by name or pattern within a directory tree",
        .params = &.{
            .{ .name = "pattern", .type_name = "string", .description = "Filename pattern to search for (glob or exact)" },
            .{ .name = "path", .type_name = "string", .description = "Starting directory (default: current directory)", .required = false },
            .{ .name = "type", .type_name = "string", .description = "Filter by type: 'file', 'dir', or 'any' (default: any)", .required = false },
        },
    },
    .{
        .name = "grep",
        .description = "Search for text patterns within files",
        .params = &.{
            .{ .name = "pattern", .type_name = "string", .description = "Regular expression or literal text to search for" },
            .{ .name = "path", .type_name = "string", .description = "File or directory to search in" },
            .{ .name = "context_lines", .type_name = "integer", .description = "Number of context lines to show (default: 0)", .required = false },
        },
    },
    .{
        .name = "tree",
        .description = "Show directory structure as a tree",
        .params = &.{
            .{ .name = "path", .type_name = "string", .description = "Root directory (default: current directory)", .required = false },
            .{ .name = "depth", .type_name = "integer", .description = "Maximum directory depth to show (default: 3)", .required = false },
            .{ .name = "ignore_patterns", .type_name = "string", .description = "Comma-separated patterns to ignore (default: '.git,node_modules,.zig-cache')", .required = false },
        },
    },
    .{
        .name = "diff",
        .description = "Show differences between two files",
        .params = &.{
            .{ .name = "file1", .type_name = "string", .description = "First file path" },
            .{ .name = "file2", .type_name = "string", .description = "Second file path" },
            .{ .name = "context_lines", .type_name = "integer", .description = "Number of context lines (default: 3)", .required = false },
        },
    },
    .{
        .name = "git",
        .description = "Run git operations (log, status, diff, show)",
        .params = &.{
            .{ .name = "operation", .type_name = "string", .description = "Git operation: 'log', 'status', 'diff', 'show'" },
            .{ .name = "args", .type_name = "string", .description = "Additional arguments for the git command (default: '')", .required = false },
        },
    },
};

const plan_tool_defs = [_]ToolDef{
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
        .name = "tree",
        .description = "Show directory structure as a tree",
        .params = &.{
            .{ .name = "path", .type_name = "string", .description = "Root directory (default: current directory)", .required = false },
            .{ .name = "depth", .type_name = "integer", .description = "Maximum directory depth to show (default: 3)", .required = false },
            .{ .name = "ignore_patterns", .type_name = "string", .description = "Comma-separated patterns to ignore (default: '.git,node_modules,.zig-cache')", .required = false },
        },
    },
};

const pair_tool_defs = [_]ToolDef{
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
        .name = "bash",
        .description = "Run a shell command and return stdout/stderr",
        .params = &.{.{
            .name = "command",
            .type_name = "string",
            .description = "The command to run",
        }},
    },
    .{
        .name = "find",
        .description = "Search for files by name or pattern within a directory tree",
        .params = &.{
            .{ .name = "pattern", .type_name = "string", .description = "Filename pattern to search for (glob or exact)" },
            .{ .name = "path", .type_name = "string", .description = "Starting directory (default: current directory)", .required = false },
            .{ .name = "type", .type_name = "string", .description = "Filter by type: 'file', 'dir', or 'any' (default: any)", .required = false },
        },
    },
    .{
        .name = "grep",
        .description = "Search for text patterns within files",
        .params = &.{
            .{ .name = "pattern", .type_name = "string", .description = "Regular expression or literal text to search for" },
            .{ .name = "path", .type_name = "string", .description = "File or directory to search in" },
            .{ .name = "context_lines", .type_name = "integer", .description = "Number of context lines to show (default: 0)", .required = false },
        },
    },
    .{
        .name = "diff",
        .description = "Show differences between two files",
        .params = &.{
            .{ .name = "file1", .type_name = "string", .description = "First file path" },
            .{ .name = "file2", .type_name = "string", .description = "Second file path" },
            .{ .name = "context_lines", .type_name = "integer", .description = "Number of context lines (default: 3)", .required = false },
        },
    },
};

/// Serializes tool schemas into the request payload shape the provider expects
/// (`tools` array of function definitions); without this the model cannot call tools.
pub fn write_tool_definitions(jw: *std.json.Stringify, mode: types.Mode) !void {
    const defs = get_tool_defs(mode);
    for (defs) |def| {
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
        for (def.params) |p| {
            if (p.required) try jw.write(p.name);
        }
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

    // Check if command is allowed
    if (!is_bash_command_allowed(command)) {
        return allocator.dupe(u8, "Refused: bash command is not allowed (contains .env access or uses disallowed command)");
    }

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

fn tool_find(allocator: std.mem.Allocator, args: []const u8) anyerror![]u8 {
    const Args = struct {
        pattern: []const u8,
        path: ?[]const u8 = null,
        @"type": ?[]const u8 = null,
    };

    const parsed = try std.json.parseFromSlice(Args, allocator, args, .{});
    defer parsed.deinit();

    const pattern = parsed.value.pattern;
    const path = parsed.value.path orelse ".";
    const file_type = parsed.value.@"type" orelse "any";

    if (validate_path(path)) |refusal| return allocator.dupe(u8, refusal);

    log_tool_call("find", "pattern", pattern);

    // Build the find command
    var cmd = std.ArrayList(u8).empty;
    defer cmd.deinit(allocator);

    try cmd.writer(allocator).print("find {s} -name '{s}'", .{ path, pattern });

    // Add type filter if specified
    if (!std.mem.eql(u8, file_type, "any")) {
        if (std.mem.eql(u8, file_type, "file")) {
            try cmd.writer(allocator).print(" -type f", .{});
        } else if (std.mem.eql(u8, file_type, "dir")) {
            try cmd.writer(allocator).print(" -type d", .{});
        }
    }

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "bash", "-lc", cmd.items },
        .max_output_bytes = max_tool_output_bytes,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return format_bash_output(allocator, result);
}

fn tool_grep(allocator: std.mem.Allocator, args: []const u8) anyerror![]u8 {
    const Args = struct {
        pattern: []const u8,
        path: []const u8,
        context_lines: ?i32 = null,
    };

    const parsed = try std.json.parseFromSlice(Args, allocator, args, .{});
    defer parsed.deinit();

    const pattern = parsed.value.pattern;
    const path = parsed.value.path;
    const context = parsed.value.context_lines orelse 0;

    if (validate_path(path)) |refusal| return allocator.dupe(u8, refusal);

    log_tool_call("grep", "pattern", pattern);

    // Build grep command
    var cmd = std.ArrayList(u8).empty;
    defer cmd.deinit(allocator);

    if (context > 0) {
        try cmd.writer(allocator).print("grep -r -n -C {d} '{s}' {s} 2>/dev/null || true", .{ context, pattern, path });
    } else {
        try cmd.writer(allocator).print("grep -r -n '{s}' {s} 2>/dev/null || true", .{ pattern, path });
    }

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "bash", "-lc", cmd.items },
        .max_output_bytes = max_tool_output_bytes,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return format_bash_output(allocator, result);
}

fn tool_tree(allocator: std.mem.Allocator, args: []const u8) anyerror![]u8 {
    const Args = struct {
        path: ?[]const u8 = null,
        depth: ?i32 = null,
        ignore_patterns: ?[]const u8 = null,
    };

    const parsed = try std.json.parseFromSlice(Args, allocator, args, .{});
    defer parsed.deinit();

    const path = parsed.value.path orelse ".";
    const depth = parsed.value.depth orelse 3;
    const ignore = parsed.value.ignore_patterns orelse ".git,node_modules,.zig-cache";

    if (validate_path(path)) |refusal| return allocator.dupe(u8, refusal);

    log_tool_call("tree", "path", path);

    // Build tree command using find (tree might not be installed)
    var cmd = std.ArrayList(u8).empty;
    defer cmd.deinit(allocator);

    try cmd.writer(allocator).print("find {s} -maxdepth {d}", .{ path, depth });

    // Add ignore patterns
    var ignore_iter = std.mem.splitSequence(u8, ignore, ",");
    while (ignore_iter.next()) |pattern| {
        const trimmed = std.mem.trim(u8, pattern, " ");
        if (trimmed.len > 0) {
            try cmd.writer(allocator).print(" -not -path '*/{s}/*' -not -path '*/{s}'", .{ trimmed, trimmed });
        }
    }

    try cmd.writer(allocator).print(" | sort", .{});

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "bash", "-lc", cmd.items },
        .max_output_bytes = max_tool_output_bytes,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return format_bash_output(allocator, result);
}

fn tool_diff(allocator: std.mem.Allocator, args: []const u8) anyerror![]u8 {
    const Args = struct {
        file1: []const u8,
        file2: []const u8,
        context_lines: ?i32 = null,
    };

    const parsed = try std.json.parseFromSlice(Args, allocator, args, .{});
    defer parsed.deinit();

    const file1 = parsed.value.file1;
    const file2 = parsed.value.file2;
    const context = parsed.value.context_lines orelse 3;

    if (validate_path(file1)) |refusal| return allocator.dupe(u8, refusal);
    if (validate_path(file2)) |refusal| return allocator.dupe(u8, refusal);

    log_tool_call("diff", "files", file1);

    var cmd = std.ArrayList(u8).empty;
    defer cmd.deinit(allocator);

    try cmd.writer(allocator).print("diff -u -U {d} '{s}' '{s}' 2>/dev/null || true", .{ context, file1, file2 });

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "bash", "-lc", cmd.items },
        .max_output_bytes = max_tool_output_bytes,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return format_bash_output(allocator, result);
}

fn tool_git(allocator: std.mem.Allocator, args: []const u8) anyerror![]u8 {
    const Args = struct {
        operation: []const u8,
        args: ?[]const u8 = null,
    };

    const parsed = try std.json.parseFromSlice(Args, allocator, args, .{});
    defer parsed.deinit();

    const operation = parsed.value.operation;
    const git_args = parsed.value.args orelse "";

    // Validate operation is one of the allowed ones
    if (!std.mem.eql(u8, operation, "log") and
        !std.mem.eql(u8, operation, "status") and
        !std.mem.eql(u8, operation, "diff") and
        !std.mem.eql(u8, operation, "show"))
    {
        return std.fmt.allocPrint(allocator, "Unsupported git operation '{s}'. Allowed: log, status, diff, show", .{operation});
    }

    log_tool_call("git", "operation", operation);

    var cmd = std.ArrayList(u8).empty;
    defer cmd.deinit(allocator);

    try cmd.writer(allocator).print("git {s} {s} 2>&1 || echo 'git command failed'", .{ operation, git_args });

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "bash", "-lc", cmd.items },
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

    if (exit_code != 0 and output.items.len == 0) {
        try output.writer(allocator).print("exit code: {d}", .{exit_code});
    }

    return output.toOwnedSlice(allocator);
}
