/// Session harness: manages messages, mode, model, and drives
/// the send/tool-call loop.
const std = @import("std");
const types = @import("../core/types.zig");
const openrouter = @import("../api/openrouter.zig");
const toolset = @import("../api/toolset.zig");
const msg = @import("../core/message_pool.zig");
const skills = @import("skills.zig");

pub const Mode = types.Mode;
pub const mode_label = types.mode_label;

pub const default_model = "anthropic/claude-haiku-4.5";

const preamble =
    "You are augur, a terminal coding assistant." ++
    " Be precise, safe, and helpful." ++
    " Personality: concise, direct, friendly." ++
    " Never guess or invent results." ++
    " Keep users informed with short progress updates" ++
    " before grouped tool actions." ++
    " For non-trivial work, use short step-by-step plans" ++
    " and update progress as steps complete." ++
    " Prefer root-cause fixes with minimal, focused diffs." ++
    " Validate with targeted checks when practical." ++
    "\n\n" ++
    "You are running in the user's terminal with access" ++
    " to their working directory." ++
    " Available tools: `read` (read files), `write`" ++
    " (write files), and `bash` (run shell commands)." ++
    " Use tools whenever file or command work is needed." ++
    "\n\n" ++
    "Instruction files:" ++
    " Follow `AGENTS.md` instructions for files you touch;" ++
    " deeper `AGENTS.md` files override broader ones.";

const build_prompt = preamble ++
    " You are in BUILD mode." ++
    " Implement code directly when needed." ++
    " Read existing code before editing." ++
    " Keep changes consistent with local style." ++
    " Avoid unrelated refactors.";
const plan_prompt = preamble ++
    " You are in PLAN mode." ++
    " Provide short, actionable plans with trade-offs." ++
    " Do not output implementation code." ++
    " Read files when context is needed.";
const pair_prompt = preamble ++
    " You are in PAIR mode." ++
    " Act as a senior pair programmer: direct, concrete, and practical." ++
    " Give actionable next steps with checkpoints, not vague advice." ++
    " You may provide code, but prioritize helping the user drive." ++
    " Prefer verifying behavior from local sources before recommending APIs:" ++
    " inspect interfaces, read project code, run `--help`, and use `man` when available." ++
    " For language docs, use local commands when possible (examples: `go doc`, `go help`, `zig build --help`, `zig env`, `rustc --help`, `python -m pydoc`)." ++
    " If a local docs server is available for the stack, propose/start it with exact commands and summarize what you found." ++
    " Structure responses as: (1) what you checked, (2) ordered path forward, (3) optional implementation patch.";

fn system_prompt(mode: Mode) []const u8 {
    return switch (mode) {
        .build => build_prompt,
        .plan => plan_prompt,
        .pair => pair_prompt,
    };
}

pub const SendOptions = struct {
    streaming: bool = false,
    stream_output: ?std.fs.File = null,
    on_first_stream_delta: ?*const fn (*anyopaque) void = null,
    on_first_stream_delta_ctx: ?*anyopaque = null,
};

