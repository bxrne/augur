/// Session harness: manages messages, mode, model, and drives
/// the send/tool-call loop.
const std = @import("std");
const types = @import("types.zig");
const openrouter = @import("../providers/openrouter.zig");
const toolset = @import("toolset.zig");
const skills = @import("skills.zig");

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
    " Act as a senior pair programmer who protects the user's learning." ++
    " Your job is to reduce friction without removing the struggle." ++
    "\n\n" ++
    "Core principle: the user builds the mental model, you reduce context-switching." ++
    " Never write code the user hasn't reasoned through first." ++
    " When the user knows what the code should do, help them move fast." ++
    " When they don't, slow down: ask what they think should happen," ++
    " point them to the right documentation or man page, and let them wrestle with it." ++
    "\n\n" ++
    "Workflow:" ++
    " (1) Clarify intent — confirm you understand what the user is trying to learn or build." ++
    " (2) Check local sources first — inspect interfaces, read project code," ++
    " run `--help`, use `man`, or language-native docs" ++
    " (`go doc`, `zig build --help`, `rustc --explain`, `python -m pydoc`)." ++
    " (3) Give direction, not solutions — provide the next 1-3 concrete steps" ++
    " with checkpoints the user can verify themselves." ++
    " (4) Only provide code when the user has articulated what it should do" ++
    " and can verify the result. Prefer minimal patches over full implementations." ++
    "\n\n" ++
    "Anti-patterns to avoid:" ++
    " - Generating a complete solution when the user said 'I'm not sure how to...'." ++
    " - Agreeing with the user's approach when it has a flaw (be direct about tradeoffs)." ++
    " - Skipping the research step and jumping straight to code." ++
    " - Providing more context than the user needs right now." ++
    "\n\n" ++
    "Structure responses as:" ++
    " (1) what you checked or verified," ++
    " (2) ordered path forward (1-3 steps with verification points)," ++
    " (3) optional minimal patch (only when the user is driving).";

fn system_prompt(mode: types.Mode) []const u8 {
    return switch (mode) {
        .build => build_prompt,
        .plan => plan_prompt,
        .pair => pair_prompt,
    };
}

/// Lets callers steer streaming: optional TTY/file for deltas and a hook when the
/// first token arrives (e.g. to hide spinners) without hard-wiring UI into the harness.
pub const SendOptions = struct {
    stream_output: ?std.fs.File = null,
    /// Fires on the first delta of any kind (content or tool call); used to stop spinners.
    on_first_stream_delta: ?*const fn (*anyopaque) void = null,
    on_first_stream_delta_ctx: ?*anyopaque = null,
    /// Fires only on the first visible content token; used to write the model prefix.
    on_first_content: ?*const fn (*anyopaque) void = null,
    on_first_content_ctx: ?*anyopaque = null,
};

/// Aggregates usage across every API round-trip inside one `send` (tool loops can
/// hit the API many times before returning).
pub const TurnUsage = struct {
    available: bool = false,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    total_tokens: u64 = 0,
    context_window_tokens: u64 = 0,
    context_used_tenths_pct: u16 = 0,
    context_left_tenths_pct: u16 = 1000,
};

/// Owns an arena allocator: all chat messages and duplicated strings live there so one
/// reset frees the entire transcript without per-message bookkeeping.
pub const Harness = struct {
    backing_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    messages: std.ArrayList(types.Message),
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
    mode: types.Mode,
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
            .mode = .plan,
            .system_text = plan_prompt,
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

    pub fn get_mode(self: *const Harness) types.Mode {
        return self.mode;
    }

    pub fn get_model(self: *const Harness) []const u8 {
        return self.model;
    }

    pub fn latest_usage(self: *const Harness) TurnUsage {
        return self.last_turn_usage;
    }

    pub fn messages_slice(
        self: *const Harness,
    ) []const types.Message {
        return self.messages.items;
    }

    pub fn set_mode(self: *Harness, mode: types.Mode) !void {
        self.mode = mode;
        try self.rebuild_system_text();
        try self.ensure_system_message();

        std.debug.assert(self.system_text.len > 0);
    }

    pub fn set_model(self: *Harness, model: []const u8) !void {
        std.debug.assert(model.len > 0);
        const a = self.arena.allocator();
        self.model = try a.dupe(u8, model);
    }

    pub fn load_conversation(
        self: *Harness,
        mode: types.Mode,
        model: []const u8,
        messages: []const types.Message,
    ) !void {
        try self.reset_state();

        const a = self.arena.allocator();
        self.mode = mode;
        try self.rebuild_system_text();
        self.model = try a.dupe(u8, model);

        for (messages) |m| {
            try self.messages.append(a, try types.clone(a, m));
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
            .role = .user,
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
                    self.mode,
                );
                try self.messages.append(a, .{
                    .role = .tool,
                    .content = output,
                    .tool_call_id = tc.id,
                });
            }

            // Separate tool-call stderr output from the next streamed response
            if (options.stream_output) |out| {
                try out.writeAll("\n");
            }
        }

        unreachable;
    }

    fn fetch_response(
        self: *Harness,
        a: std.mem.Allocator,
        options: SendOptions,
    ) !openrouter.Response {
        return openrouter.stream_message(
            a,
            self.messages.items,
            self.api_key,
            self.base_url,
            self.model,
            self.mode,
            options.stream_output,
            options.on_first_stream_delta,
            options.on_first_stream_delta_ctx,
            options.on_first_content,
            options.on_first_content_ctx,
        );
    }

    /// Heuristic per-vendor limits for context budgeting; OpenRouter does not return
    /// the true window in responses, so we approximate from the model id prefix.
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

    /// Expresses fill ratio as tenths of a percent (0–1000) so status math stays
    /// integer-only while still showing finer than whole-percent resolution.
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

    /// Drops the arena and starts a fresh one so loading or clearing a conversation
    /// reclaims all message memory in one shot instead of freeing each clone.
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

    /// Composes the mode-specific base prompt with any repository skills blurb so
    /// `system_text` always reflects the current mode and discovered SKILL.md files.
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

    /// Keeps `messages[0]` aligned with `system_text` so mode or skills changes apply
    /// on the very next request without stale system content in the transcript.
    fn ensure_system_message(self: *Harness) !void {
        if (self.system_text.len == 0) return;

        const a = self.arena.allocator();
        const content = try a.dupe(u8, self.system_text);

        if (self.messages.items.len == 0) {
            try self.messages.append(a, .{
                .role = .system,
                .content = content,
            });
            std.debug.assert(self.messages.items.len > 0);
            return;
        }

        if (self.messages.items[0].role != .system) {
            try self.messages.insert(a, 0, .{
                .role = .system,
                .content = content,
            });
            std.debug.assert(self.messages.items.len > 0);
            return;
        }

        self.messages.items[0].content = content;
    }
};
