#!/bin/bash
# beads-session.sh — Global Beads task management wrapper.
# Uses a single global BEADS_DIR at ~/.beads that persists across sessions.
#
# Usage (from hooks):
#   beads-session.sh start   — Set BEADS_DIR env, run bd prime
#   beads-session.sh prime   — Show open tasks (context injection for compaction)
#   beads-session.sh check   — Stop hook: block if there are in_progress tasks
set -euo pipefail

BEADS_DIR_PATH="$HOME/.beads"

# --- Commands ---
case "${1:-help}" in
  start)
    # Set global BEADS_DIR via CLAUDE_ENV_FILE so all subsequent Bash tool calls inherit it.
    if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
      echo "export BEADS_DIR=\"$BEADS_DIR_PATH\"" >> "$CLAUDE_ENV_FILE"
    fi

    # Show current task context
    BEADS_DIR="$BEADS_DIR_PATH" bd prime 2>/dev/null || true
    ;;

  prime)
    # Output task context for compaction and context recovery.
    # Show suspend reason if present, then show open tasks wrapped in tags.
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
    # Three exit paths in order:
    #   1. .suspend file exists → delete + allow exit (reminder/pause scenario)
    #   2. .stop-reason file exists → delete + allow exit (agent-initiated early exit)
    #   3. Check for in_progress tasks → block if any exist

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

    # Path 3: Check for in_progress tasks (= claimed by agent)
    TASK_OUTPUT=$(BEADS_DIR="$BEADS_DIR_PATH" bd list --status in_progress --json 2>/dev/null) || true

    if [ -z "$TASK_OUTPUT" ] || [ "$TASK_OUTPUT" = "[]" ] || [ "$TASK_OUTPUT" = "null" ]; then
      exit 0
    fi

    OPEN_COUNT=$(echo "$TASK_OUTPUT" | jq 'length' 2>/dev/null) || OPEN_COUNT=0
    if [ "$OPEN_COUNT" -eq 0 ]; then
      exit 0
    fi

    # in_progress tasks exist → block exit
    TASK_SUMMARY=$(echo "$TASK_OUTPUT" | jq -r '.[] | "- [\(.id)] \(.title // .summary // "untitled")"' 2>/dev/null) || TASK_SUMMARY="$OPEN_COUNT open tasks"

    cat <<BLOCKJSON
{"decision":"block","reason":"You have $OPEN_COUNT in-progress Beads task(s). Complete or close them before exiting:\n$TASK_SUMMARY\n\nTo exit cleanly, either:\n- Close tasks: bd close <id> --reason \"reason\"\n- Stop with reason: echo '{\"reason\":\"your justification\"}' > \$BEADS_DIR/.stop-reason\n- Suspend for reminder: echo \"reason\" > \$BEADS_DIR/.suspend"}
BLOCKJSON
    ;;

  *)
    echo "Usage: beads-session.sh {start|prime|check}" >&2
    exit 1
    ;;
esac
