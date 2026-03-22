const std = @import("std");
const types = @import("types.zig");
const openrouter = @import("openrouter.zig");
const toolset = @import("toolset.zig");

const max_turns = 12;

pub fn run(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    api_key: []const u8,
    base_url: []const u8,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    var messages = std.ArrayList(types.Message).empty;
    defer messages.deinit(temp_allocator);
    try messages.append(temp_allocator, .{ .role = "user", .content = try temp_allocator.dupe(u8, prompt) });

    var turn: usize = 0;
    while (turn < max_turns) : (turn += 1) {
        const response = try openrouter.fetchMessage(
            temp_allocator,
            messages.items,
            api_key,
            base_url,
        );
        try messages.append(temp_allocator, response);

        if (response.tool_calls) |tool_calls| {
            for (tool_calls) |tool_call| {
                const tool_output = try toolset.callTool(
                    tool_call.function.name,
                    tool_call.function.arguments,
                    temp_allocator,
                );

                try messages.append(temp_allocator, .{
                    .role = "tool",
                    .content = tool_output,
                    .tool_call_id = tool_call.id,
                });
            }
            continue;
        }

        return allocator.dupe(u8, response.content);
    }

    return error.TooManyTurns;
}
