# Lifecycle Hooks

Claude Code hooks inject context at lifecycle events. Hooks are shell scripts or prompts that execute automatically — their output becomes part of Claude's context.

## session-start.sh

Runs when any Claude Code session starts (trigger sessions and agent teammates).

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

## stop.sh

Runs after Claude finishes a response.

### Journal Reminder (Trigger Sessions Only)

For trigger sessions (`ATLAS_TRIGGER` is set), the stop hook checks if a journal file for today exists in `memory/journal/`. If no file matching `YYYY-MM-DD*.md` is found, it outputs a `<system-notice>` reminding the session to write a journal entry before ending.

## beads-session.sh

Manages Beads task context across session lifecycle events. Configured as command-type hooks in `settings.json`.

### beads-session.sh start (SessionStart hook)

Runs when any Claude Code session starts.

- Writes `export BEADS_DIR` and `export BEADS_ACTOR` to `CLAUDE_ENV_FILE` so all subsequent Bash tool calls inherit them
- Derives `BEADS_ACTOR` (as `session-<session_id>`) from the session_id in hook stdin JSON, falling back to `ATLAS_TRIGGER_SESSION_KEY`
- Runs `bd prime` and wraps output in `<beads-task-context>` to surface open task context at session start

### beads-session.sh prime (PreCompact hook)

Runs before automatic or manual context compaction.

- Checks for a `.suspend-<session_id>` file from a previous session; if found, outputs a `<beads-previous-suspend>` block with the reason
- Runs `bd prime` wrapped in `<beads-task-context>` to inject task state so the compacted context retains task continuity

### beads-session.sh check (Stop hook)

Runs after each response as a completion gate. Three exit paths:

1. **Suspend file** — If `.suspend-<session_id>` exists: delete it, emit a `<beads-session-suspended>` notice, and allow exit
2. **Stop-reason file** — If `.stop-reason-<session_id>` exists: delete it, emit a `<beads-stop-reason>` block, and allow exit
3. **Open tasks** — If `bd list --assignee <actor> --status in_progress` returns results: emit `{"decision":"block","reason":"..."}` JSON to block exit until tasks are closed

## pre-compact-auto.sh

Runs before automatic context compaction.

### Trigger Session Mode

Uses channel-specific templates:
- `app/prompts/trigger-{CHANNEL}-pre-compact.md`
- `app/prompts/trigger-pre-compact.md` (fallback)

### Other Sessions

Outputs generic memory flush instructions.

## pre-compact-manual.sh

Runs before manual context compaction (when user runs `/compact`). Same behavior as `pre-compact-auto.sh`.

## SubagentStop (prompt-type hook)

Configured in `settings.json` as a prompt-type hook. Fires in the trigger session when an agent teammate finishes. Asks the trigger session to evaluate whether the teammate's result is complete and acceptable, or needs rework.

Configured via `generate-settings.ts` — the model used for this review is set by `subagent_review` in `config.yml`.

## Source

- `app/hooks/session-start.sh` — Context loading
- `app/hooks/stop.sh` — Session lifecycle
- `app/hooks/beads-session.sh` — Beads task context (SessionStart, PreCompact, Stop)
- `app/hooks/pre-compact-auto.sh` — Memory flush (auto compaction)
- `app/hooks/pre-compact-manual.sh` — Memory flush (manual compaction)
- `app/hooks/generate-settings.ts` — Generates `~/.claude/settings.json` with hook config
