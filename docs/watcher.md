# Trigger Concurrency

> **Note:** The old watcher.sh / wake-file dispatch system has been removed. Triggers now orchestrate agent teammates directly using native Claude Code Agent Teams — no file-based signaling or separate dispatch process is needed.

## How Triggers Handle Concurrency

Each trigger invocation runs as its own Claude Code session. Concurrent runs of the same trigger are prevented by `trigger.sh` using a per-trigger flock:

```bash
flock -n 200 || { echo "Trigger already running"; exit 0; }
) 200>".trigger-${TRIGGER_NAME}.flock"
```

If a trigger session is already active (flock held), the new invocation exits immediately. For persistent sessions, incoming messages are injected directly via the IPC socket instead.

## Persistent Session IPC

For persistent triggers, `trigger.sh` tries to inject new messages into a running session via the Claude Code IPC socket (`/tmp/claudec-<session_id>.sock`) before spawning a new process:

1. Look up the existing session ID in `trigger_sessions` DB
2. If a socket exists at `/tmp/claudec-<session_id>.sock` → inject message via IPC
3. If the socket is stale or the session is gone → spawn a new session

This allows persistent trigger sessions (e.g. Signal, email threads) to receive multiple messages without spawning multiple Claude processes.

## Path-Level Parallelism

Within a single trigger session, agent teammates can work in parallel on non-overlapping paths using the `path_lock` / `path_unlock` MCP tools. See [task-runner.md](task-runner.md) for details.

## Log Files

- `/atlas/logs/trigger-<name>.log` — Per-trigger session output
- `/atlas/logs/atlas-mcp.log` — Atlas MCP server log
