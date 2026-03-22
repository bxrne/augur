pub const ToolCallFunction = struct {
    name: []const u8,
    arguments: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8,
    function: ToolCallFunction,
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    tool_calls: ?[]ToolCall = null,
    tool_call_id: ?[]const u8 = null,
};
