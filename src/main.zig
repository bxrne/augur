const std = @import("std");
const harness = @import("harness.zig");
const types = @import("types.zig");

const Ansi = struct {
    const reset = "\x1b[0m";
    const prompt = "\x1b[1;36m";
    const assistant = "\x1b[1;32m";
    const spinner = "\x1b[1;33m";
    const status = "\x1b[1;35m";
    const label = "\x1b[1;37m";
    const border = "\x1b[38;5;244m";
    const dim = "\x1b[2m";
    const mode_plan = "\x1b[1;34m";
    const mode_build = "\x1b[1;32m";
};

const CliOptions = struct {
    prompt: ?[]const u8 = null,
    streaming: bool = true,
};

const ConversationSnapshot = struct {
    name: []const u8,
    mode: harness.Mode,
    model: []const u8,
    messages: []types.Message,
};

const ConversationsFile = struct {
    version: u32 = 1,
    active: []const u8,
    conversations: []ConversationSnapshot,
};

const Conversation = struct {
    name: []const u8,
    mode: harness.Mode,
    model: []const u8,
    messages: std.ArrayList(types.Message),

    fn init(allocator: std.mem.Allocator, name: []const u8, mode: harness.Mode, model: []const u8) !Conversation {
        return .{
            .name = try allocator.dupe(u8, name),
            .mode = mode,
            .model = try allocator.dupe(u8, model),
            .messages = std.ArrayList(types.Message).empty,
        };
    }

    fn deinit(self: *Conversation, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.model);
        freeMessageSlice(allocator, self.messages.items);
        self.messages.deinit(allocator);
    }
};

