#!/bin/bash
# beads-session.sh — Global Beads task management wrapper.
# Uses a single global BEADS_DIR at ~/.beads that persists across sessions.
# Each session gets a unique BEADS_ACTOR derived from session_id for claim ownership.
#
# Usage (from hooks):
#   beads-session.sh start   — Set BEADS_DIR + BEADS_ACTOR env, run bd prime
#   beads-session.sh prime   — Show open tasks (context injection for compaction)
#   beads-session.sh check   — Stop hook: block if THIS session has in_progress tasks
#
# Note: BEADS_ACTOR is NOT read from env in check — it's derived from stdin
# session_id, because hooks run as separate processes without CLAUDE_ENV_FILE vars.
set -euo pipefail

BEADS_DIR_PATH="$HOME/.beads"

# Read session_id from Claude Code hook stdin JSON.
# Used by both start (to set actor) and check (to verify ownership).
# Stdin is consumed once — call only once per invocation.
read_session_id() {
  if [ ! -t 0 ]; then
    local stdin_json
    stdin_json=$(timeout 0.1 cat 2>/dev/null) || true
    echo "$stdin_json" | jq -r '.session_id // empty' 2>/dev/null || true
  fi
}

# --- Commands ---
case "${1:-help}" in
  start)
    # Set global BEADS_DIR via CLAUDE_ENV_FILE so all subsequent Bash tool calls inherit it.
    if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
      echo "export BEADS_DIR=\"$BEADS_DIR_PATH\"" >> "$CLAUDE_ENV_FILE"
    fi

    # Derive actor from session_id. Each session claims tasks under its own identity.
    SESSION_ID=$(read_session_id)
    if [ -z "${SESSION_ID:-}" ]; then
      SESSION_ID="${ATLAS_TRIGGER_SESSION_KEY:-default}"
    fi
    ACTOR="session-${SESSION_ID}"

    if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
      echo "export BEADS_ACTOR=\"$ACTOR\"" >> "$CLAUDE_ENV_FILE"
    fi

    # Show current task context (wrapped for consistency with prime)
    echo "<beads-task-context>"
    BEADS_DIR="$BEADS_DIR_PATH" bd prime 2>/dev/null || true
    echo "</beads-task-context>"
    ;;

  prime)
    # Output task context for compaction and context recovery.
    if [ -f "$BEADS_DIR_PATH/.suspend" ]; then
      echo "<beads-previous-suspend>"
      echo "Session was suspended: $(cat "$BEADS_DIR_PATH/.suspend" 2>/dev/null)"
      echo "Review open tasks below and continue where the previous session left off."
      echo "</beads-previous-suspend>"
    fi
    echo "<beads-task-context>"
    BEADS_DIR="$BEADS_DIR_PATH" bd prime 2>/dev/null || true
    echo "</beads-task-context>"
    ;;

  check)
    # Stop hook completion gate.
    # Three exit paths:
    #   1. .suspend file exists → delete + allow exit
    #   2. .stop-reason file exists → delete + allow exit
    #   3. in_progress tasks owned by THIS session → block

    # Path 1: Suspend protocol
    SUSPEND_FILE="$BEADS_DIR_PATH/.suspend"
    if [ -f "$SUSPEND_FILE" ]; then
      SUSPEND_REASON=$(cat "$SUSPEND_FILE" 2>/dev/null || echo "Session suspended")
      rm -f "$SUSPEND_FILE"
      echo "<beads-session-suspended>"
      echo "Session suspended: $SUSPEND_REASON"
      echo "</beads-session-suspended>"
      exit 0
    fi

    # Path 2: Stop-reason protocol
    STOP_REASON_FILE="$BEADS_DIR_PATH/.stop-reason"
    if [ -f "$STOP_REASON_FILE" ]; then
      STOP_REASON=$(cat "$STOP_REASON_FILE" 2>/dev/null || echo '{"reason":"Agent requested stop"}')
      rm -f "$STOP_REASON_FILE"
      echo "<beads-stop-reason>"
      echo "$STOP_REASON"
      echo "</beads-stop-reason>"
      exit 0
    fi

    # Path 3: Derive actor from stdin session_id (NOT from env — hooks don't inherit CLAUDE_ENV_FILE)
    SESSION_ID=$(read_session_id)
    if [ -z "${SESSION_ID:-}" ]; then
      exit 0
    fi
    ACTOR="session-${SESSION_ID}"

    TASK_OUTPUT=$(BEADS_DIR="$BEADS_DIR_PATH" bd list --assignee "$ACTOR" --status in_progress --json 2>/dev/null) || true

    if [ -z "$TASK_OUTPUT" ] || [ "$TASK_OUTPUT" = "[]" ] || [ "$TASK_OUTPUT" = "null" ]; then
      exit 0
    fi

    OPEN_COUNT=$(echo "$TASK_OUTPUT" | jq 'length' 2>/dev/null || echo "0")
    if ! [[ "$OPEN_COUNT" =~ ^[0-9]+$ ]] || [ "$OPEN_COUNT" -eq 0 ]; then
      exit 0
    fi

    # Build task summary and emit valid JSON via jq (avoids newline escaping bugs)
    TASK_LIST=$(echo "$TASK_OUTPUT" | jq -r '[.[] | "- [\(.id)] \(.title // .summary // "untitled")"] | join("\n")' 2>/dev/null) || TASK_LIST="$OPEN_COUNT open tasks"

    jq -n --arg count "$OPEN_COUNT" --arg tasks "$TASK_LIST" '{
      decision: "block",
      reason: ("You have " + $count + " in-progress Beads task(s). Complete or close them before exiting:\n" + $tasks + "\n\nTo exit cleanly, either:\n- Close tasks: bd close <id> --reason \"reason\"\n- Stop with reason: echo \u0027{\"reason\":\"your justification\"}\u0027 > $BEADS_DIR/.stop-reason\n- Suspend for reminder: echo \"reason\" > $BEADS_DIR/.suspend")
    }'
    ;;

  *)
    echo "Usage: beads-session.sh {start|prime|check}" >&2
    exit 1
    ;;
esac
