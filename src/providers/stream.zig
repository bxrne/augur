/// SSE framing for OpenAI-style streamed chat: splits `data:` lines, parses JSON
/// deltas, and merges partial assistant content and tool-call chunks.
const std = @import("std");
const types = @import("../lib/types.zig");

/// Hard cap on the in-memory line buffer so a stuck or malicious stream cannot
/// grow `ArrayList` without bound.
const max_stream_buffer_bytes: u32 = 8 * 1024 * 1024;

pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    total_tokens: u64 = 0,

    pub fn has_data(self: Usage) bool {
        return self.input_tokens > 0 or
            self.output_tokens > 0 or
            self.total_tokens > 0;
    }
};

pub const Response = struct {
    message: types.Message,
    usage: Usage = .{},
};

/// One tool call is split across many SSE events; fields accumulate until
/// `finish_response` can emit a complete `types.ToolCall`.
const ToolCallBuilder = struct {
    id: ?[]const u8 = null,
    tool_type: ?[]const u8 = null,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
};

/// Holds streaming parse state: raw buffer, assistant text, and per-index tool
/// builders until the provider signals end-of-stream.
pub const StreamState = struct {
    allocator: std.mem.Allocator,
    output_file: ?std.fs.File,
    on_first_stream_delta: ?*const fn (*anyopaque) void,
    on_first_stream_delta_ctx: ?*anyopaque,
    first_stream_delta_emitted: bool,
    on_first_content: ?*const fn (*anyopaque) void,
    on_first_content_ctx: ?*anyopaque,
    first_content_emitted: bool,
    buffer: std.ArrayList(u8),
    content: std.ArrayList(u8),
    tool_calls: std.ArrayList(ToolCallBuilder),
    done: bool = false,
    error_message: ?[]const u8 = null,
    failure: ?anyerror = null,
    usage: Usage = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        output_file: ?std.fs.File,
        on_first_stream_delta: ?*const fn (*anyopaque) void,
        on_first_stream_delta_ctx: ?*anyopaque,
        on_first_content: ?*const fn (*anyopaque) void,
        on_first_content_ctx: ?*anyopaque,
    ) StreamState {
        return .{
            .allocator = allocator,
            .output_file = output_file,
            .on_first_stream_delta = on_first_stream_delta,
            .on_first_stream_delta_ctx = on_first_stream_delta_ctx,
            .first_stream_delta_emitted = false,
            .on_first_content = on_first_content,
            .on_first_content_ctx = on_first_content_ctx,
            .first_content_emitted = false,
            .buffer = .empty,
            .content = .empty,
            .tool_calls = .empty,
        };
    }

    pub fn deinit(self: *StreamState) void {
        self.buffer.deinit(self.allocator);
        self.content.deinit(self.allocator);
        for (self.tool_calls.items) |*b| {
            b.name.deinit(self.allocator);
            b.arguments.deinit(self.allocator);
        }
        self.tool_calls.deinit(self.allocator);
    }

    pub fn consume(self: *StreamState, data: []const u8) !void {
        if (self.buffer.items.len + data.len >
            max_stream_buffer_bytes)
        {
            return error.StreamBufferOverflow;
        }

        try self.buffer.appendSlice(self.allocator, data);
        try self.drain_lines();
    }

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

        if (parsed.value.object.get("usage")) |usage_val| {
            self.usage = parse_usage_value(usage_val);
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
        self.mark_first_stream_delta();
        self.mark_first_content();
        try self.content.appendSlice(self.allocator, text);
        if (self.output_file) |file| {
            try file.writeAll(text);
        }
    }

    /// Fires once per StreamState when the first visible content token arrives,
    /// distinct from mark_first_stream_delta which also fires for tool-call deltas.
    fn mark_first_content(self: *StreamState) void {
        if (self.first_content_emitted) return;
        self.first_content_emitted = true;

        const callback = self.on_first_content orelse return;
        const ctx = self.on_first_content_ctx orelse return;
        callback(ctx);
    }

    fn handle_tool_calls(
        self: *StreamState,
        value: std.json.Value,
    ) !void {
        if (value != .array) return;
        if (value.array.items.len > 0) {
            self.mark_first_stream_delta();
        }

        for (value.array.items) |tc_val| {
            if (tc_val != .object) continue;
            try self.accumulate_tool_call(tc_val.object);
        }
    }

    fn mark_first_stream_delta(self: *StreamState) void {
        if (self.first_stream_delta_emitted) return;
        self.first_stream_delta_emitted = true;

        const callback = self.on_first_stream_delta orelse return;
        const ctx = self.on_first_stream_delta_ctx orelse return;
        callback(ctx);
    }

    fn accumulate_tool_call(
        self: *StreamState,
        obj: std.json.ObjectMap,
    ) !void {
        const index_val = obj.get("index") orelse return;
        const index = parse_index(index_val) orelse return;

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

    pub fn finish_response(self: *StreamState) !Response {
        var message = types.Message{
            .role = .assistant,
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

        return .{
            .message = message,
            .usage = self.usage,
        };
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

/// Bridges `StreamState.consume` to `std.io.Writer` so `http.Client.fetch` can
/// stream the response body without a separate read loop type.
pub const StreamSink = struct {
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

pub fn extract_delta(root: std.json.Value) ?std.json.Value {
    const choices = root.object.get("choices") orelse return null;
    if (choices != .array) return null;
    if (choices.array.items.len == 0) return null;

    const choice = choices.array.items[0];
    if (choice != .object) return null;

    const delta = choice.object.get("delta") orelse return null;
    if (delta != .object) return null;
    return delta;
}

pub fn parse_index(value: std.json.Value) ?usize {
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

fn parse_u64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |v| if (v >= 0)
            @as(u64, @intCast(v))
        else
            null,
        .float => |v| if (v >= 0)
            @as(u64, @intFromFloat(v))
        else
            null,
        .string => |t| std.fmt.parseInt(u64, t, 10) catch null,
        else => null,
    };
}

pub fn parse_usage_value(value: std.json.Value) Usage {
    if (value != .object) return .{};

    const obj = value.object;
    const input = if (obj.get("prompt_tokens")) |v|
        parse_u64(v) orelse 0
    else if (obj.get("input_tokens")) |v|
        parse_u64(v) orelse 0
    else
        0;

    const output = if (obj.get("completion_tokens")) |v|
        parse_u64(v) orelse 0
    else if (obj.get("output_tokens")) |v|
        parse_u64(v) orelse 0
    else
        0;

    const total = if (obj.get("total_tokens")) |v|
        parse_u64(v) orelse (input + output)
    else
        (input + output);

    return .{
        .input_tokens = input,
        .output_tokens = output,
        .total_tokens = total,
    };
}
