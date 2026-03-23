/// OpenRouter HTTP transport: buffered and streaming chat
/// completions.
const std = @import("std");
const types = @import("../core/types.zig");
const toolset = @import("toolset.zig");
const limits = @import("../core/limits.zig");

const ToolCallBuilder = struct {
    id: ?[]const u8 = null,
    tool_type: ?[]const u8 = null,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
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

    fn init(
        allocator: std.mem.Allocator,
        output_file: ?std.fs.File,
    ) StreamState {
        return .{
            .allocator = allocator,
            .output_file = output_file,
            .buffer = .empty,
            .content = .empty,
            .tool_calls = .empty,
        };
    }

    fn deinit(self: *StreamState) void {
        self.buffer.deinit(self.allocator);
        self.content.deinit(self.allocator);
        for (self.tool_calls.items) |*b| {
            b.name.deinit(self.allocator);
            b.arguments.deinit(self.allocator);
        }
        self.tool_calls.deinit(self.allocator);
    }

    /// Append raw bytes and process complete lines.
    fn consume(self: *StreamState, data: []const u8) !void {
        if (self.buffer.items.len + data.len >
            limits.max_stream_buffer_bytes)
        {
            return error.StreamBufferOverflow;
        }

        try self.buffer.appendSlice(self.allocator, data);
        try self.drain_lines();
    }

    /// Process all complete newline-terminated lines in the buffer.
    fn drain_lines(self: *StreamState) !void {
        while (true) {
            const nl = std.mem.indexOfScalar(
                u8,
                self.buffer.items,
                '\n',
            ) orelse break;

            var line = self.buffer.items[0..nl];
            if (line.len > 0) {
                if (line[line.len - 1] == '\r') {
                    line = line[0 .. line.len - 1];
                }
            }
            try self.handle_line(line);

            const rest = self.buffer.items[nl + 1 ..];
            std.mem.copyForwards(
                u8,
                self.buffer.items[0..rest.len],
                rest,
            );
            self.buffer.items.len = rest.len;
        }
    }

    fn handle_line(self: *StreamState, line: []const u8) !void {
        if (line.len == 0) return;
        if (!std.mem.startsWith(u8, line, "data:")) return;

        var payload = line[5..];
        if (payload.len > 0) {
            if (payload[0] == ' ') {
                payload = payload[1..];
            }
        }

        if (std.mem.eql(u8, payload, "[DONE]")) {
            self.done = true;
            return;
        }

        try self.handle_payload(payload);
    }

    fn handle_payload(
        self: *StreamState,
        payload: []const u8,
    ) !void {
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            payload,
            .{},
        );
        defer parsed.deinit();

        if (parsed.value.object.get("error")) |err_val| {
            try self.extract_error(err_val, payload);
            return;
        }

        const delta = extract_delta(parsed.value) orelse return;

        if (delta.object.get("content")) |c| {
            if (c == .string) {
                try self.append_content(c.string);
            }
        }

        if (delta.object.get("tool_calls")) |tc| {
            try self.handle_tool_calls(tc);
        }
    }

    fn extract_error(
        self: *StreamState,
        err_val: std.json.Value,
        payload: []const u8,
    ) !void {
        if (err_val == .object) {
            if (err_val.object.get("message")) |m| {
                if (m == .string) {
                    self.error_message = try self.allocator.dupe(
                        u8,
                        m.string,
                    );
                    return;
                }
            }
        }
        self.error_message = try self.allocator.dupe(
            u8,
            payload,
        );
    }

    fn append_content(self: *StreamState, text: []const u8) !void {
        if (text.len == 0) return;
        try self.content.appendSlice(self.allocator, text);
        if (self.output_file) |file| {
            try file.writeAll(text);
        }
    }

    fn handle_tool_calls(
        self: *StreamState,
        value: std.json.Value,
    ) !void {
        if (value != .array) return;

        for (value.array.items) |tc_val| {
            if (tc_val != .object) continue;
            try self.accumulate_tool_call(tc_val.object);
        }
    }

    fn accumulate_tool_call(
        self: *StreamState,
        obj: std.json.ObjectMap,
    ) !void {
        const index_val = obj.get("index") orelse return;
        const index = parse_index(index_val) orelse return;

        if (index >= limits.max_tool_calls) {
            return error.TooManyToolCalls;
        }

        const builder = try self.ensure_tool_call(index);

        if (obj.get("id")) |id_val| {
            if (id_val == .string) {
                if (builder.id == null) {
                    builder.id = try self.allocator.dupe(
                        u8,
                        id_val.string,
                    );
                }
            }
        }

        if (obj.get("type")) |type_val| {
            if (type_val == .string) {
                if (builder.tool_type == null) {
                    builder.tool_type = try self.allocator.dupe(
                        u8,
                        type_val.string,
                    );
                }
            }
        }

        if (obj.get("function")) |fn_val| {
            if (fn_val != .object) return;
            try self.accumulate_function(fn_val.object, builder);
        }
    }

    fn accumulate_function(
        self: *StreamState,
        obj: std.json.ObjectMap,
        builder: *ToolCallBuilder,
    ) !void {
        if (obj.get("name")) |n| {
            if (n == .string) {
                try builder.name.appendSlice(
                    self.allocator,
                    n.string,
                );
            }
        }
        if (obj.get("arguments")) |a| {
            if (a == .string) {
                try builder.arguments.appendSlice(
                    self.allocator,
                    a.string,
                );
            }
        }
    }

    fn ensure_tool_call(
        self: *StreamState,
        index: usize,
    ) !*ToolCallBuilder {
        while (self.tool_calls.items.len <= index) {
            try self.tool_calls.append(
                self.allocator,
                ToolCallBuilder{},
            );
        }
        return &self.tool_calls.items[index];
    }

    /// Build the final `Message` from accumulated state.
    fn finish_message(self: *StreamState) !types.Message {
        var message = types.Message{
            .role = "assistant",
            .content = "",
        };

        if (self.content.items.len > 0) {
            message.content = try self.content.toOwnedSlice(
                self.allocator,
            );
        }

        if (self.tool_calls.items.len > 0) {
            message.tool_calls = try self.build_tool_calls();
        }

        return message;
    }

    fn build_tool_calls(self: *StreamState) ![]types.ToolCall {
        const calls = try self.allocator.alloc(
            types.ToolCall,
            self.tool_calls.items.len,
        );

        for (self.tool_calls.items, 0..) |*b, i| {
            const name = if (b.name.items.len > 0)
                try b.name.toOwnedSlice(self.allocator)
            else
                "";
            const arguments = if (b.arguments.items.len > 0)
                try b.arguments.toOwnedSlice(self.allocator)
            else
                "";

            calls[i] = .{
                .id = b.id orelse "",
                .type = b.tool_type orelse "function",
                .function = .{
                    .name = name,
                    .arguments = arguments,
                },
            };
        }

        return calls;
    }
};

