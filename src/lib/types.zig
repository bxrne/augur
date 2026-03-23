//! Chat roles, modes, and message shapes shared with the OpenRouter/OpenAI
//! chat-completions wire format so we can round-trip without ad-hoc mapping.
const std = @import("std");

pub const Mode = enum {
    build,
    plan,
    pair,
};

pub const Role = enum {
    system,
    user,
    assistant,
    tool,
};

pub fn mode_label(mode: Mode) []const u8 {
    return switch (mode) {
        .build => "build",
        .plan => "plan",
        .pair => "pair",
    };
}

pub const ToolCallFunction = struct {
    name: []const u8,
    arguments: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8,
    function: ToolCallFunction,
};

/// Mirrors the OpenAI chat-completions message object (role, content, optional
/// tool_calls / tool_call_id) so the same struct serves API JSON and in-memory state.
pub const Message = struct {
    role: Role,
    content: []const u8,
    tool_calls: ?[]ToolCall = null,
    tool_call_id: ?[]const u8 = null,
};

/// Produces a deep copy with allocator-owned slices so the result can outlive the
/// source without sharing backing memory.
pub fn clone(
    allocator: std.mem.Allocator,
    message: Message,
) !Message {
    var cloned = Message{
        .role = message.role,
        .content = try allocator.dupe(u8, message.content),
        .tool_calls = null,
        .tool_call_id = null,
    };

    if (message.tool_call_id) |tool_call_id| {
        cloned.tool_call_id = try allocator.dupe(u8, tool_call_id);
    }

    if (message.tool_calls) |tool_calls| {
        cloned.tool_calls = try clone_tool_calls(allocator, tool_calls);
    }

    std.debug.assert(cloned.content.len == message.content.len);
    return cloned;
}

fn clone_tool_calls(
    allocator: std.mem.Allocator,
    tool_calls: []const ToolCall,
) ![]ToolCall {
    const result = try allocator.alloc(ToolCall, tool_calls.len);
    for (tool_calls, 0..) |tc, i| {
        result[i] = .{
            .id = try allocator.dupe(u8, tc.id),
            .type = try allocator.dupe(u8, tc.type),
            .function = .{
                .name = try allocator.dupe(u8, tc.function.name),
                .arguments = try allocator.dupe(u8, tc.function.arguments),
            },
        };
    }
    return result;
}

/// Releases every slice allocated for `message`; pair with `clone` so ownership stays clear.
pub fn free(
    allocator: std.mem.Allocator,
    message: *const Message,
) void {
    allocator.free(message.content);

    if (message.tool_call_id) |tool_call_id| {
        allocator.free(tool_call_id);
    }

    if (message.tool_calls) |tool_calls| {
        for (tool_calls) |tc| {
            allocator.free(tc.id);
            allocator.free(tc.type);
            allocator.free(tc.function.name);
            allocator.free(tc.function.arguments);
        }
        allocator.free(tool_calls);
    }
}

pub fn free_slice(
    allocator: std.mem.Allocator,
    messages: []const Message,
) void {
    for (messages) |*m| {
        free(allocator, m);
    }
}

pub fn replace_owned_string(
    allocator: std.mem.Allocator,
    slot: *[]const u8,
    value: []const u8,
) !void {
    const duped = try allocator.dupe(u8, value);
    allocator.free(slot.*);
    slot.* = duped;
}

/// Builds a full replacement list first, then swaps it in only on success so callers
/// never see a half-copied list if allocation or cloning fails midway.
pub fn replace_list(
    allocator: std.mem.Allocator,
    target: *std.ArrayList(Message),
    source: []const Message,
) !void {
    var next = std.ArrayList(Message).empty;
    errdefer {
        free_slice(allocator, next.items);
        next.deinit(allocator);
    }

    for (source) |message| {
        try next.append(allocator, try clone(allocator, message));
    }

    free_slice(allocator, target.items);
    target.deinit(allocator);
    target.* = next;
}

test "mode_label returns correct strings" {
    try std.testing.expectEqualStrings("plan", mode_label(.plan));
    try std.testing.expectEqualStrings("build", mode_label(.build));
    try std.testing.expectEqualStrings("pair", mode_label(.pair));
}

test "clone and free round-trip" {
    const allocator = std.testing.allocator;
    const original = Message{
        .role = .user,
        .content = "hello world",
    };
    const cloned = try clone(allocator, original);
    defer free(allocator, &cloned);

    try std.testing.expectEqual(Role.user, cloned.role);
    try std.testing.expectEqualStrings("hello world", cloned.content);
    try std.testing.expect(cloned.content.ptr != original.content.ptr);
}

test "clone preserves tool_calls" {
    const allocator = std.testing.allocator;
    var tc_buf = [_]ToolCall{.{
        .id = "tc_1",
        .type = "function",
        .function = .{ .name = "read", .arguments = "{}" },
    }};
    const original = Message{
        .role = .assistant,
        .content = "",
        .tool_calls = &tc_buf,
        .tool_call_id = null,
    };
    const cloned = try clone(allocator, original);
    defer free(allocator, &cloned);

    try std.testing.expect(cloned.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), cloned.tool_calls.?.len);
    try std.testing.expectEqualStrings("read", cloned.tool_calls.?[0].function.name);
}

test "clone preserves tool_call_id" {
    const allocator = std.testing.allocator;
    const original = Message{
        .role = .tool,
        .content = "result",
        .tool_call_id = "call_123",
    };
    const cloned = try clone(allocator, original);
    defer free(allocator, &cloned);

    try std.testing.expect(cloned.tool_call_id != null);
    try std.testing.expectEqualStrings("call_123", cloned.tool_call_id.?);
}

test "replace_owned_string frees old and dupes new" {
    const allocator = std.testing.allocator;
    var slot: []const u8 = try allocator.dupe(u8, "old");
    try replace_owned_string(allocator, &slot, "new");
    defer allocator.free(slot);

    try std.testing.expectEqualStrings("new", slot);
}
