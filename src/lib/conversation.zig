//! Persists named chat sessions to `augur/conversations.json` and keeps the harness
//! in sync when switching or creating conversations.  Each run creates a fresh
//! conversation named `<branch>-<N>` so every session starts with a clean context window.
const std = @import("std");
const types = @import("types.zig");
const harness = @import("harness.zig");

const max_conversations_file_bytes: u32 = 32 * 1024 * 1024;

/// Determine the current git branch from `.git/HEAD`.
/// Slashes in branch names become dashes for clean conversation names.
/// Returns "unknown" when git metadata is unreadable (not a repo, etc.).
fn detect_branch(allocator: std.mem.Allocator) ![]const u8 {
    const cwd = std.fs.cwd();
    const head_bytes = cwd.readFileAlloc(
        allocator,
        ".git/HEAD",
        4096,
    ) catch {
        return try allocator.dupe(u8, "unknown");
    };
    defer allocator.free(head_bytes);

    const trimmed = std.mem.trimRight(u8, head_bytes, "\r\n \t");
    const ref_prefix = "ref: refs/heads/";

    const raw = if (std.mem.startsWith(u8, trimmed, ref_prefix) and
        trimmed.len > ref_prefix.len)
        trimmed[ref_prefix.len..]
    else if (trimmed.len >= 8)
        trimmed[0..8]
    else
        "unknown";

    const result = try allocator.dupe(u8, raw);
    for (result) |*c| {
        if (c.* == '/') c.* = '-';
    }
    return result;
}

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

    /// Load conversation history from disk, returning an empty store when
    /// no file exists.  Pair with `new_branch_session` to start a clean run.
    pub fn load_history(
        allocator: std.mem.Allocator,
    ) !ConversationStore {
        const cwd = std.fs.cwd();
        try cwd.makePath(directory_path);

        const contents = cwd.readFileAlloc(
            allocator,
            file_path,
            max_conversations_file_bytes,
        ) catch |err| switch (err) {
            error.FileNotFound => return .{
                .allocator = allocator,
                .conversations = .empty,
                .active_index = 0,
            },
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

        if (parsed.value.conversations.len == 0) {
            return .{
                .allocator = allocator,
                .conversations = .empty,
                .active_index = 0,
            };
        }

        return from_snapshot(allocator, parsed.value);
    }

    fn from_snapshot(
        allocator: std.mem.Allocator,
        snapshot: ConversationsFile,
    ) !ConversationStore {
        if (snapshot.conversations.len == 0) {
            return .{
                .allocator = allocator,
                .conversations = .empty,
                .active_index = 0,
            };
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

    /// Auto-name using the current git branch: `<branch>-<N>`.
    fn generate_name(
        self: *const ConversationStore,
    ) ![]const u8 {
        const branch = try detect_branch(self.allocator);
        defer self.allocator.free(branch);

        const index = self.next_branch_index(branch);
        return try std.fmt.allocPrint(
            self.allocator,
            "{s}-{d}",
            .{ branch, index },
        );
    }

    /// Scan existing conversations for `<branch>-N` names and return the
    /// next unused index.
    fn next_branch_index(
        self: *const ConversationStore,
        branch: []const u8,
    ) u32 {
        var max_seen: ?u32 = null;
        for (self.conversations.items) |conv| {
            if (conv.name.len <= branch.len + 1) continue;
            if (!std.mem.startsWith(u8, conv.name, branch)) continue;
            if (conv.name[branch.len] != '-') continue;

            const suffix = conv.name[branch.len + 1 ..];
            const n = std.fmt.parseInt(u32, suffix, 10) catch continue;
            max_seen = if (max_seen) |m| @max(m, n) else n;
        }
        return if (max_seen) |m| m + 1 else 0;
    }

    /// Create a fresh `<branch>-<N>` conversation and make it active.
    /// Does not sync from the harness — use at startup for a guaranteed
    /// clean context window.
    pub fn new_branch_session(
        self: *ConversationStore,
        model: []const u8,
    ) ![]const u8 {
        const branch = try detect_branch(self.allocator);
        defer self.allocator.free(branch);

        const index = self.next_branch_index(branch);
        const name = try std.fmt.allocPrint(
            self.allocator,
            "{s}-{d}",
            .{ branch, index },
        );
        defer self.allocator.free(name);

        var conv = try Conversation.init(
            self.allocator,
            name,
            .plan,
            model,
        );
        errdefer conv.deinit(self.allocator);

        try self.conversations.append(self.allocator, conv);
        self.active_index = self.conversations.items.len - 1;

        return self.active_name();
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

test "next_branch_index returns 0 when no conversations exist" {
    var store = ConversationStore{
        .allocator = std.testing.allocator,
        .conversations = .empty,
        .active_index = 0,
    };
    defer store.deinit();

    try std.testing.expectEqual(@as(u32, 0), store.next_branch_index("main"));
}

test "next_branch_index increments past highest existing index" {
    const allocator = std.testing.allocator;
    var store = ConversationStore{
        .allocator = allocator,
        .conversations = .empty,
        .active_index = 0,
    };
    defer store.deinit();

    const c0 = try Conversation.init(allocator, "main-0", .plan, "m");
    try store.conversations.append(allocator, c0);
    const c1 = try Conversation.init(allocator, "main-2", .plan, "m");
    try store.conversations.append(allocator, c1);

    try std.testing.expectEqual(@as(u32, 3), store.next_branch_index("main"));
}

test "next_branch_index ignores other branches" {
    const allocator = std.testing.allocator;
    var store = ConversationStore{
        .allocator = allocator,
        .conversations = .empty,
        .active_index = 0,
    };
    defer store.deinit();

    const c0 = try Conversation.init(allocator, "feature-0", .plan, "m");
    try store.conversations.append(allocator, c0);

    try std.testing.expectEqual(@as(u32, 0), store.next_branch_index("main"));
}
