pub const Message = struct {
    role: []const u8,
    content: []const u8,
};

pub const Property = struct {
    type: []const u8,
    description: []const u8,
};

pub const ReadProperties = struct {
    file_path: Property,
};

pub const Parameters = struct {
    type: []const u8, // always "object"
    properties: ReadProperties,
    required: []const []const u8,
};

pub const Function = struct {
    name: []const u8,
    description: []const u8,
    parameters: Parameters,
};

pub const Tool = struct {
    type: []const u8, // always "function"
    function: Function,
};
