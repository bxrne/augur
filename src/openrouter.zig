const std = @import("std");
const types = @import("types.zig");
const toolset = @import("toolset.zig");

const ToolCallBuilder = struct {
    id: ?[]const u8 = null,
    tool_type: ?[]const u8 = null,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    fn init() ToolCallBuilder {
        return .{};
    }
};

const StreamState = struct {
    allocator: std.mem.Allocator,
    output_file: ?std.fs.File,
    buffer: std.ArrayList(u8),
    content: std.ArrayList(u8),
    tool_calls: std.ArrayList(ToolCallBuilder),
    done: bool = false,
    error_message: ?[]const u8 = null,
    failure: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator, output_file: ?std.fs.File) StreamState {
        return .{
            .allocator = allocator,
            .output_file = output_file,
            .buffer = .empty,
            .content = .empty,
            .tool_calls = .empty,
        };
    }

    pub fn deinit(self: *StreamState) void {
        self.buffer.deinit(self.allocator);
        self.content.deinit(self.allocator);
        for (self.tool_calls.items) |*builder| {
            builder.name.deinit(self.allocator);
            builder.arguments.deinit(self.allocator);
        }
        self.tool_calls.deinit(self.allocator);
    }

    pub fn consume(self: *StreamState, data: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, data);

        while (true) {
            const newline_index = std.mem.indexOfScalar(u8, self.buffer.items, '\n') orelse break;
            var line = self.buffer.items[0..newline_index];
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }
            try self.handleLine(line);

            const remaining = self.buffer.items[newline_index + 1 ..];
            std.mem.copyForwards(u8, self.buffer.items[0..remaining.len], remaining);
            self.buffer.items.len = remaining.len;
        }
    }

    fn handleLine(self: *StreamState, line: []const u8) !void {
        if (line.len == 0) return;
        if (!std.mem.startsWith(u8, line, "data:")) return;

        var payload = line[5..];
        if (payload.len > 0 and payload[0] == ' ') {
            payload = payload[1..];
        }

        if (std.mem.eql(u8, payload, "[DONE]")) {
            self.done = true;
            return;
        }

        try self.handlePayload(payload);
    }

    fn handlePayload(self: *StreamState, payload: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{});
        defer parsed.deinit();

        if (parsed.value.object.get("error")) |err_value| {
            if (err_value == .object) {
                if (err_value.object.get("message")) |message_value| {
                    if (message_value == .string) {
                        self.error_message = try self.allocator.dupe(u8, message_value.string);
                        return;
                    }
                }
            }
            self.error_message = try self.allocator.dupe(u8, payload);
            return;
        }

        const choices_value = parsed.value.object.get("choices") orelse return;
        if (choices_value != .array) return;
        if (choices_value.array.items.len == 0) return;

        const choice = choices_value.array.items[0];
        if (choice != .object) return;

        const delta_value = choice.object.get("delta") orelse return;
        if (delta_value != .object) return;

        if (delta_value.object.get("content")) |content| {
            if (content == .string) {
                try self.appendContent(content.string);
            }
        }

        if (delta_value.object.get("tool_calls")) |tool_calls_value| {
            try self.handleToolCalls(tool_calls_value);
        }
    }

    fn appendContent(self: *StreamState, text: []const u8) !void {
        if (text.len == 0) return;
        try self.content.appendSlice(self.allocator, text);
        if (self.output_file) |file| {
            try file.writeAll(text);
        }
    }

    fn handleToolCalls(self: *StreamState, tool_calls_value: std.json.Value) !void {
        switch (tool_calls_value) {
            .array => |tool_calls| {
                for (tool_calls.items) |tool_call_value| {
                    if (tool_call_value != .object) continue;
                    const tool_obj = tool_call_value.object;

                    const index_value = tool_obj.get("index") orelse continue;
                    const index = parseIndex(index_value) orelse continue;

                    const builder = try self.ensureToolCall(index);

                    if (tool_obj.get("id")) |id_value| {
                        if (id_value == .string and builder.id == null) {
                            builder.id = try self.allocator.dupe(u8, id_value.string);
                        }
                    }

                    if (tool_obj.get("type")) |type_value| {
                        if (type_value == .string and builder.tool_type == null) {
                            builder.tool_type = try self.allocator.dupe(u8, type_value.string);
                        }
                    }

                    if (tool_obj.get("function")) |function_value| {
                        if (function_value != .object) continue;
                        const function_obj = function_value.object;

                        if (function_obj.get("name")) |name_value| {
                            if (name_value == .string) {
                                try builder.name.appendSlice(self.allocator, name_value.string);
                            }
                        }

                        if (function_obj.get("arguments")) |args_value| {
                            if (args_value == .string) {
                                try builder.arguments.appendSlice(self.allocator, args_value.string);
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    fn ensureToolCall(self: *StreamState, index: usize) !*ToolCallBuilder {
        while (self.tool_calls.items.len <= index) {
            try self.tool_calls.append(self.allocator, ToolCallBuilder.init());
        }
        return &self.tool_calls.items[index];
    }

    pub fn finishMessage(self: *StreamState) !types.Message {
        var message = types.Message{
            .role = "assistant",
            .content = "",
        };

        if (self.content.items.len > 0) {
            message.content = try self.content.toOwnedSlice(self.allocator);
        }

        if (self.tool_calls.items.len > 0) {
            const calls = try self.allocator.alloc(types.ToolCall, self.tool_calls.items.len);
            for (self.tool_calls.items, 0..) |*builder, idx| {
                const name = if (builder.name.items.len > 0)
                    try builder.name.toOwnedSlice(self.allocator)
                else
                    "";
                const arguments = if (builder.arguments.items.len > 0)
                    try builder.arguments.toOwnedSlice(self.allocator)
                else
                    "";
                calls[idx] = .{
                    .id = builder.id orelse "",
                    .type = builder.tool_type orelse "function",
                    .function = .{
                        .name = name,
                        .arguments = arguments,
                    },
                };
            }
            message.tool_calls = calls;
        }

        return message;
    }
};

const StreamSink = struct {
    state: *StreamState,
    writer: std.io.Writer,

    pub fn init(state: *StreamState) StreamSink {
        return .{
            .state = state,
            .writer = .{
                .buffer = &.{},
                .vtable = &vtable,
            },
        };
    }

    const vtable: std.io.Writer.VTable = .{
        .drain = drain,
    };

    fn drain(w: *std.io.Writer, data: []const []const u8, splat: usize) std.io.Writer.Error!usize {
        const self: *StreamSink = @fieldParentPtr("writer", w);
        if (data.len == 0) return 0;

        var total: usize = 0;
        if (data.len > 1) {
            for (data[0 .. data.len - 1]) |chunk| {
                self.state.consume(chunk) catch |err| {
                    self.state.failure = err;
                    return error.WriteFailed;
                };
                total += chunk.len;
            }
        }

        const tail = data[data.len - 1];
        var count: usize = 0;
        while (count < splat) : (count += 1) {
            self.state.consume(tail) catch |err| {
                self.state.failure = err;
                return error.WriteFailed;
            };
        }
        total += tail.len * splat;

        return total;
    }
};

pub fn fetchMessage(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
) !types.Message {
    var body_out = try buildRequestBody(allocator, messages, model, false);
    defer body_out.deinit();
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

pub fn streamMessage(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
    output_file: ?std.fs.File,
) !types.Message {
    var body_out = try buildRequestBody(allocator, messages, model, true);
    defer body_out.deinit();
    const body = body_out.written();

    const url_str = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{base_url});
    defer allocator.free(url_str);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var state = StreamState.init(allocator, output_file);
    defer state.deinit();

    var sink = StreamSink.init(&state);

    _ = client.fetch(.{
        .location = .{ .url = url_str },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth_value },
        },
        .response_writer = &sink.writer,
    }) catch |err| {
        if (err == error.WriteFailed) {
            if (state.failure) |failure| return failure;
        }
        return err;
    };

    if (state.error_message) |message| {
        std.debug.print("OpenRouter error: {s}\n", .{message});
        return error.ApiError;
    }

    return state.finishMessage();
}

fn buildRequestBody(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    model: []const u8,
    stream: bool,
) !std.io.Writer.Allocating {
    var body_out: std.io.Writer.Allocating = .init(allocator);
    errdefer body_out.deinit();

    var jw: std.json.Stringify = .{
        .writer = &body_out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };

    try jw.beginObject();
    try jw.objectField("model");
    try jw.write(model);

    if (stream) {
        try jw.objectField("stream");
        try jw.write(true);
    }

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

    return body_out;
}

fn parseIndex(value: std.json.Value) ?usize {
    return switch (value) {
        .integer => |int_value| if (int_value >= 0) @as(usize, @intCast(int_value)) else null,
        .float => |float_value| if (float_value >= 0) @as(usize, @intFromFloat(float_value)) else null,
        .string => |text| std.fmt.parseInt(usize, text, 10) catch null,
        else => null,
    };
}
