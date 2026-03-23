// Test root: re-exports all packages so `zig build test`
// discovers every inline test block via the import graph.
pub const lib = @import("lib/mod.zig");
pub const cli = @import("cli/mod.zig");
pub const providers = @import("providers/mod.zig");
