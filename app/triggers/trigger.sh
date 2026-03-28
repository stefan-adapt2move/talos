#!/bin/bash
# Trigger runner — delegates to native compiled binary
set -euo pipefail
exec /talos/app/triggers/trigger-runner "$@"
