---
name: beads
description: Task management with Beads (bd CLI). Use when creating, tracking, or managing tasks and dependencies. Loaded automatically for complex multi-step work.
---

# Beads Task Management

Beads (`bd`) is a dependency-aware task tracker. Tasks persist in `~/.beads` across sessions.

## Core Commands

| Action | Command |
|--------|---------|
| Create task | `bd create "title" -t task` |
| Create epic | `bd create "title" -t epic` |
| Quick capture | `bd q "title"` (returns only ID) |
| List open | `bd list --status open` |
| Show details | `bd show <id>` |
| Claim task | `bd update <id> --claim` |
| Close task | `bd close <id> --reason "what was done"` |
| Reopen | `bd reopen <id>` |

## Dependencies

| Action | Command |
|--------|---------|
| Add dependency | `bd dep add <issue-id> <depends-on-id>` |
| Show tree | `bd dep tree <id>` |
| Find ready work | `bd ready` (unblocked, unclaimed) |
| Link parent-child | `bd link <parent> <child> --type parent` |

## Context & Status

| Action | Command |
|--------|---------|
| Task context (AI-optimized) | `bd prime` |
| Overview | `bd status` |
| Search | `bd search "keyword"` |
| Stale tasks | `bd stale --days 7` |

## Task Lifecycle

```
open → in_progress (via --claim) → closed (via bd close)
                                  → blocked (has unresolved dependencies)
                                  → deferred (via bd update <id> --defer-until "date")
```

## Session Integration

- `bd prime` runs at SessionStart — shows all open tasks
- Stop hook blocks exit if you have claimed but unclosed tasks
- To exit with open tasks: `echo "reason" > $BEADS_DIR/.suspend`
- Or: `echo '{"reason":"..."}' > $BEADS_DIR/.stop-reason`

## Patterns

### Planning work
```bash
bd create "Epic title" -t epic
bd create "Subtask 1" -t task
bd create "Subtask 2" -t task
bd link <epic-id> <task1-id> --type parent
bd link <epic-id> <task2-id> --type parent
bd dep add <task2-id> <task1-id>  # task2 depends on task1
```

### Working through tasks
```bash
bd ready                        # See what's unblocked
bd update <id> --claim          # Claim it
# ... do the work ...
bd close <id> --reason "Done"   # Close it
bd ready                        # Next task
```

### Discovering new work
```bash
bd create "Found issue X" --deps discovered-from:<current-id>
```

## Environment

- `BEADS_DIR=~/.beads` — set automatically by SessionStart hook
- `BEADS_SESSION_ID` — current session ID, used for task claiming
- All data persists across sessions in `~/.beads/`
