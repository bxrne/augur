# Augur Tools

This document describes the available tools in Augur. All tools are sandboxed to prevent access outside the current working directory and protected against `.env` file access.

## Tool Access by Mode

**PLAN Mode:**
- `read` — Read files only
- `tree` — View directory structure

**PAIR Mode:**
- `read` — Read files
- `bash` — Run shell commands (allowlisted commands only)
- `find` — Search for files by name/pattern
- `grep` — Search text patterns in files
- `diff` — Compare two files

**BUILD Mode:**
- All tools available: `read`, `write`, `bash`, `find`, `grep`, `tree`, `diff`, `git`

## Core Tools

### `read`
Read and return the contents of a file.

**Parameters:**
- `file_path` (string, required): The path to the file to read

**Example:** Read a source file to understand its structure

**Restrictions:** Cannot read `.env` files

### `write`
Write contents to a file, overwriting if it exists. *(BUILD mode only)*

**Parameters:**
- `file_path` (string, required): The path to the file to write
- `content` (string, required): The content to write to the file

**Example:** Create or update a file with new code

**Restrictions:** Cannot write or edit `.env` files

### `bash`
Run a shell command and return stdout/stderr. *(PAIR and BUILD modes)*

**Parameters:**
- `command` (string, required): The command to run

**Example:** Build the project, run tests, or execute arbitrary commands

**Command Allowlist (PAIR and BUILD modes):**
- **Utilities:** `cat`, `ls`, `ping`, `curl`, `sed`, `awk`, `jq`, `tail`
- **Programming:** `zig`, `uv`, `python`, `gcc`, `go`, `npm`, `node`, `bun`, `pnpm`
- **Containers:** `podman`, `docker`

**Restrictions:**
- Cannot execute commands that access or edit `.env` files
- Command must start with an allowlisted tool name (e.g., `cat file.txt` ✅, `vim file.txt` ❌)

## Navigation & Search Tools

### `find`
Search for files by name or pattern within a directory tree. *(PAIR and BUILD modes)*

**Parameters:**
- `pattern` (string, required): Filename pattern to search for (glob or exact match)
- `path` (string, optional): Starting directory (default: current directory)
- `type` (string, optional): Filter by type: `'file'`, `'dir'`, or `'any'` (default: `any`)

**Example:** `find pattern="*.zig" path="src" type="file"` — Find all Zig source files in src/

### `grep`
Search for text patterns within files (recursive). *(PAIR and BUILD modes)*

**Parameters:**
- `pattern` (string, required): Regular expression or literal text to search for
- `path` (string, required): File or directory to search in
- `context_lines` (integer, optional): Number of context lines to show (default: 0)

**Example:** `grep pattern="TODO" path="src" context_lines=2` — Find all TODOs with 2 lines of context

### `tree`
Show directory structure as a tree (with filtering for common ignored directories). *(PLAN, PAIR, and BUILD modes)*

**Parameters:**
- `path` (string, optional): Root directory (default: current directory)
- `depth` (integer, optional): Maximum directory depth to show (default: 3)
- `ignore_patterns` (string, optional): Comma-separated patterns to ignore (default: `.git,node_modules,.zig-cache`)

**Example:** `tree path="src" depth=4` — Show src/ structure up to 4 levels deep

## Comparison & Version Control

### `diff`
Show differences between two files in unified diff format. *(PAIR and BUILD modes)*

**Parameters:**
- `file1` (string, required): First file path
- `file2` (string, required): Second file path
- `context_lines` (integer, optional): Number of context lines (default: 3)

**Example:** `diff file1="old.zig" file2="new.zig" context_lines=5` — Compare two versions of a file

**Restrictions:** Cannot diff `.env` files

### `git`
Run git operations (log, status, diff, show). *(BUILD mode only)*

**Parameters:**
- `operation` (string, required): Git operation: `'log'`, `'status'`, `'diff'`, or `'show'`
- `args` (string, optional): Additional arguments for the git command (default: `''`)

**Example:** `git operation="log" args="--oneline -10"` — Show last 10 commits
**Example:** `git operation="status"` — Show git status
**Example:** `git operation="diff" args="HEAD~1"` — Show differences from last commit

## Security Features

### `.env` Protection
All file tools block access to `.env` files across all modes:
- ❌ `read` from `.env` files
- ❌ `write` or edit `.env` files
- ❌ `diff` against `.env` files
- ❌ `bash` commands that reference `.env` (e.g., `cat .env`, `source .env`, `grep .env`)

### Path Sandboxing
File tools are **sandboxed** to the current working directory:
- ❌ Absolute paths (starting with `/`) are rejected
- ❌ Path traversal (`..`) is rejected
- ✅ Relative paths are allowed

### Bash Command Filtering
Shell commands are restricted to a safe allowlist:
- ✅ Execution allowed only for whitelisted tools
- ❌ Any attempt to access `.env` is blocked
- ✅ Piping between allowed commands is supported (e.g., `cat file | grep pattern`)

## Mode Reference

### PLAN Mode
Read-only mode for planning and exploration:
- Understand codebase structure
- Read documentation and source files
- Plan implementation approach
- No execution, no modifications

### PAIR Mode
Collaborative development with safety guardrails:
- Run build commands, tests, and utilities
- Search and explore code
- Compare file changes
- No file writing or git operations
- Safe for iterating and learning

### BUILD Mode
Full capability for implementation:
- All tools available
- Read, write, and modify files
- Execute any whitelisted command
- Full git access
- For trusted, focused development work

## Tool Usage Flow

A typical workflow:

1. **Explore** (PLAN): Use `tree` or `read` to understand structure
2. **Search** (PLAN/PAIR): Use `find` or `grep` to locate specific code
3. **Compare** (PAIR): Use `diff` to review changes
4. **Verify** (PAIR): Use `bash` to run tests or builds
5. **Switch to BUILD** when ready to implement
6. **Modify** (BUILD): Use `write` to make changes
7. **Version** (BUILD): Use `git` to commit and track history
