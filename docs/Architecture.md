# Architecture

Atlas is a single-container system that turns Claude Code into a persistent, event-driven agent. This document provides a high-level component overview.

## System Overview

```
┌─────────────────── Docker Container (supervisord) ────────────────────┐
│                                                                        │
│  ┌─────────┐   ┌──────────┐   ┌──────────┐   ┌───────────────────┐   │
│  │  nginx   │──▸│  web-ui  │   │ inbox-mcp│   │     watcher.sh    │   │
│  │  :8080   │   │  :3000   │   │  (stdio) │   │  (inotifywait)    │   │
│  └─────────┘   └──────────┘   └──────────┘   └───────────────────┘   │
│                      │               │               │                 │
│                      ▼               ▼               ▼                 │
│               ┌──────────────────────────────────────────┐            │
│               │          atlas.db (SQLite)                │            │
│               │  tasks │ path_locks │ trigger_sessions     │            │
│               └──────────────────────────────────────────┘            │
│                                      │                                 │
│                            .wake-task-<id>                             │
│                                      │                                 │
│                                      ▼                                 │
│                     ┌────────────────────────────┐                     │
│                     │    task-runner.sh (per task)│                     │
│                     │  ┌──────────┐ ┌──────────┐ │                     │
│                     │  │  Worker  │↔│ Reviewer  │ │                     │
│                     │  │(ephemeral│ │  (review  │ │                     │
│                     │  │ claude)  │ │   loop)   │ │                     │
│                     │  └──────────┘ └──────────┘ │                     │
│                     └────────────────────────────┘                     │
│                                                                        │
│  ┌────────────┐   ┌────────────┐                                      │
│  │ supercronic│   │    qmd     │                                      │
│  │ (cron)     │   │   :8181    │                                      │
│  └────────────┘   └────────────┘                                      │
└────────────────────────────────────────────────────────────────────────┘
```

## Component Summary

| Component | Port | Purpose | Documentation |
|-----------|------|---------|---------------|
| **nginx** | 8080 | Reverse proxy to web-ui | [web-ui.md](web-ui.md) |
| **web-ui** | 3000 | Hono.js + HTMX dashboard | [web-ui.md](web-ui.md) |
| **inbox-mcp** | stdio | MCP server for inbox/trigger tools | [inbox-mcp.md](inbox-mcp.md) |
| **watcher** | — | inotifywait loop, dispatches task-runners | [watcher.md](watcher.md) |
| **task-runner** | — | Per-task orchestrator with review loop | [task-runner.md](task-runner.md) |
| **supercronic** | — | Cron job runner | [Triggers.md](Triggers.md) |
| **qmd** | 8181 | Memory search daemon | [qmd-memory.md](qmd-memory.md) |

## Data Flow

1. **Event arrives** — Cron fires, webhook POSTs, or message sent
2. **Trigger session** — Evaluates event, plans work, creates tasks via `task_create()`
3. **Wake signal** — `.wake-task-<id>` file touched per task
4. **Watcher dispatches** — Checks path locks and max_parallel, spawns task-runners
5. **Task-runner orchestrates** — Acquires path lock, spawns ephemeral worker
6. **Worker executes** — Processes task end-to-end, returns JSON result
7. **Review loop** — If review enabled, reviewer checks result; iterates up to 5 times
8. **Completion** — Lock released, trigger re-awakened with result via `.wake-<trigger>-<id>`
9. **Dispatch next** — Watcher re-checks pending tasks, dispatches next available

## Session Types

### Trigger Session (Project Manager)
- **Spawned by**: trigger.sh per event
- **Access**: Read-only workspace
- **Tools**: Trigger tools (task_create, task_get, task_update, task_cancel, task_lock_status)
- **Purpose**: User communication, task planning, memory management

### Ephemeral Worker
- **Spawned by**: task-runner.sh per task
- **Access**: Read/write workspace
- **Tools**: Playwright MCP only (no inbox, no memory MCP)
- **Purpose**: Execute a single task, return structured JSON result
- **Lifecycle**: Created fresh per task, may be resumed during review iterations

### Review Agent
- **Spawned by**: task-runner.sh after worker completes
- **Access**: Read-only workspace
- **Tools**: Built-in tools (Read, Grep, Glob)
- **Purpose**: Verify worker output against acceptance criteria

See [task-runner.md](task-runner.md) for the worker↔reviewer lifecycle.
See [Triggers.md](Triggers.md) for trigger details.

## Parallel Execution

Tasks can run in parallel under these conditions:
- **Tasks with non-overlapping paths** — Each locks its path + subdirectories
- **Tasks without path** — No lock, always dispatchable (research, browser automation, etc.)
- **Max parallel workers** — Configurable limit (default: 3) in `config.yml`

Path lock conflicts are checked bidirectionally: a new path is blocked if it's an ancestor or descendant of an existing lock.

## Filesystem Layout

| Location | Access | Contents |
|----------|--------|----------|
| `/atlas/app/` | Read-only | Core code, hooks, MCP server, prompts |
| `/home/atlas/` | Read-write | Memory, system state, config, identity, skills |

See [directory-structure.md](directory-structure.md) for details.

## Hook System

Hooks inject context at lifecycle events:

| Hook | Runs When | Purpose |
|------|-----------|---------|
| session-start.sh | Session starts | Load memory (trigger only) |
| stop.sh | After response | Mode-specific exit (all modes exit 0) |
| pre-compact-*.sh | Before compaction | Prompt memory flush |
| subagent-stop.sh | Subagent finishes | Quality gate |

See [hooks.md](hooks.md) for details.

## Detailed Documentation

- [inbox-mcp.md](inbox-mcp.md) — Database schema, MCP tools, task lifecycle
- [task-runner.md](task-runner.md) — Task-runner lifecycle, review loop, path locking
- [hooks.md](hooks.md) — Lifecycle hook system
- [watcher.md](watcher.md) — Event-driven wake system
- [qmd-memory.md](qmd-memory.md) — Memory and search system
- [web-ui.md](web-ui.md) — Dashboard and API
- [directory-structure.md](directory-structure.md) — Filesystem layout
- [development.md](development.md) — Developer guide
- [Triggers.md](Triggers.md) — Triggers system
- [Integrations.md](Integrations.md) — Signal and Email channels
