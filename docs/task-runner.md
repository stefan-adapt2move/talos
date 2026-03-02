# Task Runner

The task-runner orchestrates the complete lifecycle of a single task: path locking, ephemeral worker execution, optional review loop, and trigger re-awakening.

## Implementation

Source: `app/task-runner.sh`

Each task gets its own task-runner process, spawned by the watcher when dispatch conditions are met.

## Lifecycle

```
task-runner.sh <task_id>
  │
  ├─ Write PID file (/tmp/task-runner-<id>.pid)
  ├─ Read task from DB (content, path, review)
  ├─ Acquire path lock (if path set) → exit if conflict
  ├─ Set status → 'processing'
  │
  ├─ Spawn ephemeral worker session
  │    └─ claude-atlas --mode worker-ephemeral -p "<task_content>"
  │    └─ Working directory: path (if set) or $HOME
  │    └─ Capture JSON output
  │
  ├─ Review loop (if review=true)
  │    ├─ Set status → 'reviewing'
  │    ├─ Spawn reviewer session with original task + worker result
  │    ├─ Parse verdict: "approve" or "revise"
  │    │
  │    ├─ If "approve" → break
  │    ├─ If "revise" → resume worker with feedback
  │    │                 → resume reviewer with new result
  │    │                 → repeat (max 5 iterations)
  │    └─ If max iterations → accept current result
  │
  ├─ Set status → 'done'
  ├─ Release path lock
  ├─ Wake trigger (.wake-<trigger>-<task_id>)
  └─ Touch .wake → watcher dispatches next tasks
```

## Worker Session

The ephemeral worker receives the task description as a direct prompt (`-p` argument) and runs with:
- **Mode**: `--mode worker-ephemeral`
- **MCP**: Base config only (Playwright) — auto-discovered from `$HOME/.mcp.json`
- **No inbox MCP**, no memory MCP (those are only in the trigger MCP config)
- **Working directory**: Task's `path` (if set) or `$HOME`

The worker's final message should contain a JSON result block:

```json
{
  "status": "completed",
  "summary": "What was accomplished",
  "files_changed": ["path/to/file.ts"],
  "notes": "Observations or caveats"
}
```

## Review Loop

When `review=true` for a task, the task-runner spawns a review agent after the worker completes.

### Reviewer Session

- **Mode**: `--mode reviewer`
- **MCP**: Base config only (Playwright) — auto-discovered from `$HOME/.mcp.json`
- **Permissions**: Write/Edit not auto-approved (soft read-only via settings permissions)
- **Input**: Original task description + worker's result
- **For tasks with `path`**: Also reviews changed files for quality, security, performance

The reviewer returns a verdict:

```json
{
  "verdict": "approve|revise",
  "feedback": "Summary",
  "issues": [{"severity": "high", "description": "..."}]
}
```

### Iteration Flow

1. Worker completes → reviewer checks
2. If "revise" → worker session resumed with feedback
3. Worker revises → reviewer checks again
4. Repeat until "approve" or max iterations reached (default: 5)

Both sessions persist during iterations (resumed via `--resume`).

### When Review Runs

- **`review=true`** (default): Review is performed
- **`review=false`**: Worker result goes directly to trigger, no review

The trigger session decides per task via the `review` parameter in `task_create()`.

## Path Locking

Tasks with a `path` parameter lock that directory and all subdirectories during execution.

### Lock Acquisition

```
acquire-lock.ts <task_id> <path> [pid]
```

Checks for bidirectional conflicts:
- New path is under an existing lock (ancestor locked)
- Existing lock is under the new path (descendant locked)

If no conflict, the lock is stored in `path_locks` table.

### Lock Release

```
release-lock.ts <task_id>
```

Removes the lock when the task completes (or fails).

### Crash Recovery

On watcher startup:
1. Check all `path_locks` entries for running PIDs
2. If PID is dead → delete lock, reset task to `pending`
3. Dispatch any pending tasks

## Task States

```
pending → processing → reviewing → done
                 │           │
                 └───────────┴──→ failed
                                    │
pending ← (crash recovery) ─────────┘
```

| State | Meaning |
|-------|---------|
| pending | Waiting to be dispatched |
| processing | Worker is executing |
| reviewing | Review agent is checking |
| done | Completed successfully |
| failed | Worker or reviewer crashed |
| cancelled | Cancelled by trigger |

## Error Handling

- **Worker crash**: Task marked `failed`, lock released, trigger woken with error
- **Reviewer crash**: Worker result accepted as-is (graceful degradation)
- **Task-runner crash**: Watcher startup recovery cleans up stale locks and resets tasks

## Configuration

In `config.yml`:

```yaml
workers:
  max_parallel: 3          # Maximum concurrent task-runners
  max_review_iterations: 5  # Max worker↔reviewer rounds per task
```

## Files

| File | Purpose |
|------|---------|
| `app/task-runner.sh` | Task lifecycle orchestrator |
| `app/inbox-mcp/update-task.ts` | CLI: parameterized task status/result updates |
| `app/inbox-mcp/locks.ts` | Path locking module |
| `app/inbox-mcp/acquire-lock.ts` | CLI: acquire path lock |
| `app/inbox-mcp/release-lock.ts` | CLI: release path lock |
| `app/inbox-mcp/wake-trigger.ts` | CLI: wake trigger session |
| `app/prompts/worker-ephemeral-prompt.md` | Ephemeral worker prompt |
| `app/prompts/reviewer-system-prompt.md` | Review agent prompt |
| `app/.mcp.json` | Base MCP config (Playwright) — shared by all modes |
| `/tmp/task-runner-<id>.pid` | PID file for crash recovery |
| `/atlas/logs/task-runner-<id>.log` | Per-task log |
