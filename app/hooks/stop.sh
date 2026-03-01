#!/bin/bash
# Stop Hook: Session lifecycle management
set -euo pipefail

# All session types: just exit, lifecycle is managed externally
# - Trigger: watcher handles re-awakening
# - Worker-ephemeral: task-runner manages lifecycle
# - Reviewer: task-runner manages lifecycle
exit 0