const StreamSink = struct {
    state: *StreamState,
    writer: std.io.Writer,

    fn init(state: *StreamState) StreamSink {
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

    fn drain(
        w: *std.io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.io.Writer.Error!usize {
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

/// Extract the delta object from a streaming response chunk.
fn extract_delta(root: std.json.Value) ?std.json.Value {
    const choices = root.object.get("choices") orelse return null;
    if (choices != .array) return null;
    if (choices.array.items.len == 0) return null;

    const choice = choices.array.items[0];
    if (choice != .object) return null;

    const delta = choice.object.get("delta") orelse return null;
    if (delta != .object) return null;
    return delta;
}

fn parse_index(value: std.json.Value) ?usize {
    return switch (value) {
        .integer => |v| if (v >= 0)
            @as(usize, @intCast(v))
        else
            null,
        .float => |v| if (v >= 0)
            @as(usize, @intFromFloat(v))
        else
            null,
        .string => |t| std.fmt.parseInt(usize, t, 10) catch null,
        else => null,
    };
}

fn build_chat_url(
    allocator: std.mem.Allocator,
    base_url: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/chat/completions",
        .{base_url},
    );
}

fn build_auth_header(
    allocator: std.mem.Allocator,
    api_key: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Bearer {s}",
        .{api_key},
    );
}

/// Send a non-streaming chat completion request.
pub fn fetch_message(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
) !types.Message {
    std.debug.assert(api_key.len > 0);
    std.debug.assert(model.len > 0);

    var body_out = try build_request_body(
        allocator,
        messages,
        model,
        false,
    );
    defer body_out.deinit();
    const body = body_out.written();

    const url_str = try build_chat_url(allocator, base_url);
    defer allocator.free(url_str);

    const auth = try build_auth_header(allocator, api_key);
    defer allocator.free(auth);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var resp_out: std.io.Writer.Allocating = .init(allocator);
    defer resp_out.deinit();

    _ = try client.fetch(.{
        .location = .{ .url = url_str },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth },
        },
        .response_writer = &resp_out.writer,
    });

    return parse_fetch_response(allocator, resp_out.written());
}