const ConversationStore = struct {
    allocator: std.mem.Allocator,
    conversations: std.ArrayList(Conversation),
    active_index: usize,

    const directory_path = "zip";
    const file_path = "zip/conversations.json";
    const max_file_size = 32 * 1024 * 1024;

    fn initDefault(allocator: std.mem.Allocator) !ConversationStore {
        var conversations = std.ArrayList(Conversation).empty;
        errdefer conversations.deinit(allocator);

        var default_conversation = try Conversation.init(allocator, "default", .plan, harness.default_model);
        errdefer default_conversation.deinit(allocator);

        try conversations.append(allocator, default_conversation);

        return .{
            .allocator = allocator,
            .conversations = conversations,
            .active_index = 0,
        };
    }

    fn loadOrInit(allocator: std.mem.Allocator) !ConversationStore {
        const cwd = std.fs.cwd();
        try cwd.makePath(directory_path);

        const file_contents = cwd.readFileAlloc(allocator, file_path, max_file_size) catch |err| switch (err) {
            error.FileNotFound => return initDefault(allocator),
            else => return err,
        };
        defer allocator.free(file_contents);

        const parsed = try std.json.parseFromSlice(ConversationsFile, allocator, file_contents, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        return fromSnapshot(allocator, parsed.value);
    }

    fn fromSnapshot(allocator: std.mem.Allocator, snapshot: ConversationsFile) !ConversationStore {
        if (snapshot.conversations.len == 0) {
            return initDefault(allocator);
        }

        var store = ConversationStore{
            .allocator = allocator,
            .conversations = std.ArrayList(Conversation).empty,
            .active_index = 0,
        };
        errdefer store.deinit();

        for (snapshot.conversations) |conversation_snapshot| {
            var conversation = try Conversation.init(
                allocator,
                conversation_snapshot.name,
                conversation_snapshot.mode,
                conversation_snapshot.model,
            );
            errdefer conversation.deinit(allocator);

            for (conversation_snapshot.messages) |message| {
                try conversation.messages.append(allocator, try cloneMessage(allocator, message));
            }

            try store.conversations.append(allocator, conversation);
        }

        if (snapshot.active.len > 0) {
            if (store.findIndexByName(snapshot.active)) |idx| {
                store.active_index = idx;
            }
        }

        return store;
    }

    fn deinit(self: *ConversationStore) void {
        for (self.conversations.items) |*conversation| {
            conversation.deinit(self.allocator);
        }
        self.conversations.deinit(self.allocator);
    }

    fn save(self: *const ConversationStore) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();

        const snapshot = try self.toSnapshot(scratch);

        const cwd = std.fs.cwd();
        try cwd.makePath(directory_path);

        var file = try cwd.createFile(file_path, .{ .truncate = true });
        defer file.close();

        var file_writer = file.writer(&.{});
        var json_writer: std.json.Stringify = .{
            .writer = &file_writer.interface,
            .options = .{ .emit_null_optional_fields = false },
        };
        try json_writer.write(snapshot);
    }

    fn toSnapshot(self: *const ConversationStore, allocator: std.mem.Allocator) !ConversationsFile {
        const conversations = try allocator.alloc(ConversationSnapshot, self.conversations.items.len);

        for (self.conversations.items, 0..) |conversation, idx| {
            const messages = try allocator.alloc(types.Message, conversation.messages.items.len);
            for (conversation.messages.items, 0..) |message, message_idx| {
                messages[message_idx] = try cloneMessage(allocator, message);
            }

            conversations[idx] = .{
                .name = try allocator.dupe(u8, conversation.name),
                .mode = conversation.mode,
                .model = try allocator.dupe(u8, conversation.model),
                .messages = messages,
            };
        }

        return .{
            .version = 1,
            .active = try allocator.dupe(u8, self.activeName()),
            .conversations = conversations,
        };
    }

    fn activeName(self: *const ConversationStore) []const u8 {
        return self.conversations.items[self.active_index].name;
    }

    fn applyActive(self: *ConversationStore, session: *harness.Harness) !void {
        const active = &self.conversations.items[self.active_index];
        try session.loadConversation(active.mode, active.model, active.messages.items);
    }

    fn syncActiveFromSession(self: *ConversationStore, session: *const harness.Harness) !void {
        const active = &self.conversations.items[self.active_index];
        active.mode = session.getMode();
        try replaceOwnedString(self.allocator, &active.model, session.getModel());
        try replaceMessageList(self.allocator, &active.messages, session.messagesSlice());
    }

    fn switchConversation(self: *ConversationStore, session: *harness.Harness, name: []const u8) !bool {
        try self.syncActiveFromSession(session);
        const idx = self.findIndexByName(name) orelse return false;

        self.active_index = idx;
        try self.applyActive(session);
        return true;
    }

    fn createConversationAndSwitch(self: *ConversationStore, session: *harness.Harness, requested_name: ?[]const u8) ![]const u8 {
        try self.syncActiveFromSession(session);

        const maybe_name = requested_name orelse try self.generateConversationName();
        const should_free_generated = requested_name == null;
        defer if (should_free_generated) self.allocator.free(maybe_name);

        if (self.findIndexByName(maybe_name) != null) {
            return error.ConversationAlreadyExists;
        }

        var conversation = try Conversation.init(self.allocator, maybe_name, .plan, session.getModel());
        errdefer conversation.deinit(self.allocator);

        try self.conversations.append(self.allocator, conversation);
        self.active_index = self.conversations.items.len - 1;

        try self.applyActive(session);
        return self.activeName();
    }

    fn generateConversationName(self: *const ConversationStore) ![]const u8 {
        var suffix: usize = self.conversations.items.len + 1;
        while (true) : (suffix += 1) {
            const name = try std.fmt.allocPrint(self.allocator, "chat-{d}", .{suffix});
            if (self.findIndexByName(name) == null) {
                return name;
            }
            self.allocator.free(name);
        }
    }

    fn findIndexByName(self: *const ConversationStore, name: []const u8) ?usize {
        for (self.conversations.items, 0..) |conversation, idx| {
            if (std.mem.eql(u8, conversation.name, name)) {
                return idx;
            }
        }
        return null;
    }
};

