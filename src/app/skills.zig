/// Discovery and prompt wiring for repository-local SKILLS files.
const std = @import("std");

/// Build a system-prompt suffix that advertises discovered skills.
///
/// Supported locations:
/// - `SKILLS.md`
/// - `SKILLS/*/SKILL.md`
/// - `.skills/*/SKILL.md`
pub fn load_system_suffix(
    allocator: std.mem.Allocator,
) ![]u8 {
    var skill_paths = std.ArrayList([]u8).empty;
    defer {
        for (skill_paths.items) |p| allocator.free(p);
        skill_paths.deinit(allocator);
    }

    const has_skills_md = file_exists("SKILLS.md");
    try collect_skill_files(
        allocator,
        &skill_paths,
        "SKILLS",
    );
    try collect_skill_files(
        allocator,
        &skill_paths,
        ".skills",
    );

    if (!has_skills_md and skill_paths.items.len == 0) {
        return allocator.alloc(u8, 0);
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var w = out.writer(allocator);

    try w.writeAll("Repository SKILLS support:\n");

    if (has_skills_md) {
        try w.writeAll(
            "- `SKILLS.md` found at repository root. Read it when relevant.\n",
        );
    }

    if (skill_paths.items.len > 0) {
        try w.writeAll("- Discovered skill files:\n");
        for (skill_paths.items) |path| {
            try w.print("  - `{s}`\n", .{path});
        }
    }

    try w.writeAll(
        "When the task matches a skill, read the matching " ++
            "`SKILL.md` before making changes. Resolve relative " ++
            "paths from the skill's directory.",
    );

    return out.toOwnedSlice(allocator);
}

fn collect_skill_files(
    allocator: std.mem.Allocator,
    paths: *std.ArrayList([]u8),
    base_dir: []const u8,
) !void {
    var dir = std.fs.cwd().openDir(
        base_dir,
        .{ .iterate = true },
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file => {
                if (!std.mem.eql(u8, entry.name, "SKILL.md")) {
                    continue;
                }
                const path = try std.fmt.allocPrint(
                    allocator,
                    "{s}/SKILL.md",
                    .{base_dir},
                );
                try paths.append(allocator, path);
            },
            .directory => {
                const path = try std.fmt.allocPrint(
                    allocator,
                    "{s}/{s}/SKILL.md",
                    .{ base_dir, entry.name },
                );
                errdefer allocator.free(path);

                if (!file_exists(path)) {
                    allocator.free(path);
                    continue;
                }
                try paths.append(allocator, path);
            },
            else => {},
        }
    }
}

fn file_exists(path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return false;
    };
    file.close();
    return true;
}