fn parse_fetch_response(
    allocator: std.mem.Allocator,
    body: []const u8,
) !types.Message {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{},
    );
    defer parsed.deinit();

    if (parsed.value.object.get("error")) |err_val| {
        if (err_val.object.get("message")) |m| {
            if (m == .string) {
                std.debug.print(
                    "OpenRouter error: {s}\n",
                    .{m.string},
                );
            }
        } else {
            std.debug.print(
                "OpenRouter error response: {s}\n",
                .{body},
            );
        }
        return error.ApiError;
    }

    const choices = parsed.value.object.get("choices") orelse {
        std.debug.print(
            "Unexpected response: {s}\n",
            .{body},
        );
        return error.MissingChoices;
    };
    if (choices.array.items.len == 0) {
        std.debug.print(
            "Unexpected response: {s}\n",
            .{body},
        );
        return error.MissingChoices;
    }

    const msg_val = choices.array.items[0].object.get(
        "message",
    ).?;
    return parse_message_value(allocator, msg_val);
}

fn parse_message_value(
    allocator: std.mem.Allocator,
    val: std.json.Value,
) !types.Message {
    var message = types.Message{
        .role = "assistant",
        .content = "",
    };

    if (val.object.get("content")) |c| {
        if (c == .string) {
            message.content = try allocator.dupe(u8, c.string);
        }
    }

    if (val.object.get("tool_calls")) |tc_val| {
        if (tc_val == .array) {
            message.tool_calls = try parse_tool_calls(
                allocator,
                tc_val.array.items,
            );
        }
    }

    return message;
}

fn parse_tool_calls(
    allocator: std.mem.Allocator,
    items: []const std.json.Value,
) ![]types.ToolCall {
    const calls = try allocator.alloc(types.ToolCall, items.len);

    for (items, 0..) |tc, i| {
        const obj = tc.object;
        const fn_obj = obj.get("function").?.object;

        calls[i] = .{
            .id = try allocator.dupe(
                u8,
                obj.get("id").?.string,
            ),
            .type = try allocator.dupe(
                u8,
                obj.get("type").?.string,
            ),
            .function = .{
                .name = try allocator.dupe(
                    u8,
                    fn_obj.get("name").?.string,
                ),
                .arguments = try allocator.dupe(
                    u8,
                    fn_obj.get("arguments").?.string,
                ),
            },
        };
    }

    return calls;
}

/// Send a streaming chat completion request.
pub fn stream_message(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
    output_file: ?std.fs.File,
) !types.Message {
    std.debug.assert(api_key.len > 0);
    std.debug.assert(model.len > 0);

    var body_out = try build_request_body(
        allocator,
        messages,
        model,
        true,
    );
    defer body_out.deinit();
    const body = body_out.written();

    const url_str = try build_chat_url(allocator, base_url);
    defer allocator.free(url_str);

    const auth = try build_auth_header(allocator, api_key);
    defer allocator.free(auth);

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
            .{ .name = "authorization", .value = auth },
        },
        .response_writer = &sink.writer,
    }) catch |err| {
        if (err == error.WriteFailed) {
            if (state.failure) |f| return f;
        }
        return err;
    };

    if (state.error_message) |e| {
        std.debug.print("OpenRouter error: {s}\n", .{e});
        return error.ApiError;
    }

    return state.finish_message();
}

fn build_request_body(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    model: []const u8,
    stream: bool,
) !std.io.Writer.Allocating {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var jw: std.json.Stringify = .{
        .writer = &out.writer,
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
    for (messages) |m| {
        try jw.write(m);
    }
    try jw.endArray();

    try jw.objectField("tools");
    try jw.beginArray();
    try toolset.write_tool_definitions(&jw);
    try jw.endArray();

    try jw.endObject();

    return out;
}
