# Lifecycle Hooks

Claude Code hooks inject context at lifecycle events. Hooks are shell scripts that output text — the output becomes part of Claude's context.

## session-start.sh

Runs when Claude wakes up. Loads memory context and inbox status.

### Ephemeral Worker / Reviewer Mode

If `ATLAS_WORKER_EPHEMERAL=1` or `ATLAS_REVIEWER=1`, the hook exits immediately. These sessions don't need memory context — the task description provides all necessary context.

### Trigger Mode

Outputs XML-wrapped sections:

1. **Long-term memory** — Full `memory/MEMORY.md` content:
   ```xml
   <long-term-memory>
   (content of MEMORY.md)
   </long-term-memory>
   ```

2. **Recent journals** — List of recent journal files (last 7 days):
   ```xml
   <recent-journals>
     2026-02-24 (45 lines) — Daily standup and project updates
     2026-02-23 (12 lines) — Code review session
   </recent-journals>
   ```

3. **Inbox status** — Pending task count (only if > 0):
   ```xml
   <inbox-status>
   You have 3 pending task(s) in the queue. Workers are dispatched automatically.
   </inbox-status>
   ```

## stop.sh

Runs after Claude finishes a response. Handles session lifecycle.

### Session Mode Behavior

| Mode | Environment Variable | Behavior |
|------|---------------------|----------|
| Daily cleanup | `ATLAS_CLEANUP=1` | Touch `.cleanup-done`, exit 0 |
| Trigger | `ATLAS_TRIGGER` set | Exit 0 (watcher handles re-awakening) |
| Ephemeral worker | `ATLAS_WORKER_EPHEMERAL=1` | Exit 0 (task-runner manages lifecycle) |
| Reviewer | `ATLAS_REVIEWER=1` | Exit 0 (task-runner manages lifecycle) |

## pre-compact-auto.sh

Runs before automatic context compaction. Prompts memory flush.

### Trigger Session Mode

Uses channel-specific templates:
- `app/prompts/trigger-{CHANNEL}-pre-compact.md`
- `app/prompts/trigger-pre-compact.md` (fallback)

### Main Session Mode

Outputs generic memory flush instructions.

## pre-compact-manual.sh

Runs before manual context compaction (when user runs `/compact`). Same behavior as `pre-compact-auto.sh`.

## subagent-stop.sh

Runs when a team member (subagent) finishes. Quality gate that prompts evaluation.

## Source

- `app/hooks/session-start.sh` — Context loading
- `app/hooks/stop.sh` — Session lifecycle
- `app/hooks/pre-compact-auto.sh` — Memory flush (auto compaction)
- `app/hooks/pre-compact-manual.sh` — Memory flush (manual compaction)
- `app/hooks/subagent-stop.sh` — Quality gate
