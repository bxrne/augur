const std = @import("std");
const types = @import("types.zig");
const toolset = @import("toolset.zig");

pub fn fetchMessage(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    api_key: []const u8,
    base_url: []const u8,
) !types.Message {
    var body_out: std.io.Writer.Allocating = .init(allocator);
    defer body_out.deinit();

    var jw: std.json.Stringify = .{
        .writer = &body_out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };

    try jw.beginObject();
    try jw.objectField("model");
    try jw.write("anthropic/claude-haiku-4.5");

    try jw.objectField("messages");
    try jw.beginArray();
    for (messages) |message| {
        try jw.write(message);
    }
    try jw.endArray();

    try jw.objectField("tools");
    try jw.beginArray();
    try toolset.writeToolDefinitions(&jw);
    try jw.endArray();

    try jw.endObject();
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

    if (parsed.value.object.get("error")) |err_value| {
        if (err_value.object.get("message")) |message_value| {
            if (message_value == .string) {
                std.debug.print("OpenRouter error: {s}\n", .{message_value.string});
            }
        } else {
            std.debug.print("OpenRouter error response: {s}\n", .{response_body});
        }
        return error.ApiError;
    }

    const choices = parsed.value.object.get("choices") orelse {
        std.debug.print("Unexpected response: {s}\n", .{response_body});
        return error.MissingChoices;
    };
    if (choices.array.items.len == 0) {
        std.debug.print("Unexpected response: {s}\n", .{response_body});
        return error.MissingChoices;
    }

    const message_value = choices.array.items[0].object.get("message").?;
    var message = types.Message{
        .role = "assistant",
        .content = "",
    };

    if (message_value.object.get("content")) |content| {
        switch (content) {
            .string => |text| message.content = try allocator.dupe(u8, text),
            else => {},
        }
    }

    if (message_value.object.get("tool_calls")) |tool_calls_value| {
        switch (tool_calls_value) {
            .array => |tool_calls| {
                const calls = try allocator.alloc(types.ToolCall, tool_calls.items.len);
                for (tool_calls.items, 0..) |tool_call, idx| {
                    const tool_obj = tool_call.object;
                    const id = tool_obj.get("id").?.string;
                    const tool_type = tool_obj.get("type").?.string;
                    const function_obj = tool_obj.get("function").?.object;
                    const name = function_obj.get("name").?.string;
                    const arguments = function_obj.get("arguments").?.string;

                    calls[idx] = .{
                        .id = try allocator.dupe(u8, id),
                        .type = try allocator.dupe(u8, tool_type),
                        .function = .{
                            .name = try allocator.dupe(u8, name),
                            .arguments = try allocator.dupe(u8, arguments),
                        },
                    };
                }
                message.tool_calls = calls;
            },
            else => {},
        }
    }

    return message;
}
