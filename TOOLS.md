# Augur Tools

This document describes the available tools in Augur. All tools are sandboxed to prevent access outside the current working directory.

## Core Tools

### `read`
Read and return the contents of a file.

**Parameters:**
- `file_path` (string, required): The path to the file to read

**Example:** Read a source file to understand its structure

### `write`
Write contents to a file, overwriting if it exists.

**Parameters:**
- `file_path` (string, required): The path to the file to write
- `content` (string, required): The content to write to the file

**Example:** Create or update a file with new code

### `bash`
Run a shell command and return stdout/stderr.

**Parameters:**
- `command` (string, required): The command to run

**Example:** Build the project, run tests, or execute arbitrary commands

## Navigation & Search Tools

### `find`
Search for files by name or pattern within a directory tree.

**Parameters:**
- `pattern` (string, required): Filename pattern to search for (glob or exact match)
- `path` (string, optional): Starting directory (default: current directory)
- `type` (string, optional): Filter by type: `'file'`, `'dir'`, or `'any'` (default: `any`)

**Example:** `find pattern="*.zig" path="src" type="file"` — Find all Zig source files in src/

### `grep`
Search for text patterns within files (recursive).

**Parameters:**
- `pattern` (string, required): Regular expression or literal text to search for
- `path` (string, required): File or directory to search in
- `context_lines` (integer, optional): Number of context lines to show (default: 0)

**Example:** `grep pattern="TODO" path="src" context_lines=2` — Find all TODOs with 2 lines of context

### `tree`
Show directory structure as a tree (with filtering for common ignored directories).

**Parameters:**
- `path` (string, optional): Root directory (default: current directory)
- `depth` (integer, optional): Maximum directory depth to show (default: 3)
- `ignore_patterns` (string, optional): Comma-separated patterns to ignore (default: `.git,node_modules,.zig-cache`)

**Example:** `tree path="src" depth=4` — Show src/ structure up to 4 levels deep

## Comparison & Version Control

### `diff`
Show differences between two files in unified diff format.

**Parameters:**
- `file1` (string, required): First file path
- `file2` (string, required): Second file path
- `context_lines` (integer, optional): Number of context lines (default: 3)

**Example:** `diff file1="old.zig" file2="new.zig" context_lines=5` — Compare two versions of a file

### `git`
Run git operations (log, status, diff, show).

**Parameters:**
- `operation` (string, required): Git operation: `'log'`, `'status'`, `'diff'`, or `'show'`
- `args` (string, optional): Additional arguments for the git command (default: `''`)

**Example:** `git operation="log" args="--oneline -10"` — Show last 10 commits
**Example:** `git operation="status"` — Show git status
**Example:** `git operation="diff" args="HEAD~1"` — Show differences from last commit

## Security Notes

All file tools are **sandboxed** to the current working directory:
- ❌ Absolute paths (starting with `/`) are rejected
- ❌ Path traversal (`..`) is rejected
- ✅ Relative paths are allowed

Shell commands via `bash` have standard terminal restrictions but can still access files within the working directory.

## Tool Usage Flow

A typical workflow:

1. **Explore**: Use `find`, `tree`, or `ls` to understand the codebase structure
2. **Search**: Use `grep` to locate specific code patterns
3. **Read**: Use `read` to examine relevant files
4. **Compare**: Use `diff` or `git diff` to review changes
5. **Modify**: Use `write` to make changes
6. **Verify**: Use `bash` to build, test, or validate
7. **Version**: Use `git` to commit changes and view history
