---
name: multi-agent-collaboration
description: Cross-agent coordination with Beads -- federation, molecules, swarms, and gates. Use when syncing tasks between agents/workspaces, setting up structured parallel workflows, or waiting on async external events. Do NOT use for single-session task management (use beads skill instead).
---

# Multi-Agent Collaboration

Advanced Beads features for coordinating across agents or workspaces. Requires the `beads` skill for basics.

## Atomic Claiming (Team Safety)

When multiple agents share a task pool, use atomic claiming to prevent race conditions:

```bash
bd update <id> --claim          # Sets assignee + in_progress atomically
bd ready                        # Only unclaimed, unblocked tasks
bd stale --days 7               # Find abandoned claims
```

## Team Workflow (Single Session)

Coordinate Claude Code teams via shared Beads pool:

```bash
# Coordinator: plan tasks
bd create "Epic: Feature X" -t epic
bd create "Task 1" -t task && bd link <epic> <t1> --type parent
bd create "Task 2" -t task && bd link <epic> <t2> --type parent

# Coordinator: spawn workers
TeamCreate(team_name="feature-x")
Agent(team_name="feature-x", name="worker-1", model="sonnet",
  prompt="Run bd ready, claim with bd update <id> --claim, work, close with bd close <id> --reason '...'")

# Workers claim atomically -- no conflicts
# Coordinator monitors: bd status
```

## Molecules -- Structured Workflows

Template-based workflow patterns (for recurring or complex operations):

| Type | Purpose |
|------|---------|
| **Swarms** | Epic + children with dependency DAG; max parallelism |
| **Patrols** | Recurring cycles (health checks, deployments) |
| **Wisps** | Ephemeral one-time workflows with auto-cleanup |

```bash
bd formula list                 # Available templates
bd mol pour <proto-id>          # Create persistent workflow
bd mol wisp <proto-id>          # Ephemeral (auto-cleaned)
bd swarm validate <epic-id>     # Analyze parallelizability
```

## Gates -- Async Coordination

Molecules can block on external events:

| Gate | Clears when |
|------|-------------|
| `gh:run` | GitHub Actions completed |
| `gh:pr` | PR merged |
| `timer` | Time elapsed |
| `human` | Manual approval |

```bash
bd gate list <mol-id>           # Show gates
bd gate clear <gate-id>         # Manual clear
bd mol ready --gated            # Molecules with cleared gates
```

## Federation -- Cross-Workspace Sync

Sync tasks between agent workspaces:

```bash
# Setup (one-time per peer)
bd federation add-peer <peer-name> dolthub://myorg/shared-tasks
# Remotes: dolthub://, s3://, file://, ssh://, https://

# Sync
bd federation sync              # All peers
bd federation sync talos        # Specific peer
bd federation status            # Check sync state
```

### Data Sovereignty Tiers
Control what gets shared per peer:
- **T1**: Full sync -- all issues
- **T2**: Filtered -- by label/project
- **T3**: Summary only -- titles + status
- **T4**: Notifications only -- events without content

## Gotchas

- Federation requires Dolt backend (default in non-stealth mode). Stealth mode (`--stealth`) uses SQLite -- no federation support.
- Atomic claiming only prevents conflicts between agents sharing the same BEADS_DIR or synced via federation. Unsynced workspaces can have duplicate claims.
- Molecules are templates, not tasks. They create tasks when poured. Don't confuse molecule IDs with task IDs.
- Gates clear asynchronously. Poll with `bd mol ready --gated`, don't busy-wait.
