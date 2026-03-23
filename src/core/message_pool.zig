/// Shared deep-copy and lifetime helpers for `Message` values.
///
/// Both `harness.zig` and the conversation store need to clone
/// messages across allocator boundaries. This module provides a
/// single implementation so the logic is tested and maintained in
/// one place.
const std = @import("std");
const types = @import("types.zig");

/// Deep-copy a single message, duplicating every owned slice.
pub fn clone(
    allocator: std.mem.Allocator,
    message: types.Message,
) !types.Message {
    std.debug.assert(message.role.len > 0);

    var cloned = types.Message{
        .role = try allocator.dupe(u8, message.role),
        .content = try allocator.dupe(u8, message.content),
        .tool_calls = null,
        .tool_call_id = null,
    };

    if (message.tool_call_id) |tool_call_id| {
        cloned.tool_call_id = try allocator.dupe(
            u8,
            tool_call_id,
        );
    }

    if (message.tool_calls) |tool_calls| {
        cloned.tool_calls = try clone_tool_calls(
            allocator,
            tool_calls,
        );
    }

    std.debug.assert(cloned.role.len == message.role.len);
    std.debug.assert(cloned.content.len == message.content.len);
    return cloned;
}

/// Deep-copy a tool-calls slice.
fn clone_tool_calls(
    allocator: std.mem.Allocator,
    tool_calls: []const types.ToolCall,
) ![]types.ToolCall {
    const result = try allocator.alloc(
        types.ToolCall,
        tool_calls.len,
    );
    for (tool_calls, 0..) |tc, i| {
        result[i] = .{
            .id = try allocator.dupe(u8, tc.id),
            .type = try allocator.dupe(u8, tc.type),
            .function = .{
                .name = try allocator.dupe(u8, tc.function.name),
                .arguments = try allocator.dupe(
                    u8,
                    tc.function.arguments,
                ),
            },
        };
    }
    return result;
}

/// Release all owned memory inside a single message.
pub fn free(
    allocator: std.mem.Allocator,
    message: *const types.Message,
) void {
    allocator.free(message.role);
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

/// Release every message in a slice.
pub fn free_slice(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
) void {
    for (messages) |*m| {
        free(allocator, m);
    }
}

/// Replace the contents of `slot` with a freshly duped value,
/// freeing the old string first.
pub fn replace_owned_string(
    allocator: std.mem.Allocator,
    slot: *[]const u8,
    value: []const u8,
) !void {
    const duped = try allocator.dupe(u8, value);
    allocator.free(slot.*);
    slot.* = duped;
}

/// Swap an entire message list for a deep copy of `source`,
/// freeing the old contents.
pub fn replace_list(
    allocator: std.mem.Allocator,
    target: *std.ArrayList(types.Message),
    source: []const types.Message,
) !void {
    var next = std.ArrayList(types.Message).empty;
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
