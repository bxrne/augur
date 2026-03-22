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
# streams by default
OPENROUTER_API_KEY=... zig build run -- -p "Say hello"

# buffered output (shows a spinner in TTYs)
OPENROUTER_API_KEY=... zig build run -- -p "Say hello" --no-stream
```

## Start the REPL

```sh
OPENROUTER_API_KEY=... zig build run
```

Type `/quit` to leave the REPL.

Streaming is on by default; pass `--no-stream` to buffer responses. The REPL
uses ANSI colors when stdout is a TTY, starts in **plan** mode, and shows the
active model in the startup header.

### Slash commands

Inside the REPL:

- `/plan` switches to plan mode (high-level steps, no code).
- `/build` switches to build mode (implementation + code).
- `/model <id>` changes the OpenRouter model.
- `/quit` exits the REPL.
- `/help` shows the command list.

In the REPL, prompts are prefixed with `mode>` (for example `plan>`) and assistant responses with `>`. 

## Environment variables

- `OPENROUTER_API_KEY` (required)
- `OPENROUTER_BASE_URL` (optional, defaults to `https://openrouter.ai/api/v1`)

## Tools

The assistant can call these tools:

- `read`: Read a file from disk.
- `write`: Write a file to disk.
- `bash`: Run a shell command and return stdout/stderr.

## Roadmap

- [x] Streamed responses 
- [x] Model choice
- [x] Plan and Build modes
- [ ] Conversation Mgmt
- [ ] Web search tool 
- [ ] Subagents
