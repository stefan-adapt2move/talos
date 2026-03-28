#!/bin/bash
set -euo pipefail

EVENT_TYPE="${1:?Usage: event.sh <event-type>}"
EVENT_PROMPT="$HOME/triggers/cron/${EVENT_TYPE}/event-prompt.md"

if [ ! -f "$EVENT_PROMPT" ]; then
  echo "[$(date)] No event-prompt found for: $EVENT_TYPE" >> /talos/logs/cron.log
  exit 0
fi

echo "[$(date)] Cron event: $EVENT_TYPE" >> /talos/logs/cron.log

# Start autonomous Claude session with event prompt (cron model via TALOS_CRON)
export TALOS_CRON=1
/talos/app/triggers/trigger-runner --direct "$(cat "$EVENT_PROMPT")" --channel internal 2>&1 | tee -a /talos/logs/cron.log || true
