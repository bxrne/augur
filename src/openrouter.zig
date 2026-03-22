const std = @import("std");
const types = @import("types.zig");
const toolset = @import("toolset.zig");

pub fn fetchCompletion(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    api_key: []const u8,
    base_url: []const u8,
) ![]u8 {
    var body_out: std.io.Writer.Allocating = .init(allocator);
    defer body_out.deinit();

    var jw: std.json.Stringify = .{ .writer = &body_out.writer };
    try jw.write(.{
        .model = "anthropic/claude-haiku-4.5",
        .messages = &[_]types.Message{
            .{ .role = "user", .content = prompt },
        },
        .tools = &[_]types.Tool{types.Tool{
            .type = "function",
            .function = .{
                .name = "Read",
                .description = "Read and return the contents of a file",
                .parameters = .{
                    .type = "object",
                    .properties = .{
                        .file_path = .{
                            .type = "string",
                            .description = "The path to the file to read",
                        },
                    },
                    .required = &.{"file_path"},
                },
            },
        }},
    });
    const body = body_out.written();

    const url_str = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{base_url});
    defer allocator.free(url_str);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_out: std.io.Writer.Allocating = .init(allocator);
    defer response_out.deinit();

    _ = try client.fetch(.{
        .location = .{ .url = url_str },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth_value },
        },
        .response_writer = &response_out.writer,
    });

    const response_body = response_out.written();
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
    defer parsed.deinit();

    const choices = parsed.value.object.get("choices") orelse @panic("No choices in response");
    if (choices.array.items.len == 0) {
        @panic("No choices in response");
    }

    const message = choices.array.items[0].object.get("message").?;
    if (message.object.get("tool_calls")) |tool_calls| {
        for (tool_calls.array.items) |tool_call| {
            const tool = tool_call.object.get("function").?.object.get("name").?.string;
            const arguments = tool_call.object.get("function").?.object.get("arguments").?.string;
            call_tool(tool, arguments, allocator);
        }
    } else if (message.object.get("content")) |content| {
        try std.fs.File.stdout().writeAll(content.string);
    }
}

fn call_tool(tool: []const u8, args: []const u8, allocator: std.mem.Allocator) void {
    if (toolset.tools.get(tool)) |func| {
        func(args, allocator);
    } else std.debug.print("{s}: tool not found\n", .{tool});
}
