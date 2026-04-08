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

Sync tasks between agent workspaces. Local tasks and peer tasks are decoupled -- federation syncs on demand, not automatically.

### Authentication

Each remote type needs its own credentials:

| Remote | Auth method |
|--------|-------------|
| `dolthub://` | `DOLT_TOKEN` env var or `dolt login` (stores in `~/.dolt/creds/`) |
| `s3://` | `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` env vars (or `~/.aws/credentials`) |
| `file://` / `ssh://` | Standard filesystem/SSH key auth |
| `https://` | Basic auth in URL or `DOLT_TOKEN` header |

Store secrets in `~/secrets/` and export them in `~/user-extensions.sh`:
```bash
# ~/user-extensions.sh
export DOLT_TOKEN="$(cat ~/secrets/dolt-token)"
export AWS_ACCESS_KEY_ID="$(cat ~/secrets/aws-key-id)"
export AWS_SECRET_ACCESS_KEY="$(cat ~/secrets/aws-secret-key)"
```

### Setup and Sync

```bash
# Add peer (one-time)
bd federation add-peer <peer-name> dolthub://myorg/shared-tasks

# Sync is explicit -- never automatic
bd federation sync              # All peers
bd federation sync <peer-name>  # Specific peer
bd federation status            # Check sync state
```

### Local vs Peer Tasks

Federation merges are explicit. Your local `.beads/` database is always the source of truth:
- **Local tasks**: created and managed normally. Never auto-pushed to peers.
- **Peer tasks**: appear after `bd federation sync`. Identified by their origin peer in metadata.
- **Conflicts**: Dolt's merge handles concurrent edits. Same task modified on both sides → merge conflict resolved by Dolt's 3-way merge.
- Use labels or projects to separate local-only vs shared tasks: `bd create "Shared task" --label "shared"`

### Data Sovereignty Tiers
Control what gets shared per peer:
- **T1**: Full sync -- all issues
- **T2**: Filtered -- by label/project
- **T3**: Summary only -- titles + status
- **T4**: Notifications only -- events without content

## Gotchas

- **Federation requires Dolt backend.** Stealth mode (`--stealth`) uses SQLite -- no federation. To enable federation, initialize a fresh Beads dir without `--stealth` (requires Dolt installed).
- **Sync is always manual.** No background sync. Run `bd federation sync` explicitly when you want to exchange tasks.
- Atomic claiming only prevents conflicts between agents sharing the same BEADS_DIR or synced via federation. Unsynced workspaces can have duplicate claims.
- Molecules are templates, not tasks. They create tasks when poured. Don't confuse molecule IDs with task IDs.
- Gates clear asynchronously. Poll with `bd mol ready --gated`, don't busy-wait.