const Spinner = struct {
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    stdout: std.fs.File = undefined,
    message: []const u8 = "",
    use_color: bool = false,
    active: bool = false,

    pub fn start(self: *Spinner, stdout: std.fs.File, message: []const u8, use_color: bool) !void {
        self.stop_flag = std.atomic.Value(bool).init(false);
        self.stdout = stdout;
        self.message = message;
        self.use_color = use_color;
        self.active = true;
        self.thread = try std.Thread.spawn(.{}, spinnerLoop, .{self});
    }

    pub fn stop(self: *Spinner) void {
        if (!self.active) return;
        self.stop_flag.store(true, .release);
        if (self.thread) |thread| {
            thread.join();
        }
        _ = self.stdout.writeAll("\r\x1b[2K") catch {};
        self.active = false;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const api_key = std.posix.getenv("OPENROUTER_API_KEY") orelse @panic("OPENROUTER_API_KEY is not set");
    const base_url = std.posix.getenv("OPENROUTER_BASE_URL") orelse "https://openrouter.ai/api/v1";

    var session = harness.Harness.init(allocator, api_key, base_url);
    defer session.deinit();

    const options = try parseArgs(args);
    const stdout_file = std.fs.File.stdout();
    const is_tty = stdout_file.isTty();
    const use_color = is_tty;

    if (options.prompt) |prompt| {
        try runPrompt(&session, prompt, stdout_file, is_tty, use_color, options.streaming, false);
        return;
    }

    try runRepl(allocator, &session, stdout_file, is_tty, use_color, options.streaming);
}

fn parseArgs(args: []const [:0]u8) !CliOptions {
    var options = CliOptions{};
    var idx: usize = 1;

    while (idx < args.len) : (idx += 1) {
        const arg = std.mem.sliceTo(args[idx], 0);
        if (std.mem.eql(u8, arg, "-p")) {
            if (idx + 1 >= args.len) return error.MissingPrompt;
            options.prompt = std.mem.sliceTo(args[idx + 1], 0);
            idx += 1;
        } else if (std.mem.eql(u8, arg, "--stream")) {
            options.streaming = true;
        } else if (std.mem.eql(u8, arg, "--no-stream")) {
            options.streaming = false;
        }
    }

    return options;
}

fn runRepl(
    allocator: std.mem.Allocator,
    session: *harness.Harness,
    stdout_file: std.fs.File,
    is_tty: bool,
    use_color: bool,
    streaming: bool,
) !void {
    const stdin = std.fs.File.stdin().deprecatedReader();

    var store = try ConversationStore.loadOrInit(allocator);
    defer store.deinit();

    try store.applyActive(session);

    // REPL sessions always start in planning mode.
    try session.setMode(.plan);
    try store.syncActiveFromSession(session);
    try store.save();

    try writeReplHeader(stdout_file, use_color, session, store.activeName(), streaming);

    while (true) {
        try writePrompt(stdout_file, use_color, session.getMode());
        const line_opt = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024 * 1024);
        if (line_opt == null) {
            break;
        }
        const line = line_opt.?;
        defer allocator.free(line);

        const trimmed = std.mem.trimRight(u8, line, "\r\n");
        if (trimmed.len == 0) {
            continue;
        }

        if (trimmed[0] == '/') {
            switch (try handleSlashCommand(&store, session, trimmed, stdout_file, use_color)) {
                .handled => {
                    try store.syncActiveFromSession(session);
                    try store.save();
                    continue;
                },
                .quit => break,
            }
        }

        try runPrompt(session, trimmed, stdout_file, is_tty, use_color, streaming, true);
        try store.syncActiveFromSession(session);
        try store.save();
    }
}

fn runPrompt(
    session: *harness.Harness,
    prompt: []const u8,
    stdout_file: std.fs.File,
    is_tty: bool,
    use_color: bool,
    streaming: bool,
    show_prefix: bool,
) !void {
    if (streaming) {
        if (show_prefix) {
            try writeAssistantPrefix(stdout_file, use_color);
        }
        _ = try session.send(prompt, .{ .streaming = true, .stream_output = stdout_file });
        if (show_prefix) {
            try stdout_file.writeAll("\n");
        }
        return;
    }

    var spinner: Spinner = undefined;
    var spinner_active = false;
    if (is_tty) {
        const phrase = pickStatusPhrase();
        try spinner.start(stdout_file, phrase, use_color);
        spinner_active = true;
    }

    const response = session.send(prompt, .{}) catch |err| {
        if (spinner_active) spinner.stop();
        return err;
    };

    if (spinner_active) spinner.stop();

    if (show_prefix) {
        try writeAssistantPrefix(stdout_file, use_color);
    }
    try stdout_file.writeAll(response);
    if (show_prefix) {
        try stdout_file.writeAll("\n");
    }
}

