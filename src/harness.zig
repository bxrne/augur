const std = @import("std");
const types = @import("types.zig");
const openrouter = @import("openrouter.zig");
const toolset = @import("toolset.zig");

const max_tool_turns = 12;

pub const SendOptions = struct {
    streaming: bool = false,
    stream_output: ?std.fs.File = null,
};

pub const Harness = struct {
    arena: std.heap.ArenaAllocator,
    messages: std.ArrayList(types.Message),
    api_key: []const u8,
    base_url: []const u8,

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8, base_url: []const u8) Harness {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .messages = std.ArrayList(types.Message).empty,
            .api_key = api_key,
            .base_url = base_url,
        };
    }

    pub fn deinit(self: *Harness) void {
        self.messages.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    pub fn send(self: *Harness, prompt: []const u8, options: SendOptions) ![]const u8 {
        const arena_allocator = self.arena.allocator();
        try self.messages.append(arena_allocator, .{
            .role = "user",
            .content = try arena_allocator.dupe(u8, prompt),
        });

        var turn: usize = 0;
        while (turn < max_tool_turns) : (turn += 1) {
            const response = if (options.streaming)
                try openrouter.streamMessage(
                    arena_allocator,
                    self.messages.items,
                    self.api_key,
                    self.base_url,
                    options.stream_output,
                )
            else
                try openrouter.fetchMessage(
                    arena_allocator,
                    self.messages.items,
                    self.api_key,
                    self.base_url,
                );
            try self.messages.append(arena_allocator, response);

            if (response.tool_calls) |tool_calls| {
                for (tool_calls) |tool_call| {
                    const tool_output = try toolset.callTool(
                        tool_call.function.name,
                        tool_call.function.arguments,
                        arena_allocator,
                    );

                    try self.messages.append(arena_allocator, .{
                        .role = "tool",
                        .content = tool_output,
                        .tool_call_id = tool_call.id,
                    });
                }
                continue;
            }

            return response.content;
        }

        return error.TooManyTurns;
    }
};
