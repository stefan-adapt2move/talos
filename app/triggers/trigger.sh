#!/bin/bash
# Trigger runner — delegates to TypeScript implementation
set -euo pipefail
exec bun run /atlas/app/triggers/trigger-runner.ts "$@"
