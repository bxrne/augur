/// Session harness: manages messages, mode, model, and drives
/// the send/tool-call loop.
const std = @import("std");
const types = @import("../core/types.zig");
const openrouter = @import("../api/openrouter.zig");
const toolset = @import("../api/toolset.zig");
const msg = @import("../core/message_pool.zig");
const limits = @import("../core/limits.zig");

pub const Mode = types.Mode;
pub const mode_label = types.mode_label;

pub const default_model = "anthropic/claude-haiku-4.5";

const preamble =
    "You are augur, a command-line coding assistant." ++
    " You are running in the user's terminal with access" ++
    " to their working directory." ++
    " You have three tools:" ++
    " `read` (read a file), `write` (write a file)," ++
    " and `bash` (run a shell command)." ++
    " Always use tools when the user asks you to inspect," ++
    " create, or modify files or run commands." ++
    " Be terse. No preamble. No filler.\n\n";

const build_prompt = preamble ++
    "You are in BUILD mode." ++
    " Write working code. Implement solutions directly." ++
    " Use tools to read existing code before editing." ++
    " Show diffs or full files as appropriate." ++
    " Prefer small, correct changes over large rewrites.";
const plan_prompt = preamble ++
    "You are in PLAN mode." ++
    " Outline steps, trade-offs, and approach." ++
    " Do NOT write implementation code." ++
    " Use tools to read files when you need context." ++
    " Keep plans short and actionable.";

fn system_prompt(mode: Mode) []const u8 {
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
    system_text: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        base_url: []const u8,
    ) Harness {
        std.debug.assert(api_key.len > 0);
        std.debug.assert(base_url.len > 0);

        return .{
            .backing_allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .messages = std.ArrayList(types.Message).empty,
            .api_key = api_key,
            .base_url = base_url,
            .model = default_model,
            .mode = .build,
            .system_text = build_prompt,
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

    pub fn messagesSlice(
        self: *const Harness,
    ) []const types.Message {
        return self.messages.items;
    }

    pub fn setMode(self: *Harness, mode: Mode) !void {
        self.mode = mode;
        self.system_text = system_prompt(mode);
        try self.ensure_system_message();

        std.debug.assert(self.system_text.len > 0);
    }

    pub fn setModel(self: *Harness, model: []const u8) !void {
        std.debug.assert(model.len > 0);
        const a = self.arena.allocator();
        self.model = try a.dupe(u8, model);
    }

    pub fn loadConversation(
        self: *Harness,
        mode: Mode,
        model: []const u8,
        messages: []const types.Message,
    ) !void {
        self.reset_state();

        const a = self.arena.allocator();
        self.mode = mode;
        self.system_text = system_prompt(mode);
        self.model = try a.dupe(u8, model);

        for (messages) |m| {
            try self.messages.append(a, try msg.clone(a, m));
        }

        try self.ensure_system_message();
    }

    /// Send a user prompt and return the final assistant text.
    ///
    /// Runs up to `limits.max_tool_turns` tool-call rounds.
    pub fn send(
        self: *Harness,
        prompt: []const u8,
        options: SendOptions,
    ) ![]const u8 {
        std.debug.assert(prompt.len > 0);

        const a = self.arena.allocator();
        try self.ensure_system_message();
        try self.messages.append(a, .{
            .role = "user",
            .content = try a.dupe(u8, prompt),
        });

        var turn: u32 = 0;
        while (turn < limits.max_tool_turns) : (turn += 1) {
            const response = try self.fetch_response(
                a,
                options,
            );
            try self.messages.append(a, response);

            const tool_calls = response.tool_calls orelse {
                return response.content;
            };

            for (tool_calls) |tc| {
                const output = try toolset.call_tool(
                    tc.function.name,
                    tc.function.arguments,
                    a,
                );
                try self.messages.append(a, .{
                    .role = "tool",
                    .content = output,
                    .tool_call_id = tc.id,
                });
            }
        }

        return error.TooManyTurns;
    }

    fn fetch_response(
        self: *Harness,
        a: std.mem.Allocator,
        options: SendOptions,
    ) !types.Message {
        if (options.streaming) {
            return openrouter.stream_message(
                a,
                self.messages.items,
                self.api_key,
                self.base_url,
                self.model,
                options.stream_output,
            );
        }
        return openrouter.fetch_message(
            a,
            self.messages.items,
            self.api_key,
            self.base_url,
            self.model,
        );
    }

    fn reset_state(self: *Harness) void {
        self.messages.deinit(self.arena.allocator());
        self.arena.deinit();

        self.arena = std.heap.ArenaAllocator.init(
            self.backing_allocator,
        );
        self.messages = std.ArrayList(types.Message).empty;
        self.model = default_model;
        self.mode = .build;
        self.system_text = build_prompt;
    }

    fn ensure_system_message(self: *Harness) !void {
        if (self.system_text.len == 0) return;

        const a = self.arena.allocator();
        const content = try a.dupe(u8, self.system_text);

        if (self.messages.items.len == 0) {
            try self.messages.append(a, .{
                .role = "system",
                .content = content,
            });
            std.debug.assert(self.messages.items.len > 0);
            return;
        }

        if (!std.mem.eql(
            u8,
            self.messages.items[0].role,
            "system",
        )) {
            try self.messages.insert(a, 0, .{
                .role = "system",
                .content = content,
            });
            std.debug.assert(self.messages.items.len > 0);
            return;
        }

        self.messages.items[0].content = content;
    }
};