pub const TurnUsage = struct {
    available: bool = false,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    total_tokens: u64 = 0,
    context_window_tokens: u64 = 0,
    context_used_tenths_pct: u16 = 0,
    context_left_tenths_pct: u16 = 1000,
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
    skills_text: []u8,
    last_turn_usage: TurnUsage,

    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        base_url: []const u8,
    ) !Harness {
        std.debug.assert(api_key.len > 0);
        std.debug.assert(base_url.len > 0);

        var result = Harness{
            .backing_allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .messages = std.ArrayList(types.Message).empty,
            .api_key = api_key,
            .base_url = base_url,
            .model = default_model,
            .mode = .build,
            .system_text = build_prompt,
            .skills_text = try skills.load_system_suffix(
                allocator,
            ),
            .last_turn_usage = .{},
        };
        errdefer allocator.free(result.skills_text);

        try result.rebuild_system_text();
        return result;
    }

    pub fn deinit(self: *Harness) void {
        self.messages.deinit(self.arena.allocator());
        self.arena.deinit();
        self.backing_allocator.free(self.skills_text);
    }

    pub fn getMode(self: *const Harness) Mode {
        return self.mode;
    }

    pub fn getModel(self: *const Harness) []const u8 {
        return self.model;
    }

    pub fn latestUsage(self: *const Harness) TurnUsage {
        return self.last_turn_usage;
    }

    pub fn messagesSlice(
        self: *const Harness,
    ) []const types.Message {
        return self.messages.items;
    }

    pub fn setMode(self: *Harness, mode: Mode) !void {
        self.mode = mode;
        try self.rebuild_system_text();
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
        try self.reset_state();

        const a = self.arena.allocator();
        self.mode = mode;
        try self.rebuild_system_text();
        self.model = try a.dupe(u8, model);

        for (messages) |m| {
            try self.messages.append(a, try msg.clone(a, m));
        }

        try self.ensure_system_message();
    }

    /// Send a user prompt and return the final assistant text.
    ///
    /// Tool-call rounds continue while context space remains.
    pub fn send(
        self: *Harness,
        prompt: []const u8,
        options: SendOptions,
    ) ![]const u8 {
        std.debug.assert(prompt.len > 0);

        self.last_turn_usage = .{};

        const a = self.arena.allocator();
        try self.ensure_system_message();
        try self.messages.append(a, .{
            .role = "user",
            .content = try a.dupe(u8, prompt),
        });

        var usage_seen = false;
        var cumulative_input: u64 = 0;
        var cumulative_output: u64 = 0;
        var cumulative_total: u64 = 0;
        var max_context_input: u64 = 0;

        const context_window = context_window_tokens_for_model(
            self.model,
        );

        while (true) {
            if (usage_seen and max_context_input >= context_window) {
                return error.ContextWindowExhausted;
            }
            const api_response = try self.fetch_response(
                a,
                options,
            );
            const response = api_response.message;
            try self.messages.append(a, response);

            if (api_response.usage.has_data()) {
                usage_seen = true;
                cumulative_input += api_response.usage.input_tokens;
                cumulative_output += api_response.usage.output_tokens;
                cumulative_total += if (api_response.usage.total_tokens > 0)
                    api_response.usage.total_tokens
                else
                    api_response.usage.input_tokens +
                        api_response.usage.output_tokens;

                max_context_input = @max(
                    max_context_input,
                    api_response.usage.input_tokens,
                );
            }

            const used_tenths = context_used_tenths(
                max_context_input,
                context_window,
            );
            self.last_turn_usage = .{
                .available = usage_seen,
                .input_tokens = cumulative_input,
                .output_tokens = cumulative_output,
                .total_tokens = if (cumulative_total > 0)
                    cumulative_total
                else
                    (cumulative_input + cumulative_output),
                .context_window_tokens = context_window,
                .context_used_tenths_pct = used_tenths,
                .context_left_tenths_pct = 1000 -| used_tenths,
            };

            const tool_calls = response.tool_calls orelse {
                return response.content;
            };

            if (!usage_seen) {
                return error.ContextUsageUnavailable;
            }

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

        unreachable;
    }

    fn fetch_response(
        self: *Harness,
        a: std.mem.Allocator,
        options: SendOptions,
    ) !openrouter.Response {
        if (options.streaming) {
            return openrouter.stream_message(
                a,
                self.messages.items,
                self.api_key,
                self.base_url,
                self.model,
                options.stream_output,
                options.on_first_stream_delta,
                options.on_first_stream_delta_ctx,
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

    fn context_window_tokens_for_model(model: []const u8) u64 {
        if (std.mem.startsWith(u8, model, "anthropic/")) {
            return 200_000;
        }
        if (std.mem.startsWith(u8, model, "openai/gpt-4.1")) {
            return 1_047_576;
        }
        if (std.mem.startsWith(u8, model, "openai/")) {
            return 128_000;
        }
        if (std.mem.startsWith(u8, model, "google/")) {
            return 1_000_000;
        }
        return 200_000;
    }

    fn context_used_tenths(
        input_tokens: u64,
        context_window: u64,
    ) u16 {
        if (context_window == 0) return 0;
        const scaled =
            (input_tokens * 1000 + context_window / 2) /
            context_window;
        return @intCast(@min(scaled, 1000));
    }

    fn reset_state(self: *Harness) !void {
        self.messages.deinit(self.arena.allocator());
        self.arena.deinit();

        self.arena = std.heap.ArenaAllocator.init(
            self.backing_allocator,
        );
        self.messages = std.ArrayList(types.Message).empty;
        self.model = default_model;
        self.mode = .build;
        self.last_turn_usage = .{};
        try self.rebuild_system_text();
    }

    fn rebuild_system_text(self: *Harness) !void {
        const base = system_prompt(self.mode);
        if (self.skills_text.len == 0) {
            self.system_text = base;
            return;
        }

        const a = self.arena.allocator();
        self.system_text = try std.fmt.allocPrint(
            a,
            "{s}\n\n{s}",
            .{ base, self.skills_text },
        );
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