const SlashCommandResult = enum {
    handled,
    quit,
};

fn handleSlashCommand(
    store: *ConversationStore,
    session: *harness.Harness,
    line: []const u8,
    stdout_file: std.fs.File,
    use_color: bool,
) !SlashCommandResult {
    if (line.len == 0 or line[0] != '/') return .handled;

    var iter = std.mem.tokenizeScalar(u8, line[1..], ' ');
    const cmd = iter.next() orelse {
        try writeStatusLine(stdout_file, use_color, "Commands: /plan /build /model /new /switch /convos /quit /help");
        return .handled;
    };

    if (std.mem.eql(u8, cmd, "plan")) {
        try session.setMode(.plan);
        try writeStatusLine(stdout_file, use_color, "Mode set to plan.");
        return .handled;
    }

    if (std.mem.eql(u8, cmd, "build")) {
        try session.setMode(.build);
        try writeStatusLine(stdout_file, use_color, "Mode set to build.");
        return .handled;
    }

    if (std.mem.eql(u8, cmd, "model")) {
        if (iter.next()) |model| {
            try session.setModel(model);
            var buffer: [256]u8 = undefined;
            const line_out = try std.fmt.bufPrint(&buffer, "Model set to {s}.", .{model});
            try writeStatusLine(stdout_file, use_color, line_out);
        } else {
            var buffer: [256]u8 = undefined;
            const line_out = try std.fmt.bufPrint(&buffer, "Current model: {s}", .{session.getModel()});
            try writeStatusLine(stdout_file, use_color, line_out);
        }
        return .handled;
    }

    if (std.mem.eql(u8, cmd, "new")) {
        const requested_name = iter.next();
        const conversation_name = store.createConversationAndSwitch(session, requested_name) catch |err| {
            if (err == error.ConversationAlreadyExists) {
                try writeStatusLine(stdout_file, use_color, "Conversation already exists. Use /switch <name>.");
                return .handled;
            }
            return err;
        };

        var buffer: [256]u8 = undefined;
        const line_out = try std.fmt.bufPrint(&buffer, "Switched to new conversation: {s}", .{conversation_name});
        try writeStatusLine(stdout_file, use_color, line_out);
        return .handled;
    }

    if (std.mem.eql(u8, cmd, "switch")) {
        const conversation_name = iter.next() orelse {
            try writeStatusLine(stdout_file, use_color, "Usage: /switch <name>");
            return .handled;
        };

        const switched = try store.switchConversation(session, conversation_name);
        if (!switched) {
            try writeStatusLine(stdout_file, use_color, "Conversation not found. Try /convos.");
            return .handled;
        }

        var buffer: [256]u8 = undefined;
        const line_out = try std.fmt.bufPrint(&buffer, "Switched to conversation: {s}", .{store.activeName()});
        try writeStatusLine(stdout_file, use_color, line_out);
        return .handled;
    }

    if (std.mem.eql(u8, cmd, "convos")) {
        try writeStatusLine(stdout_file, use_color, "Conversations:");
        for (store.conversations.items, 0..) |conversation, idx| {
            var buffer: [512]u8 = undefined;
            const marker = if (idx == store.active_index) "*" else " ";
            const line_out = try std.fmt.bufPrint(
                &buffer,
                " {s} {s} (mode={s}, model={s}, messages={d})",
                .{ marker, conversation.name, harness.modeLabel(conversation.mode), conversation.model, conversation.messages.items.len },
            );
            try writeStatusLine(stdout_file, use_color, line_out);
        }
        return .handled;
    }

    if (std.mem.eql(u8, cmd, "quit")) {
        return .quit;
    }

    if (std.mem.eql(u8, cmd, "help")) {
        try writeStatusLine(stdout_file, use_color, "Slash commands:");
        try writeStatusLine(stdout_file, use_color, "  /plan          - planning mode (no code)");
        try writeStatusLine(stdout_file, use_color, "  /build         - build mode (implementation)");
        try writeStatusLine(stdout_file, use_color, "  /model         - show current OpenRouter model");
        try writeStatusLine(stdout_file, use_color, "  /model <id>    - switch OpenRouter model");
        try writeStatusLine(stdout_file, use_color, "  /new [name]    - create + switch conversation");
        try writeStatusLine(stdout_file, use_color, "  /switch <name> - switch conversation");
        try writeStatusLine(stdout_file, use_color, "  /convos        - list conversations");
        try writeStatusLine(stdout_file, use_color, "  /quit          - leave the REPL");
        return .handled;
    }

    var buffer: [256]u8 = undefined;
    const line_out = try std.fmt.bufPrint(&buffer, "Unknown command: /{s}. Try /help.", .{cmd});
    try writeStatusLine(stdout_file, use_color, line_out);
    return .handled;
}

