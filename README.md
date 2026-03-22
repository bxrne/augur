# zip

`zip` is a tiny Claude-style assistant client written in Zig. It talks to
OpenRouter, supports tool calling, and ships with a simple REPL.

This project started as the CodeCrafters course "Build your own Claude Code."

## Requirements

- Zig 0.15+
- An OpenRouter API key (`OPENROUTER_API_KEY`)

## Build

```sh
zig build
```

## Run a single prompt

```sh
OPENROUTER_API_KEY=... zig build run -- -p "Say hello"
```

## Start the REPL

```sh
OPENROUTER_API_KEY=... zig build run
```

Type `exit` or `quit` to leave the REPL.

## Environment variables

- `OPENROUTER_API_KEY` (required)
- `OPENROUTER_BASE_URL` (optional, defaults to `https://openrouter.ai/api/v1`)

## Tools

The assistant can call these tools:

- `read`: Read a file from disk.
- `write`: Write a file to disk.
- `bash`: Run a shell command and return stdout/stderr.

## Roadmap

- [ ] Streamed responses 
- [ ] Plan and Build modes
- [ ] Conversation Mgmt
- [ ] Web search tool 
- [ ] Subagents

