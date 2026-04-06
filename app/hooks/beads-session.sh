#!/bin/bash
# beads-session.sh — Per-session Beads task management wrapper.
# Ensures each Claude Code session gets its own isolated .beads/ directory.
#
# Usage (from hooks):
#   beads-session.sh start   — Init session dir, set BEADS_DIR env, run bd prime
#   beads-session.sh prime   — Show open tasks for this session (context injection)
#   beads-session.sh check   — Output open task status (for stop hook evaluation)
#   beads-session.sh cleanup — Remove this session's beads directory
#
# Session identification priority:
#   1. session_id from Claude Code hook stdin JSON (single source of truth)
#   2. BEADS_DIR env var (already set by CLAUDE_ENV_FILE from SessionStart)
#   3. ATLAS_TRIGGER_SESSION_KEY (trigger sessions)
#   4. PPID fallback
set -euo pipefail

SESSIONS_DIR="$HOME/.beads-sessions"

# --- Resolve session directory ---
# For `start`: always read session_id from stdin (Claude Code provides it).
# For other commands: prefer BEADS_DIR (set via CLAUDE_ENV_FILE), fall back to stdin.
resolve_session_dir() {
  # If BEADS_DIR is already set and points to a session dir, use it directly
  if [ -n "${BEADS_DIR:-}" ] && [[ "$BEADS_DIR" == "$SESSIONS_DIR/"* ]]; then
    echo "$BEADS_DIR"
    return
  fi

  local sid=""

  # Try stdin JSON (Claude Code hook input — contains session_id)
  if [ ! -t 0 ]; then
    sid=$(timeout 1 cat 2>/dev/null | jq -r '.session_id // empty' 2>/dev/null) || true
  fi

  # Fallback: trigger session key (set by trigger.sh)
  if [ -z "$sid" ]; then
    sid="${ATLAS_TRIGGER_SESSION_KEY:-}"
  fi

  # Fallback: PPID
  if [ -z "$sid" ]; then
    sid="ppid-${PPID:-$$}"
  fi

  echo "$SESSIONS_DIR/$sid"
}

SESSION_DIR=$(resolve_session_dir)

# --- Commands ---
case "${1:-help}" in
  start)
    # Initialize beads for this session if not already done
    if [ ! -d "$SESSION_DIR" ]; then
      mkdir -p "$SESSION_DIR"
      BEADS_DIR="$SESSION_DIR" bd init --quiet 2>/dev/null || true
    fi

    # Propagate BEADS_DIR to all subsequent Bash tool calls via CLAUDE_ENV_FILE.
    # This is the canonical way to share hook-derived state with agent commands.
    if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
      echo "export BEADS_DIR=\"$SESSION_DIR\"" >> "$CLAUDE_ENV_FILE"
    fi

    # Output current task context
    BEADS_DIR="$SESSION_DIR" bd prime 2>/dev/null || true
    ;;

  prime)
    # Output task context for compaction and context recovery.
    # Called by PreCompact hooks — output gets included in the compaction summary,
    # ensuring task state survives context compression.
    if [ -d "$SESSION_DIR" ]; then
      # Show suspend reason if present (read-only — check command handles deletion)
      if [ -f "$SESSION_DIR/.suspend" ]; then
        echo "<beads-previous-suspend>"
        echo "Session was suspended: $(cat "$SESSION_DIR/.suspend" 2>/dev/null)"
        echo "Review open tasks below and continue where the previous session left off."
        echo "</beads-previous-suspend>"
      fi
      echo "<beads-task-context>"
      BEADS_DIR="$SESSION_DIR" bd prime 2>/dev/null || true
      echo "</beads-task-context>"
    fi
    ;;

  check)
    # Stop hook completion gate (RalphLoop-style).
    # Four exit paths in order:
    #   1. .suspend file exists → delete + allow exit (reminder-triggered pause)
    #   2. .stop-reason file exists → delete + allow exit (agent-initiated early exit)
    #   3. No open tasks → allow exit
    #   4. Open tasks remain → block exit with task list
    if [ ! -d "$SESSION_DIR" ]; then
      exit 0
    fi

    # Path 1: Suspend protocol — reminder-triggered pause with open tasks.
    # The agent creates .suspend when setting a reminder to continue later.
    # Usage: echo "Waiting for user input" > $BEADS_DIR/.suspend
    SUSPEND_FILE="$SESSION_DIR/.suspend"
    if [ -f "$SUSPEND_FILE" ]; then
      SUSPEND_REASON=$(cat "$SUSPEND_FILE" 2>/dev/null || echo "Session suspended")
      rm -f "$SUSPEND_FILE"
      echo "<beads-session-suspended>"
      echo "Session suspended: $SUSPEND_REASON"
      echo "</beads-session-suspended>"
      exit 0
    fi

    # Path 2: Stop-reason protocol — agent-initiated early exit with JSON justification.
    # The agent writes a JSON file to exit despite open tasks (non-reminder case).
    # Usage: echo '{"reason":"Need clarification from user"}' > $BEADS_DIR/.stop-reason
    STOP_REASON_FILE="$SESSION_DIR/.stop-reason"
    if [ -f "$STOP_REASON_FILE" ]; then
      STOP_REASON=$(cat "$STOP_REASON_FILE" 2>/dev/null || echo '{"reason":"Agent requested stop"}')
      rm -f "$STOP_REASON_FILE"
      echo "<beads-stop-reason>"
      echo "$STOP_REASON"
      echo "</beads-stop-reason>"
      exit 0
    fi

    # Path 3: No open tasks → allow exit
    READY_OUTPUT=$(BEADS_DIR="$SESSION_DIR" bd ready --json 2>/dev/null) || true

    if [ -z "$READY_OUTPUT" ] || [ "$READY_OUTPUT" = "[]" ] || [ "$READY_OUTPUT" = "null" ]; then
      exit 0
    fi

    OPEN_COUNT=$(echo "$READY_OUTPUT" | jq 'length' 2>/dev/null) || OPEN_COUNT=0
    if [ "$OPEN_COUNT" -eq 0 ]; then
      exit 0
    fi

    # Path 4: Open tasks remain → block exit
    TASK_SUMMARY=$(echo "$READY_OUTPUT" | jq -r '.[] | "- [\(.id)] \(.title // .summary // "untitled")"' 2>/dev/null) || TASK_SUMMARY="$OPEN_COUNT open tasks"

    cat <<BLOCKJSON
{"decision":"block","reason":"You have $OPEN_COUNT open Beads task(s). Complete or close them before exiting:\n$TASK_SUMMARY\n\nTo exit cleanly, either:\n- Close tasks: bd close <id> \"reason\"\n- Stop with reason: echo '{\"reason\":\"your justification\"}' > \$BEADS_DIR/.stop-reason\n- Suspend for reminder: echo \"reason\" > \$BEADS_DIR/.suspend"}
BLOCKJSON
    ;;

  cleanup)
    # Remove session beads directory (called by daily cleanup)
    if [ -d "$SESSION_DIR" ]; then
      rm -rf "$SESSION_DIR"
    fi
    ;;

  *)
    echo "Usage: beads-session.sh {start|prime|check|cleanup}" >&2
    exit 1
    ;;
esac