fn writeStatusLine(stdout_file: std.fs.File, use_color: bool, message: []const u8) !void {
    if (use_color) {
        try stdout_file.writeAll(Ansi.status);
    }
    try stdout_file.writeAll(message);
    if (use_color) {
        try stdout_file.writeAll(Ansi.reset);
    }
    try stdout_file.writeAll("\n");
}

fn writeReplHeader(
    stdout_file: std.fs.File,
    use_color: bool,
    session: *const harness.Harness,
    active_conversation: []const u8,
    streaming: bool,
) !void {
    if (use_color) {
        try stdout_file.writeAll(Ansi.border);
    }
    try stdout_file.writeAll("zip • convo=");
    if (use_color) {
        try stdout_file.writeAll(Ansi.label);
    }
    try stdout_file.writeAll(active_conversation);
    if (use_color) {
        try stdout_file.writeAll(Ansi.border);
    }
    try stdout_file.writeAll(" • mode=");
    if (use_color) {
        try stdout_file.writeAll(modeColor(session.getMode()));
    }
    try stdout_file.writeAll(harness.modeLabel(session.getMode()));
    if (use_color) {
        try stdout_file.writeAll(Ansi.border);
    }
    try stdout_file.writeAll(" • model=");
    if (use_color) {
        try stdout_file.writeAll(Ansi.label);
    }
    try stdout_file.writeAll(session.getModel());
    if (use_color) {
        try stdout_file.writeAll(Ansi.border);
    }
    try stdout_file.writeAll(" • streaming=");
    if (use_color) {
        try stdout_file.writeAll(Ansi.label);
    }
    try stdout_file.writeAll(if (streaming) "on" else "off");
    if (use_color) {
        try stdout_file.writeAll(Ansi.border);
    }
    try stdout_file.writeAll(" • /help • /quit\n\n");
    if (use_color) {
        try stdout_file.writeAll(Ansi.reset);
    }
}

fn writeHeaderField(
    stdout_file: std.fs.File,
    use_color: bool,
    label: []const u8,
    value: []const u8,
    mode_opt: ?harness.Mode,
) !void {
    if (use_color) {
        try stdout_file.writeAll(Ansi.border);
    }
    try stdout_file.writeAll("│ ");
    if (use_color) {
        try stdout_file.writeAll(Ansi.dim);
    }
    try stdout_file.writeAll(label);
    try stdout_file.writeAll(": ");
    if (use_color) {
        try stdout_file.writeAll(Ansi.reset);
        if (mode_opt) |mode| {
            try stdout_file.writeAll(modeColor(mode));
        } else {
            try stdout_file.writeAll(Ansi.label);
        }
    }
    try stdout_file.writeAll(value);
    if (use_color) {
        try stdout_file.writeAll(Ansi.border);
    }
    try stdout_file.writeAll("\n");
}

fn modeColor(mode: harness.Mode) []const u8 {
    return switch (mode) {
        .plan => Ansi.mode_plan,
        .build => Ansi.mode_build,
    };
}

fn writePrompt(stdout_file: std.fs.File, use_color: bool, mode: harness.Mode) !void {
    if (use_color) {
        try stdout_file.writeAll(modeColor(mode));
    }
    try stdout_file.writeAll(harness.modeLabel(mode));
    if (use_color) {
        try stdout_file.writeAll(Ansi.prompt);
    }
    try stdout_file.writeAll("> ");
    if (use_color) {
        try stdout_file.writeAll(Ansi.reset);
    }
}

