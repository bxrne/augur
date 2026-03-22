const std = @import("std");
const types = @import("types.zig");
const openrouter = @import("openrouter.zig");
const toolset = @import("toolset.zig");

const max_tool_turns = 12;

pub const Mode = enum {
    build,
    plan,
};

pub const default_model = "anthropic/claude-haiku-4.5";

const build_prompt = "You are in build mode. Provide concise implementation guidance and code when needed. Be direct and practical.";
const plan_prompt = "You are in plan mode. Provide a short plan with bullet points or steps. Avoid code until build mode is selected.";

pub fn modeLabel(mode: Mode) []const u8 {
    return switch (mode) {
        .build => "build",
        .plan => "plan",
    };
}

fn systemPrompt(mode: Mode) []const u8 {
    return switch (mode) {
        .build => build_prompt,
        .plan => plan_prompt,
    };
}

pub const SendOptions = struct {
    streaming: bool = false,
    stream_output: ?std.fs.File = null,
};

pub const Harness = struct {
    backing_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    messages: std.ArrayList(types.Message),
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
    mode: Mode,
    system_prompt: []const u8,

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8, base_url: []const u8) Harness {
        return .{
            .backing_allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .messages = std.ArrayList(types.Message).empty,
            .api_key = api_key,
            .base_url = base_url,
            .model = default_model,
            .mode = .build,
            .system_prompt = build_prompt,
        };
    }

    pub fn deinit(self: *Harness) void {
        self.messages.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    pub fn getMode(self: *const Harness) Mode {
        return self.mode;
    }

    pub fn getModel(self: *const Harness) []const u8 {
        return self.model;
    }

    pub fn messagesSlice(self: *const Harness) []const types.Message {
        return self.messages.items;
    }

    pub fn setMode(self: *Harness, mode: Mode) !void {
        self.mode = mode;
        self.system_prompt = systemPrompt(mode);
        try self.ensureSystemMessage();
    }

    pub fn setModel(self: *Harness, model: []const u8) !void {
        const arena_allocator = self.arena.allocator();
        self.model = try arena_allocator.dupe(u8, model);
    }

    pub fn loadConversation(self: *Harness, mode: Mode, model: []const u8, messages: []const types.Message) !void {
        self.resetState();

        const arena_allocator = self.arena.allocator();
        self.mode = mode;
        self.system_prompt = systemPrompt(mode);
        self.model = try arena_allocator.dupe(u8, model);

        for (messages) |message| {
            try self.messages.append(arena_allocator, try duplicateMessage(arena_allocator, message));
        }

        try self.ensureSystemMessage();
    }

    pub fn send(self: *Harness, prompt: []const u8, options: SendOptions) ![]const u8 {
        const arena_allocator = self.arena.allocator();
        try self.ensureSystemMessage();
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
                    self.model,
                    options.stream_output,
                )
            else
                try openrouter.fetchMessage(
                    arena_allocator,
                    self.messages.items,
                    self.api_key,
                    self.base_url,
                    self.model,
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

    fn resetState(self: *Harness) void {
        self.messages.deinit(self.arena.allocator());
        self.arena.deinit();

        self.arena = std.heap.ArenaAllocator.init(self.backing_allocator);
        self.messages = std.ArrayList(types.Message).empty;
        self.model = default_model;
        self.mode = .build;
        self.system_prompt = build_prompt;
    }

    fn duplicateMessage(allocator: std.mem.Allocator, message: types.Message) !types.Message {
        var duplicated = types.Message{
            .role = try allocator.dupe(u8, message.role),
            .content = try allocator.dupe(u8, message.content),
            .tool_calls = null,
            .tool_call_id = null,
        };

        if (message.tool_call_id) |tool_call_id| {
            duplicated.tool_call_id = try allocator.dupe(u8, tool_call_id);
        }

        if (message.tool_calls) |tool_calls| {
            const duplicated_calls = try allocator.alloc(types.ToolCall, tool_calls.len);
            for (tool_calls, 0..) |tool_call, idx| {
                duplicated_calls[idx] = .{
                    .id = try allocator.dupe(u8, tool_call.id),
                    .type = try allocator.dupe(u8, tool_call.type),
                    .function = .{
                        .name = try allocator.dupe(u8, tool_call.function.name),
                        .arguments = try allocator.dupe(u8, tool_call.function.arguments),
                    },
                };
            }
            duplicated.tool_calls = duplicated_calls;
        }

        return duplicated;
    }

    fn ensureSystemMessage(self: *Harness) !void {
        if (self.system_prompt.len == 0) return;
        const arena_allocator = self.arena.allocator();
        const content = try arena_allocator.dupe(u8, self.system_prompt);

        if (self.messages.items.len == 0) {
            try self.messages.append(arena_allocator, .{
                .role = "system",
                .content = content,
            });
            return;
        }

        if (!std.mem.eql(u8, self.messages.items[0].role, "system")) {
            try self.messages.insert(arena_allocator, 0, .{
                .role = "system",
                .content = content,
            });
            return;
        }

        self.messages.items[0].content = content;
    }
};
