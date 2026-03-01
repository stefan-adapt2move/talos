#!/bin/bash
# Stop Hook: Session lifecycle management
set -euo pipefail

CLEANUP_DONE="$HOME/.cleanup-done"

# Daily cleanup mode - just signal done and exit
if [ "${ATLAS_CLEANUP:-}" = "1" ]; then
  touch "$CLEANUP_DONE"
  exit 0
fi

# Trigger session mode — just exit, watcher handles re-awakening
if [ -n "${ATLAS_TRIGGER:-}" ]; then
  exit 0
fi

# Ephemeral worker mode — task-runner manages lifecycle, just exit
if [ "${ATLAS_WORKER_EPHEMERAL:-}" = "1" ]; then
  exit 0
fi

# Reviewer mode — task-runner manages lifecycle, just exit
if [ "${ATLAS_REVIEWER:-}" = "1" ]; then
  exit 0
fi

exit 0
