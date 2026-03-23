//! Persists named chat sessions to `augur/conversations.json` and keeps the harness
//! in sync when switching or creating conversations.
const std = @import("std");
const types = @import("types.zig");
const harness = @import("harness.zig");

const max_conversation_name_attempts: u32 = 4096;
const max_conversations_file_bytes: u32 = 32 * 1024 * 1024;

/// One conversation's serialised shape in JSON: metadata plus a cloned message list.
const ConversationSnapshot = struct {
    name: []const u8,
    mode: types.Mode,
    model: []const u8,
    messages: []types.Message,
};

/// Top-level envelope written to disk: format version, active name, and all snapshots.
const ConversationsFile = struct {
    version: u32 = 1,
    active: []const u8,
    conversations: []ConversationSnapshot,
};

/// A single named session with its own mode, model, and message history (heap-owned).
pub const Conversation = struct {
    name: []const u8,
    mode: types.Mode,
    model: []const u8,
    messages: std.ArrayList(types.Message),

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        mode: types.Mode,
        model: []const u8,
    ) !Conversation {
        std.debug.assert(name.len > 0);
        std.debug.assert(model.len > 0);

        const result = Conversation{
            .name = try allocator.dupe(u8, name),
            .mode = mode,
            .model = try allocator.dupe(u8, model),
            .messages = std.ArrayList(types.Message).empty,
        };

        std.debug.assert(result.messages.items.len == 0);
        return result;
    }

    pub fn deinit(self: *Conversation, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.model);
        types.free_slice(allocator, self.messages.items);
        self.messages.deinit(allocator);
    }
};

