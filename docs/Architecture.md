# Architecture

Atlas is a single-container system that turns Claude Code into a persistent, event-driven agent. This document provides a high-level component overview.

## System Overview

```
┌─────────────────── Docker Container (supervisord) ────────────────────┐
│                                                                        │
│  ┌─────────┐   ┌──────────┐   ┌──────────┐                           │
│  │  nginx   │──▸│  web-ui  │   │ atlas-mcp│                           │
│  │  :8080   │   │  :3000   │   │  (stdio) │                           │
│  └─────────┘   └──────────┘   └──────────┘                           │
│                      │               │                                 │
│                      ▼               ▼                                 │
│               ┌──────────────────────────────────────────┐            │
│               │          atlas.db (SQLite)                │            │
│               │  triggers │ trigger_sessions │ path_locks  │            │
│               └──────────────────────────────────────────┘            │
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
| **atlas-mcp** | stdio | MCP server for path locking tools | [inbox-mcp.md](inbox-mcp.md) |
| **supercronic** | — | Cron job runner | [Triggers.md](Triggers.md) |
| **qmd** | 8181 | Memory search daemon | [qmd-memory.md](qmd-memory.md) |

## Data Flow

1. **Event arrives** — Cron fires, webhook POSTs, or message sent
2. **Trigger session** — `trigger.sh` spawns a Claude session via `claude-atlas`
3. **Trigger handles** — Processes the event, responds directly or delegates
4. **Delegation** — For complex work: `TeamCreate` + `path_lock` + `Agent` teammates
5. **Parallel execution** — Teammates work independently on non-overlapping paths
6. **Coordination** — Trigger monitors teammates via `SendMessage`, synthesizes results
7. **Cleanup** — Path locks released, team shut down

## Session Types

### Trigger Session (Project Manager)
- **Spawned by**: `trigger.sh` per event via `claude-atlas`
- **System prompt**: SOUL + IDENTITY + trigger-system-prompt + channel-specific prompt
- **MCP tools**: `path_lock`, `path_unlock`, `path_lock_status` + memory (qmd)
- **Purpose**: User communication, task planning, memory management, team coordination

### Agent Teammates
- **Spawned by**: Trigger session via `Agent(team_name=..., name=..., model=...)`
- **Context**: Own context window — loads CLAUDE.md, MCP servers, skills + spawn prompt
- **Purpose**: Execute focused tasks (implementation, research, review)
- **Constraint**: Cannot spawn further teammates; communicate via `SendMessage`

See [Triggers.md](Triggers.md) for the full trigger lifecycle.

## Parallel Execution

Teammates can work in parallel on non-overlapping paths. The trigger session manages this directly:

1. Call `path_lock(path)` before spawning a file-modifying teammate
2. Spawn teammate via `Agent(team_name=..., ...)`
3. Call `path_unlock(path)` after the teammate completes

Path conflicts are checked bidirectionally: a lock on `/home/atlas/projects/app` blocks both its ancestors and descendants.

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
| session-start.sh | Every session starts | Load memory (all sessions) |
| stop.sh | After response | Journal reminder (trigger), path lock cleanup |
| pre-compact-*.sh | Before compaction | Prompt memory flush |
| SubagentStop | Agent teammate finishes | Quality gate (prompt-type review) |

See [hooks.md](hooks.md) for details.

## Detailed Documentation

- [inbox-mcp.md](inbox-mcp.md) — Database schema, MCP tools, path locking
- [hooks.md](hooks.md) — Lifecycle hook system
- [qmd-memory.md](qmd-memory.md) — Memory and search system
- [web-ui.md](web-ui.md) — Dashboard and API
- [directory-structure.md](directory-structure.md) — Filesystem layout
- [development.md](development.md) — Developer guide
- [Triggers.md](Triggers.md) — Triggers system
- [Integrations.md](Integrations.md) — Signal and Email
