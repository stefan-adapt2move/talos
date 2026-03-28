#!/bin/bash
# PreCompact (auto) Hook: Memory flush before context compaction
# For trigger sessions: uses channel-specific pre-compact + compact templates
# For main session: uses generic memory flush instructions
set -euo pipefail

TODAY=$(date +%Y-%m-%d)
PROMPT_DIR="/atlas/app/prompts"

# Resolve trigger env vars dynamically based on APP_NAME
APP_NAME="${APP_NAME:-Atlas}"
APP_NAME_UPPER=$(echo "$APP_NAME" | tr '[:lower:]' '[:upper:]')
_TRIGGER_VAR="${APP_NAME_UPPER}_TRIGGER"
_TRIGGER_CHANNEL_VAR="${APP_NAME_UPPER}_TRIGGER_CHANNEL"
_CURRENT_TRIGGER="${!_TRIGGER_VAR:-}"
_CURRENT_CHANNEL="${!_TRIGGER_CHANNEL_VAR:-internal}"

# Helper: resolve channel-specific template with fallback
resolve_template() {
  local suffix="$1"
  for candidate in "$PROMPT_DIR/trigger-${CHANNEL}-${suffix}.md" "$PROMPT_DIR/trigger-${suffix}.md"; do
    if [ -f "$candidate" ]; then
      echo "$candidate"
      return
    fi
  done
}

# --- Trigger session: channel-specific compaction ---
if [ -n "$_CURRENT_TRIGGER" ]; then
  CHANNEL="${_CURRENT_CHANNEL}"
  TRIGGER_NAME="$_CURRENT_TRIGGER"

  # Phase 1: Pre-compaction — save state to memory
  PRE_COMPACT=$(resolve_template "pre-compact")
  if [ -n "$PRE_COMPACT" ]; then
    echo "<system-notice>"
    sed -e "s|{{trigger_name}}|${TRIGGER_NAME}|g" \
        -e "s|{{channel}}|${CHANNEL}|g" \
        -e "s|{{today}}|${TODAY}|g" \
        "$PRE_COMPACT"
    echo "(Journal file: memory/journal/${TODAY}.md)"
    echo "</system-notice>"
  fi

  echo ""

  # Phase 2: Post-compaction context — should survive compaction
  COMPACT=$(resolve_template "compact")
  if [ -n "$COMPACT" ]; then
    echo "<system-reminder>"
    sed -e "s|{{trigger_name}}|${TRIGGER_NAME}|g" \
        -e "s|{{channel}}|${CHANNEL}|g" \
        "$COMPACT"
    echo "</system-reminder>"
  fi

  exit 0
fi

# --- Main session: generic memory flush ---

echo "<system-notice>"
cat << EOF
Context is about to be compressed. Consolidate important findings:

1. Write lasting facts, decisions, and preferences to memory/MEMORY.md
2. Write task results and daily context to memory/journal/${TODAY}.md
3. If a project topic is relevant, create/update a file in memory/projects/
4. If managing a team or coordinating agents, save current task state, decisions, and progress
5. Save any in-flight coordination context that would be lost after compaction

MEMORY.md is for long-term, timeless information. The journal is for daily details (append-only).
Only write what is truly relevant, no noise. Perform the memory flush now.
EOF
echo "</system-notice>"
