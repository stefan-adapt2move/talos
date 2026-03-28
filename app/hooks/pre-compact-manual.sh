#!/bin/bash
# PreCompact (manual) Hook: Same as auto but with emphasis on thoroughness
# For trigger sessions: uses channel-specific templates
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

  # Phase 1: Pre-compaction — save state to memory (be thorough)
  PRE_COMPACT=$(resolve_template "pre-compact")
  if [ -n "$PRE_COMPACT" ]; then
    echo "<system-notice>"
    echo "Manual compaction requested. Be thorough — detailed context will be lost."
    echo ""
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
Manual compaction requested. Consolidate ALL important findings:

1. Write lasting facts, decisions, and preferences to memory/MEMORY.md
2. Write task results and context to memory/journal/${TODAY}.md
3. If a project topic is relevant, create/update memory/projects/
4. If managing a team or coordinating agents, save current task state, decisions, and progress
5. Save any in-flight coordination context that would be lost after compaction

Be thorough — detailed context will be lost after compaction.
EOF
echo "</system-notice>"
