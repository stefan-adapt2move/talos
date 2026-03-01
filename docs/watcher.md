# Watcher

The watcher is an event-driven dispatch system that monitors for filesystem events, manages task parallelism, and resumes trigger sessions when tasks complete. It uses `inotifywait` for efficient monitoring without polling.

## Implementation

Source: `app/watcher.sh`

The watcher runs as a continuous loop:

```bash
inotifywait -m "$WATCH_DIR" -e create,modify,attrib \
  --exclude '\.(db|wal|shm)$' \
  --format '%f' | while read FILENAME; do
  # Handle wake events
done
```

## Wake File Patterns

### `.wake-task-<id>` — New Task Signal

Created by `task_create()` when a trigger creates a task. The watcher:

1. Removes the wake file (task stays pending in DB)
2. Calls `dispatch_pending_tasks`

### `.wake` — Re-dispatch Signal

Touched by task-runners when they finish. The watcher calls `dispatch_pending_tasks` to check for pending tasks that can now be dispatched (freed path locks, available slots).

### `.wake-<trigger>-<task_id>` — Trigger Re-awakening

Created by `wake-trigger.ts` when a task completes. Contains JSON with the task result. The watcher resumes the trigger session with the result.

## Task Dispatch

The `dispatch_pending_tasks` function is the core scheduling logic:

1. Read `max_parallel` from `config.yml` (default: 3)
2. Count active workers (tasks in `processing`/`reviewing` state)
3. If at capacity → skip
4. Query pending tasks ordered by `created_at`
5. For each pending task:
   - If has `path` → check for lock conflicts (bidirectional)
   - If conflict → skip this task
   - If no conflict (or no path) → spawn `task-runner.sh <task_id>` in background
6. Re-check active count after each dispatch

### Path Lock Checking

Path conflicts are checked directly via SQLite:

```sql
SELECT COUNT(*) FROM path_locks
WHERE '<normalized_path>' LIKE locked_path || '%'  -- ancestor locked
   OR locked_path LIKE '<normalized_path>' || '%'   -- descendant locked
```

Tasks without a path are always dispatchable since they don't lock any paths.

## Trigger Re-awakening

When a task-runner completes a task that was created by a trigger, the trigger session is re-awakened via `.wake-<trigger>-<task_id>` files.

### Wake File Format

JSON file at `.wake-<trigger_name>-<task_id>`:

```json
{
  "task_id": 42,
  "trigger_name": "email-handler",
  "session_key": "thread-123",
  "session_id": "abc-def-123",
  "channel": "email",
  "response_summary": "Task completed. Here's the result..."
}
```

### Re-awakening Process

1. Watcher detects `.wake-*` file (excluding `.wake-task-*`)
2. Runs in background (doesn't block main watcher)
3. Acquires per-trigger flock
4. Atomically moves wake file to temp
5. Parses JSON fields
6. Resumes trigger session with result message
7. If no session ID, falls back to spawning via `trigger.sh`

## Startup Recovery

On startup, the watcher performs recovery:

1. **Clean stale path locks** — Check PIDs in `path_locks`; if dead, delete lock and reset task to pending
2. **Reset stuck tasks** — Any task in `processing`/`reviewing` without a lock entry is reset to `pending`
3. **Remove stale `.wake-task-*` files** — Tasks are still pending in DB
4. **Process stale `.wake-<trigger>-*` files** — Re-awaken triggers
5. **Re-create missing trigger wakes** — For done tasks still in `task_awaits`
6. **Initial dispatch** — Process any pending tasks

## Concurrency Control

### Trigger Session Locks

Each trigger has its own lock file to prevent concurrent runs:

```bash
flock -n 200 || { echo "Trigger already running"; exit 0; }
) 200>".trigger-${TRIGGER_NAME}.flock"
```

### Task-Level Concurrency

Managed via:
- `max_parallel` config — Overall limit on concurrent task-runners
- `path_locks` SQLite table — Per-task path locking
- PID files in `/tmp/` — Crash detection

## Log Files

- `/atlas/logs/watcher.log` — Watcher dispatch events
- `/atlas/logs/task-runner-<id>.log` — Per-task runner logs
- `/atlas/logs/trigger-<name>.log` — Per-trigger session output

## Files

| File | Purpose |
|------|---------|
| `.wake` | Re-dispatch signal (task completed, check for more) |
| `.wake-task-<id>` | New task created, trigger dispatch |
| `.wake-<trigger>-<id>` | Trigger re-awakening with result |
| `.trigger-<name>.flock` | flock file per trigger |
| `/tmp/task-runner-<id>.pid` | Task-runner PID for crash recovery |
