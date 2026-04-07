---
name: multi-agent-collaboration
description: Advanced multi-agent coordination with Beads — federation, molecules, swarms, and gates. Use when coordinating across multiple AI agents or workspaces.
---

# Multi-Agent Collaboration with Beads

Advanced features for coordinating work across multiple agents or workspaces.

## Atomic Claiming

Multiple agents can safely work from the same task pool:

```bash
bd update <id> --claim          # Atomically sets assignee + status=in_progress
bd ready                        # Returns only unclaimed, unblocked work
bd stale --days 7               # Find abandoned in_progress claims
```

## Molecules — Structured Workflows

Templates for common multi-agent patterns:

| Type | Purpose |
|------|---------|
| **Swarms** | Epic + children with dependency DAG; max parallelism |
| **Patrols** | Recurring operational cycles (health checks, deployments) |
| **Wisps** | Ephemeral one-time workflows with auto-cleanup |

```bash
bd formula list                 # Available templates
bd mol pour <proto-id>          # Create persistent workflow
bd mol wisp <proto-id>          # Create ephemeral workflow
bd swarm validate <epic-id>     # Analyze parallelizability
```

## Gates — Async Coordination

Molecules can wait on external events:

| Gate Type | Trigger |
|-----------|---------|
| `gh:run` | GitHub Actions completed |
| `gh:pr` | PR merged |
| `timer` | Time elapsed |
| `human` | Manual approval |
| `mail` | Email delegation |

```bash
bd gate list <mol-id>           # Show gates for a molecule
bd gate clear <gate-id>         # Manually clear a gate
bd mol ready --gated            # Find molecules with cleared gates
```

## Federation — Cross-Workspace Sync

Sync tasks between multiple agent workspaces (e.g., Atlas <-> Talos):

### Setup
```bash
bd federation add-peer <name> <remote-url>
# Supported remotes: dolthub://, s3://, file://, ssh://, https://
```

### Usage
```bash
bd federation sync              # Sync with all peers
bd federation sync <peer-name>  # Sync with specific peer
bd federation status            # Show sync status
```

### Data Sovereignty Tiers
- **T1**: Full sync — all issues shared
- **T2**: Filtered sync — label/project-based
- **T3**: Summary only — titles + status, no details
- **T4**: Notifications only — events without content

### Example: Atlas <-> Talos Collaboration
```bash
# On Atlas:
bd federation add-peer talos dolthub://adapt2move/shared-tasks

# On Talos:
bd federation add-peer atlas dolthub://adapt2move/shared-tasks

# Both agents can now:
bd create "Shared task" --label "shared"
bd federation sync
```

## Team Workflow Pattern

For complex tasks within a single session using Claude Code teams:

```bash
# Coordinator creates tasks
bd create "Epic: Feature X" -t epic
bd create "Task 1" -t task && bd link <epic> <t1> --type parent
bd create "Task 2" -t task && bd link <epic> <t2> --type parent

# Spawn team
TeamCreate(team_name="feature-x")
Agent(team_name="feature-x", name="worker-1", model="sonnet",
  prompt="Check bd ready, claim a task with bd update <id> --claim, complete it, close with bd close <id> --reason '...'")

# Workers atomically claim and complete tasks
# Coordinator monitors: bd status
```
