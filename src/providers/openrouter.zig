/// OpenRouter chat provider: streaming completions only (no non-streaming
/// shortcut).
const std = @import("std");
const types = @import("../lib/types.zig");
const toolset = @import("../lib/toolset.zig");
const stream = @import("stream.zig");

pub const Usage = stream.Usage;
pub const Response = stream.Response;

/// POST JSON to `/chat/completions` with `stream: true`, feeding the response
/// body into `stream.StreamState` until `[DONE]` or an error payload.
pub fn stream_message(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
    mode: types.Mode,
    output_file: ?std.fs.File,
    on_first_stream_delta: ?*const fn (*anyopaque) void,
    on_first_stream_delta_ctx: ?*anyopaque,
    on_first_content: ?*const fn (*anyopaque) void,
    on_first_content_ctx: ?*anyopaque,
) !Response {
    std.debug.assert(api_key.len > 0);
    std.debug.assert(model.len > 0);

    var body_out = try build_request_body(
        allocator,
        messages,
        model,
        mode,
    );
    defer body_out.deinit();
    const body = body_out.written();

    const url_str = try build_chat_url(allocator, base_url);
    defer allocator.free(url_str);

    const auth = try build_auth_header(allocator, api_key);
    defer allocator.free(auth);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var state = stream.StreamState.init(
        allocator,
        output_file,
        on_first_stream_delta,
        on_first_stream_delta_ctx,
        on_first_content,
        on_first_content_ctx,
    );
    defer state.deinit();

    var sink = stream.StreamSink.init(&state);

    _ = client.fetch(.{
        .location = .{ .url = url_str },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth },
        },
        .response_writer = &sink.writer,
    }) catch |err| {
        if (err == error.WriteFailed) {
            if (state.failure) |f| return f;
        }
        return err;
    };

    if (state.error_message) |e| {
        std.debug.print("OpenRouter error: {s}\n", .{e});
        return error.ApiError;
    }

    return state.finish_response();
}

/// Request shape is fixed for augur: every turn opts into streaming and always
/// advertises tool definitions because the harness expects tool-capable replies.
fn build_request_body(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    model: []const u8,
    mode: types.Mode,
) !std.io.Writer.Allocating {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var jw: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };

    try jw.beginObject();

    try jw.objectField("model");
    try jw.write(model);

    try jw.objectField("stream");
    try jw.write(true);

    try jw.objectField("stream_options");
    try jw.beginObject();
    try jw.objectField("include_usage");
    try jw.write(true);
    try jw.endObject();

    try jw.objectField("messages");
    try jw.beginArray();
    for (messages) |m| {
        try jw.write(m);
    }
    try jw.endArray();

    try jw.objectField("tools");
    try jw.beginArray();
    try toolset.write_tool_definitions(&jw, mode);
    try jw.endArray();

    try jw.endObject();

    return out;
}

fn build_chat_url(
    allocator: std.mem.Allocator,
    base_url: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/chat/completions",
        .{base_url},
    );
}

fn build_auth_header(
    allocator: std.mem.Allocator,
    api_key: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Bearer {s}",
        .{api_key},
    );
}