pub const ConversationStore = struct {
    allocator: std.mem.Allocator,
    conversations: std.ArrayList(Conversation),
    active_index: usize,

    const directory_path = "augur";
    const file_path = "augur/conversations.json";

    /// Create a store with a single "default" conversation.
    pub fn init_default(
        allocator: std.mem.Allocator,
    ) !ConversationStore {
        var conversations = std.ArrayList(Conversation).empty;
        errdefer conversations.deinit(allocator);

        var default = try Conversation.init(
            allocator,
            "default",
            .plan,
            harness.default_model,
        );
        errdefer default.deinit(allocator);

        try conversations.append(allocator, default);

        const store = ConversationStore{
            .allocator = allocator,
            .conversations = conversations,
            .active_index = 0,
        };
        std.debug.assert(store.conversations.items.len > 0);
        return store;
    }

    /// Load from disk, falling back to a default store.
    pub fn load_or_init(
        allocator: std.mem.Allocator,
    ) !ConversationStore {
        const cwd = std.fs.cwd();
        try cwd.makePath(directory_path);

        const contents = cwd.readFileAlloc(
            allocator,
            file_path,
            max_conversations_file_bytes,
        ) catch |err| switch (err) {
            error.FileNotFound => return init_default(allocator),
            else => return err,
        };
        defer allocator.free(contents);

        const parsed = try std.json.parseFromSlice(
            ConversationsFile,
            allocator,
            contents,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        return from_snapshot(allocator, parsed.value);
    }

    fn from_snapshot(
        allocator: std.mem.Allocator,
        snapshot: ConversationsFile,
    ) !ConversationStore {
        if (snapshot.conversations.len == 0) {
            return init_default(allocator);
        }

        var store = ConversationStore{
            .allocator = allocator,
            .conversations = std.ArrayList(Conversation).empty,
            .active_index = 0,
        };
        errdefer store.deinit();

        for (snapshot.conversations) |snap| {
            var conv = try Conversation.init(
                allocator,
                snap.name,
                snap.mode,
                snap.model,
            );
            errdefer conv.deinit(allocator);

            for (snap.messages) |m| {
                try conv.messages.append(
                    allocator,
                    try types.clone(allocator, m),
                );
            }

            try store.conversations.append(allocator, conv);
        }

        if (snapshot.active.len > 0) {
            if (store.find_index_by_name(snapshot.active)) |idx| {
                store.active_index = idx;
            }
        }

        std.debug.assert(store.conversations.items.len > 0);
        std.debug.assert(
            store.active_index < store.conversations.items.len,
        );
        return store;
    }

    pub fn deinit(self: *ConversationStore) void {
        for (self.conversations.items) |*conv| {
            conv.deinit(self.allocator);
        }
        self.conversations.deinit(self.allocator);
    }

    /// Persist all conversations to disk.
    pub fn save(self: *const ConversationStore) !void {
        std.debug.assert(self.conversations.items.len > 0);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();

        const snapshot = try self.to_snapshot(scratch);

        const cwd = std.fs.cwd();
        try cwd.makePath(directory_path);

        var file = try cwd.createFile(
            file_path,
            .{ .truncate = true },
        );
        defer file.close();

        var fw = file.writer(&.{});
        var jw: std.json.Stringify = .{
            .writer = &fw.interface,
            .options = .{
                .emit_null_optional_fields = false,
            },
        };
        try jw.write(snapshot);
    }

    fn to_snapshot(
        self: *const ConversationStore,
        allocator: std.mem.Allocator,
    ) !ConversationsFile {
        const convs = try allocator.alloc(
            ConversationSnapshot,
            self.conversations.items.len,
        );

        for (self.conversations.items, 0..) |conv, i| {
            const msgs = try allocator.alloc(
                types.Message,
                conv.messages.items.len,
            );
            for (conv.messages.items, 0..) |m, j| {
                msgs[j] = try types.clone(allocator, m);
            }

            convs[i] = .{
                .name = try allocator.dupe(u8, conv.name),
                .mode = conv.mode,
                .model = try allocator.dupe(u8, conv.model),
                .messages = msgs,
            };
        }

        return .{
            .version = 1,
            .active = try allocator.dupe(
                u8,
                self.active_name(),
            ),
            .conversations = convs,
        };
    }

    pub fn active_name(self: *const ConversationStore) []const u8 {
        std.debug.assert(
            self.active_index < self.conversations.items.len,
        );
        return self.conversations.items[self.active_index].name;
    }

    pub fn active_conversation(
        self: *ConversationStore,
    ) *Conversation {
        std.debug.assert(
            self.active_index < self.conversations.items.len,
        );
        return &self.conversations.items[self.active_index];
    }

    /// Push the active conversation's state into the harness.
    pub fn apply_active(
        self: *ConversationStore,
        session: *harness.Harness,
    ) !void {
        const active = self.active_conversation();
        try session.load_conversation(
            active.mode,
            active.model,
            active.messages.items,
        );
    }

    /// Pull the harness state back into the active conversation.
    pub fn sync_active_from_session(
        self: *ConversationStore,
        session: *const harness.Harness,
    ) !void {
        const active = self.active_conversation();
        active.mode = session.get_mode();
        try types.replace_owned_string(
            self.allocator,
            &active.model,
            session.get_model(),
        );
        try types.replace_list(
            self.allocator,
            &active.messages,
            session.messages_slice(),
        );
    }

    /// Switch to a named conversation, returning false if not found.
    pub fn switch_conversation(
        self: *ConversationStore,
        session: *harness.Harness,
        name: []const u8,
    ) !bool {
        try self.sync_active_from_session(session);
        const idx = self.find_index_by_name(name) orelse {
            return false;
        };

        self.active_index = idx;
        std.debug.assert(
            self.active_index < self.conversations.items.len,
        );
        try self.apply_active(session);
        return true;
    }

    /// Create a new conversation and switch to it.
    pub fn create_and_switch(
        self: *ConversationStore,
        session: *harness.Harness,
        requested_name: ?[]const u8,
    ) ![]const u8 {
        try self.sync_active_from_session(session);

        const name = if (requested_name) |n|
            try self.allocator.dupe(u8, n)
        else
            try self.generate_name();
        defer self.allocator.free(name);

        if (self.find_index_by_name(name) != null) {
            return error.ConversationAlreadyExists;
        }

        var conv = try Conversation.init(
            self.allocator,
            name,
            .plan,
            session.get_model(),
        );
        errdefer conv.deinit(self.allocator);

        try self.conversations.append(self.allocator, conv);
        self.active_index = self.conversations.items.len - 1;

        std.debug.assert(
            self.active_index < self.conversations.items.len,
        );
        try self.apply_active(session);
        return self.active_name();
    }

    /// Picks `chat-{n}` starting from `len+1`, bumping `n` until unused so auto names
    /// never collide with existing conversations.
    fn generate_name(
        self: *const ConversationStore,
    ) ![]const u8 {
        var suffix: u32 = @intCast(
            self.conversations.items.len + 1,
        );
        var attempt: u32 = 0;

        while (attempt < max_conversation_name_attempts) {
            const name = try std.fmt.allocPrint(
                self.allocator,
                "chat-{d}",
                .{suffix},
            );
            if (self.find_index_by_name(name) == null) {
                return name;
            }
            self.allocator.free(name);
            suffix += 1;
            attempt += 1;
        }

        return error.ConversationNameExhausted;
    }

    fn find_index_by_name(
        self: *const ConversationStore,
        name: []const u8,
    ) ?usize {
        for (self.conversations.items, 0..) |conv, i| {
            if (std.mem.eql(u8, conv.name, name)) {
                return i;
            }
        }
        return null;
    }
};

/// Counts user/assistant/tool turns for status UI; omits system because that slot is
/// synthetic and not part of the conversational back-and-forth the user cares about.
pub fn context_message_count(
    messages: []const types.Message,
) usize {
    var count: usize = 0;
    for (messages) |m| {
        if (m.role != .system) {
            count += 1;
        }
    }
    std.debug.assert(count <= messages.len);
    return count;
}

test "context_message_count skips system messages" {
    const messages = [_]types.Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "hi" },
        .{ .role = .assistant, .content = "hello" },
    };
    try std.testing.expectEqual(@as(usize, 2), context_message_count(&messages));
}

test "context_message_count empty slice" {
    const messages = [_]types.Message{};
    try std.testing.expectEqual(@as(usize, 0), context_message_count(&messages));
}

test "Conversation init and deinit" {
    const allocator = std.testing.allocator;
    var conv = try Conversation.init(allocator, "test", .plan, "model-1");
    defer conv.deinit(allocator);

    try std.testing.expectEqualStrings("test", conv.name);
    try std.testing.expectEqual(types.Mode.plan, conv.mode);
    try std.testing.expectEqualStrings("model-1", conv.model);
    try std.testing.expectEqual(@as(usize, 0), conv.messages.items.len);
}

test "ConversationStore init_default" {
    const allocator = std.testing.allocator;
    var store = try ConversationStore.init_default(allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 1), store.conversations.items.len);
    try std.testing.expectEqualStrings("default", store.active_name());
}
