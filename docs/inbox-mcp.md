# Inbox-MCP

The Inbox-MCP server provides MCP (Model Context Protocol) tools for task and trigger management. It runs as a stdio-based MCP server that Claude Code connects to directly.

## Database Schema

Atlas uses SQLite with WAL mode at `~/.index/atlas.db`.

### tasks

The work queue. Tasks flow through statuses: `pending` → `processing` → `reviewing` → `done`/`failed`/`cancelled`.

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Auto-increment primary key |
| trigger_name | TEXT | Origin trigger that created this task |
| content | TEXT | Task description with acceptance criteria |
| status | TEXT | pending, processing, reviewing, done, failed, cancelled |
| path | TEXT | Optional working directory (locked during execution) |
| review | INTEGER | 1=review enabled, 0=skip review |
| review_iteration | INTEGER | Current review loop iteration |
| worker_result | TEXT | JSON result from the worker |
| response_summary | TEXT | Final result relayed to trigger |
| created_at | TEXT | ISO datetime |
| processed_at | TEXT | ISO datetime |

Index: `(status, created_at)` for efficient queue queries.

### path_locks

Tracks which paths are locked by running tasks for parallel execution control.

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Auto-increment primary key |
| task_id | INTEGER | References tasks(id), unique |
| locked_path | TEXT | Normalized absolute path with trailing `/` |
| pid | INTEGER | Task-runner PID for crash recovery |
| locked_at | TEXT | ISO datetime |

### task_awaits

Tracks which trigger session is waiting for a task result. When a task completes, the watcher uses this to re-awaken the trigger.

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Auto-increment primary key |
| task_id | INTEGER | References tasks(id) |
| trigger_name | TEXT | Trigger waiting for result |
| session_key | TEXT | Session key for persistent triggers |
| created_at | TEXT | ISO datetime |

### messages

External event log (signal, email, web). Fire-and-forget — no status tracking.

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Auto-increment primary key |
| channel | TEXT | Source channel |
| sender | TEXT | Sender identifier |
| content | TEXT | Message body |
| created_at | TEXT | ISO datetime |

### trigger_sessions

Maps `(trigger_name, session_key)` to Claude session IDs for persistent triggers.

### triggers

Trigger definitions for cron, webhook, and manual triggers.

### session_metrics

Per-invocation cost and token tracking for all session types.

## Tool Specifications

Tools are registered conditionally based on the `ATLAS_TRIGGER` environment variable.

### Trigger Tools (ATLAS_TRIGGER is set)

These tools are available to trigger sessions (project manager role):

#### task_create

Create a task for execution. Automatically writes `.wake-task-<id>` and registers for re-awakening.

```typescript
{
  content: string,           // Task description with acceptance criteria (self-contained)
  path?: string,             // Working directory (locked during execution)
  review?: boolean            // Default: true
}
```

- Tasks with non-overlapping `path` values run in parallel
- Tasks without `path` always run in parallel (no lock needed)
- `review: false` skips the review agent

#### task_get

Get a specific task by ID to check status and response.

```typescript
{
  task_id: number
}
```

#### task_update

Update a pending task's content. Only works if status is `pending`.

```typescript
{
  task_id: number,
  content: string
}
```

#### task_cancel

Cancel a pending task. Only works if status is `pending`.

```typescript
{
  task_id: number,
  reason?: string
}
```

#### task_lock_status

View active path locks. Shows which directories are currently locked by running tasks.

Returns: `{ active_workers: number, locks: [...] }`

### Worker Tools (Legacy — ATLAS_TRIGGER is not set)

These tools exist for backward compatibility with the legacy persistent worker (`--mode worker`). New ephemeral workers don't use inbox MCP at all — the task-runner manages their lifecycle.

- `get_next_task` — Claim next pending task
- `task_complete` — Mark task done
- `task_list` — List tasks
- `task_get` — Get task by ID
- `inbox_stats` — Queue statistics

## Task Lifecycle (New)

1. **Creation**: Trigger calls `task_create()` → task inserted as `pending`
2. **Wake**: `.wake-task-<id>` file written → watcher dispatches
3. **Dispatch**: Watcher checks locks/capacity → spawns `task-runner.sh`
4. **Lock**: Task-runner acquires path lock → status `processing`
5. **Execute**: Ephemeral worker runs task → returns JSON result
6. **Review**: If enabled, reviewer checks result → may iterate
7. **Complete**: Status `done`, lock released, `.wake-<trigger>-<id>` written
8. **Re-awaken**: Watcher resumes trigger session with result
9. **Next**: `.wake` touched → watcher dispatches next pending tasks

## Source

- `app/inbox-mcp/index.ts` — Main MCP server
- `app/inbox-mcp/db.ts` — Database initialization, schema, migrations
- `app/inbox-mcp/locks.ts` — Path locking module
- `app/inbox-mcp/acquire-lock.ts` — CLI: acquire path lock
- `app/inbox-mcp/release-lock.ts` — CLI: release path lock
- `app/inbox-mcp/wake-trigger.ts` — CLI: wake trigger session
