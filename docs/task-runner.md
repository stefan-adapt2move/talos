# Path Locking

Path locking prevents concurrent writes to the same directory when multiple agent teammates work in parallel. The trigger session manages locks directly via MCP tools.

> **Note:** The old task-runner.sh / worker / reviewer pattern has been replaced by native Claude Code Agent Teams. Triggers now orchestrate teammates directly.

## How It Works

Before spawning a teammate that modifies files, the trigger session acquires a path lock. After the teammate finishes, the lock is released. This prevents two teammates from writing to the same directory simultaneously.

```
trigger_session:
  1. path_lock("/home/agent/projects/app")
  2. Agent(team_name=..., name="developer", ...)
     → teammate modifies /home/agent/projects/app
  3. path_unlock("/home/agent/projects/app")
```

## MCP Tools

### path_lock

Acquires a lock on a directory. The lock covers the path and all its subdirectories.

```typescript
path_lock({ path: "/home/agent/projects/myapp" })
// → { locked: true, path: "/home/agent/projects/myapp", pid: 1234 }
```

If there is a conflict, returns an error with details about the blocking lock.

### path_unlock

Releases a previously acquired lock.

```typescript
path_unlock({ path: "/home/agent/projects/myapp" })
// → { unlocked: true, path: "/home/agent/projects/myapp" }
```

### path_lock_status

Shows all currently active locks.

```typescript
path_lock_status()
// → { locks: [{ locked_path: "/home/agent/projects/myapp/", pid: 1234, ... }] }
```

## Conflict Detection

Conflicts are checked bidirectionally:

- A new lock on `/home/agent/projects/app` is blocked if `/home/agent/projects` is already locked (ancestor conflict)
- A new lock on `/home/agent/projects` is blocked if `/home/agent/projects/app` is already locked (descendant conflict)

Tasks without file modifications don't need a lock and can always run in parallel.

## Crash Recovery

Locks are keyed by PID. The `stop.sh` hook releases any locks held by the current session's PID when the session ends (normally or on crash). On container restart, `entrypoint.sh` clears all stale path locks from the database.

## Parallel Execution Pattern

```
trigger_session:
  path_lock("/home/agent/projects/frontend")
  path_lock("/home/agent/projects/backend")
  Agent(team_name="feature-x", name="frontend-dev", ...)
  Agent(team_name="feature-x", name="backend-dev", ...)
  ↓ (teammates work in parallel on non-overlapping paths)
  path_unlock("/home/agent/projects/frontend")
  path_unlock("/home/agent/projects/backend")
```

## Source

- `app/atlas-mcp/index.ts` — `path_lock`, `path_unlock`, `path_lock_status` tool implementations
- `app/atlas-mcp/locks.ts` — Path locking logic and conflict detection
- `app/hooks/stop.sh` — PID-based lock cleanup on session exit
- `app/entrypoint.sh` — Clears all locks on container start
