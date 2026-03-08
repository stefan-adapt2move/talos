# Atlas MCP

The Atlas MCP server provides MCP (Model Context Protocol) tools for path locking and trigger management. It runs as a stdio-based MCP server that Claude Code connects to via the MCP servers configured in `trigger-runner`.

## Database Schema

Atlas uses SQLite with WAL mode at `~/.index/atlas.db`.

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

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Auto-increment primary key |
| trigger_name | TEXT | Trigger name |
| session_key | TEXT | Session key (e.g. phone number, thread ID) |
| session_id | TEXT | Claude Code session ID |
| updated_at | TEXT | ISO datetime |

Unique constraint on `(trigger_name, session_key)`.

### triggers

Trigger definitions for cron, webhook, and manual triggers.

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Auto-increment primary key |
| name | TEXT | Unique slug |
| type | TEXT | cron, webhook, or manual |
| description | TEXT | Human-readable description |
| channel | TEXT | inbox channel (internal, signal, email, web) |
| schedule | TEXT | Cron expression (cron triggers only) |
| webhook_secret | TEXT | Optional auth token (webhook triggers only) |
| prompt | TEXT | Trigger prompt template |
| session_mode | TEXT | ephemeral or persistent |
| enabled | INTEGER | 1=enabled, 0=disabled |
| last_run | TEXT | ISO datetime of last invocation |
| run_count | INTEGER | Total invocation count |
| created_at | TEXT | ISO datetime |

### path_locks

Tracks which paths are locked by running trigger sessions for parallel execution control.

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Auto-increment primary key |
| task_id | INTEGER | PID of the locking process (unique) |
| locked_path | TEXT | Normalized absolute path with trailing `/` |
| pid | INTEGER | Process PID for crash recovery |
| locked_at | TEXT | ISO datetime |

### session_metrics

Per-invocation cost and token tracking for all trigger sessions.

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Auto-increment primary key |
| session_type | TEXT | Session type (e.g. "trigger") |
| session_id | TEXT | Claude Code session ID |
| trigger_name | TEXT | Associated trigger |
| started_at | TEXT | ISO datetime |
| ended_at | TEXT | ISO datetime |
| duration_ms | INTEGER | Session duration in milliseconds |
| input_tokens | INTEGER | Input token count |
| output_tokens | INTEGER | Output token count |
| cache_read_tokens | INTEGER | Cache read token count |
| cache_creation_tokens | INTEGER | Cache creation token count |
| cost_usd | REAL | Total cost in USD |
| num_turns | INTEGER | Number of conversation turns |
| is_error | INTEGER | 1 if session ended in error |

### trigger_runs

Tracks active trigger invocations for crash recovery.

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER | Auto-increment primary key |
| trigger_name | TEXT | Trigger name |
| session_key | TEXT | Session key |
| session_mode | TEXT | ephemeral or persistent |
| session_id | TEXT | Claude Code session ID |
| payload | TEXT | Original trigger payload |
| started_at | TEXT | ISO datetime |
| completed_at | TEXT | ISO datetime (NULL while running) |

## Tool Specifications

Tools are registered conditionally based on the `ATLAS_TRIGGER` environment variable (set by `trigger.sh`).

### Trigger Tools (ATLAS_TRIGGER is set)

These tools are available to trigger sessions:

#### path_lock

Acquire a path lock before spawning an agent for file-modifying work. Prevents concurrent writes to the same directory. Uses the process PID for crash recovery.

```typescript
{
  path: string  // Directory to lock (e.g. '/home/atlas/projects/myapp')
}
```

Returns `{ locked: true, path, pid }` on success, or an error with the conflicting lock details.

- The path and all subdirectories are locked
- Conflict check is bidirectional: blocks both ancestors and descendants of the locked path
- Locks are automatically released by `stop.sh` on session exit (via PID cleanup)

#### path_unlock

Release a path lock after an agent completes its work.

```typescript
{
  path: string  // Directory to unlock
}
```

#### path_lock_status

View active path locks to understand which directories are currently locked.

Returns: `{ locks: [...] }`

## Path Locking Flow

The trigger session manages path locks directly when delegating file-modifying work to agent teammates:

```
1. trigger_session: path_lock("/home/atlas/projects/app")
2. trigger_session: Agent(team_name=..., name="developer", ...)
   → teammate works on /home/atlas/projects/app
3. trigger_session: path_unlock("/home/atlas/projects/app")
```

For parallel work on non-overlapping paths:

```
trigger_session: path_lock("/home/atlas/projects/frontend")
trigger_session: path_lock("/home/atlas/projects/backend")
trigger_session: Agent(team_name=..., name="frontend-dev", ...)
trigger_session: Agent(team_name=..., name="backend-dev", ...)
   → both teammates work in parallel
trigger_session: path_unlock("/home/atlas/projects/frontend")
trigger_session: path_unlock("/home/atlas/projects/backend")
```

## Source

- `app/atlas-mcp/index.ts` — Main MCP server
- `app/atlas-mcp/db.ts` — Database initialization, schema, migrations
- `app/atlas-mcp/locks.ts` — Path locking module
