#!/bin/bash
# Trigger runner — delegates to native compiled binary
set -euo pipefail
exec /atlas/app/triggers/trigger-runner "$@"
