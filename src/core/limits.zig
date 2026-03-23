/// Hard upper bounds for all bounded resources.
///
/// Tiger Style mandates a limit on everything. Centralising
/// constants here keeps the rest of the codebase consistent and
/// makes it easy to audit every cap in one place.

/// Maximum number of CLI arguments accepted.
pub const max_args: u32 = 64;

/// Maximum bytes for a single user prompt.
pub const max_prompt_bytes: u32 = 1 * 1024 * 1024;

/// Maximum conversations stored at once.
pub const max_conversations: u32 = 256;

/// Maximum messages retained per conversation.
pub const max_messages_per_conversation: u32 = 4096;

/// Maximum attempts when generating a unique conversation name.
pub const max_conversation_name_attempts: u32 = 4096;

/// Maximum bytes read from the conversations JSON file.
pub const max_conversations_file_bytes: u32 = 32 * 1024 * 1024;

/// Maximum REPL iterations before the loop exits.
pub const max_repl_turns: u32 = 100_000;

/// Maximum spinner animation ticks (~6 min at 120 ms).
pub const max_spinner_ticks: u32 = 3_000;

/// Maximum bytes buffered during SSE streaming.
pub const max_stream_buffer_bytes: u32 = 8 * 1024 * 1024;

/// Maximum tool calls in a single assistant response.
pub const max_tool_calls: u32 = 64;

/// Maximum bytes captured from a tool subprocess.
pub const max_tool_output_bytes: u32 = 200 * 1024;

/// Maximum bytes read from a single file via the read tool.
pub const max_read_file_bytes: u32 = 10 * 1024 * 1024;

/// Maximum tool-call rounds before the harness gives up.
pub const max_tool_turns: u32 = 12;

/// Spinner frame delay in nanoseconds.
pub const spinner_frame_delay_ns: u64 = 120 * 1_000_000;
