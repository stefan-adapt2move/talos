---
name: beads
description: Task management with Beads (bd CLI). Use when planning multi-step work, tracking progress across sessions, or coordinating tasks with dependencies. Triggers on 'create task', 'track progress', 'plan work', 'what tasks are open', 'dependency graph', or any complex goal that benefits from decomposition. Do NOT use for simple one-off actions.
---

# Beads Task Management

`bd` is a dependency-aware task tracker. All data persists in `~/.beads` across sessions.

## Quick Reference

| Action | Command |
|--------|---------|
| Create task | `bd create "title" -t task` |
| Create epic | `bd create "title" -t epic` |
| Quick capture (ID only) | `bd q "title"` |
| List open | `bd list --status open` |
| Show details | `bd show <id>` |
| Claim task | `bd update <id> --claim` |
| Close task | `bd close <id> --reason "what was done"` |
| Reopen | `bd reopen <id>` |
| Add dependency | `bd dep add <issue-id> <depends-on-id>` |
| Show dep tree | `bd dep tree <id>` |
| Find ready work | `bd ready` |
| Link parent-child | `bd link <parent> <child> --type parent` |
| Task context | `bd prime` |
| Overview | `bd status` |
| Search | `bd search "keyword"` |
| Compound filter | `bd query "status=open AND assignee=me"` |

## Task Lifecycle

```
open --> in_progress (via --claim) --> closed (via bd close)
     \-> blocked (unresolved deps)
     \-> deferred (via bd update <id> --defer-until "2026-04-10")
```

## Session Integration

- **SessionStart**: sets `BEADS_DIR` and `BEADS_ACTOR` (= `session-<session_id>`), then runs `bd prime`
- **Stop hook**: blocks exit if you have in_progress tasks assigned to YOUR `BEADS_ACTOR`
- **Exit with open tasks**: write `echo "reason" > $BEADS_DIR/.suspend` (for reminders) or `echo '{"reason":"..."}' > $BEADS_DIR/.stop-reason` (early exit)
- **Teams/subagents**: override `BEADS_ACTOR` with a unique identity (e.g. `export BEADS_ACTOR=worker-<name>`) so each agent's claims are scoped independently

## Gotchas

- `bd list --status` takes **one** value only. For compound filters use `bd query "status=open OR status=in_progress"`.
- `bd dep add <A> <B>` means "A depends on B" (A is blocked by B). Order matters.
- `bd close` requires `--reason` flag -- positional reason argument does NOT work.
- `bd ready` returns unclaimed AND unblocked tasks. Claimed tasks (in_progress) are excluded.
- IDs are hash-based (`agent-ps4`), not sequential. Always copy from output.
- `--claim` sets assignee to `BEADS_ACTOR` and status to in_progress atomically. Different sessions/subagents get different actors.
- `BEADS_DIR` and `BEADS_ACTOR` are set automatically by the SessionStart hook. Subagents should only override `BEADS_ACTOR`.

## Patterns

### Plan and execute work
```bash
# 1. Create structure
bd create "Epic title" -t epic           # Returns epic ID
bd create "Subtask 1" -t task            # Returns task ID
bd create "Subtask 2" -t task
bd link <epic-id> <task1-id> --type parent
bd link <epic-id> <task2-id> --type parent
bd dep add <task2-id> <task1-id>         # task2 waits for task1

# 2. Work through tasks
bd ready                                 # See unblocked work
bd update <id> --claim                   # Claim it
# ... do the work ...
bd close <id> --reason "Done: merged PR" # Close with context
bd ready                                 # Next task

# 3. Discover new work during execution
bd create "Found issue X" --deps discovered-from:<current-id>
```

### Cross-session continuity
Tasks persist. A reminder session picks up where you left off:
```bash
bd prime                                 # See all open tasks
bd ready                                 # What's unblocked now?
```