fn writeAssistantPrefix(stdout_file: std.fs.File, use_color: bool) !void {
    if (use_color) {
        try stdout_file.writeAll(Ansi.assistant);
    }
    try stdout_file.writeAll("> ");
    if (use_color) {
        try stdout_file.writeAll(Ansi.reset);
    }
}

fn cloneMessage(allocator: std.mem.Allocator, message: types.Message) !types.Message {
    var cloned = types.Message{
        .role = try allocator.dupe(u8, message.role),
        .content = try allocator.dupe(u8, message.content),
        .tool_calls = null,
        .tool_call_id = null,
    };

    if (message.tool_call_id) |tool_call_id| {
        cloned.tool_call_id = try allocator.dupe(u8, tool_call_id);
    }

    if (message.tool_calls) |tool_calls| {
        const cloned_tool_calls = try allocator.alloc(types.ToolCall, tool_calls.len);
        for (tool_calls, 0..) |tool_call, idx| {
            cloned_tool_calls[idx] = .{
                .id = try allocator.dupe(u8, tool_call.id),
                .type = try allocator.dupe(u8, tool_call.type),
                .function = .{
                    .name = try allocator.dupe(u8, tool_call.function.name),
                    .arguments = try allocator.dupe(u8, tool_call.function.arguments),
                },
            };
        }
        cloned.tool_calls = cloned_tool_calls;
    }

    return cloned;
}

fn freeMessage(allocator: std.mem.Allocator, message: *const types.Message) void {
    allocator.free(message.role);
    allocator.free(message.content);

    if (message.tool_call_id) |tool_call_id| {
        allocator.free(tool_call_id);
    }

    if (message.tool_calls) |tool_calls| {
        for (tool_calls) |tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.type);
            allocator.free(tool_call.function.name);
            allocator.free(tool_call.function.arguments);
        }
        allocator.free(tool_calls);
    }
}

fn freeMessageSlice(allocator: std.mem.Allocator, messages: []const types.Message) void {
    for (messages) |*message| {
        freeMessage(allocator, message);
    }
}

fn replaceOwnedString(allocator: std.mem.Allocator, slot: *[]const u8, value: []const u8) !void {
    const duplicated = try allocator.dupe(u8, value);
    allocator.free(slot.*);
    slot.* = duplicated;
}

fn replaceMessageList(
    allocator: std.mem.Allocator,
    target: *std.ArrayList(types.Message),
    source: []const types.Message,
) !void {
    var next = std.ArrayList(types.Message).empty;
    errdefer {
        freeMessageSlice(allocator, next.items);
        next.deinit(allocator);
    }

    for (source) |message| {
        try next.append(allocator, try cloneMessage(allocator, message));
    }

    freeMessageSlice(allocator, target.items);
    target.deinit(allocator);
    target.* = next;
}

fn pickStatusPhrase() []const u8 {
    const phrases = [_][]const u8{
        "compiling response",
        "building reply",
        "shipping bytes",
        "warming the model",
        "linking thoughts",
    };
    const now = std.time.nanoTimestamp();
    const positive = if (now < 0) -now else now;
    const idx = @as(usize, @intCast(@mod(positive, @as(i128, phrases.len))));
    return phrases[idx];
}

fn spinnerLoop(spinner: *Spinner) void {
    const frames = [_][]const u8{ "|", "/", "-", "\\" };
    var frame_index: usize = 0;

    while (!spinner.stop_flag.load(.acquire)) {
        _ = spinner.stdout.writeAll("\r\x1b[2K") catch {};
        if (spinner.use_color) {
            _ = spinner.stdout.writeAll(Ansi.spinner) catch {};
        }
        _ = spinner.stdout.writeAll(frames[frame_index]) catch {};
        _ = spinner.stdout.writeAll(" ") catch {};
        _ = spinner.stdout.writeAll(spinner.message) catch {};
        if (spinner.use_color) {
            _ = spinner.stdout.writeAll(Ansi.reset) catch {};
        }
        _ = spinner.stdout.writeAll("...") catch {};

        frame_index = (frame_index + 1) % frames.len;
        std.Thread.sleep(120 * std.time.ns_per_ms);
    }
}
