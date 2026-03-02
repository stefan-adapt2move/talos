#!/bin/bash
# Task Runner: Orchestrates the lifecycle of a single task.
# Spawns an ephemeral worker, optionally runs a review loop, then completes the task.
# Usage: task-runner.sh <task_id>
set -euo pipefail

export PATH=/atlas/app/bin:/usr/local/bin:/usr/bin:/bin:$PATH

TASK_ID="${1:?Usage: task-runner.sh <task_id>}"
WORKSPACE="$HOME"
DB="$WORKSPACE/.index/atlas.db"
APP_DIR="/atlas/app"
LOG="/atlas/logs/task-runner-${TASK_ID}.log"
PID_FILE="/tmp/task-runner-${TASK_ID}.pid"
TASK_HELPERS="$APP_DIR/inbox-mcp"

# Write PID file for crash recovery
echo $$ > "$PID_FILE"

log() { echo "[$(date)] [task:$TASK_ID] $*" | tee -a "$LOG"; }

# Track temp files for cleanup
TEMP_FILES=()

cleanup() {
  # Release path lock
  bun run "$TASK_HELPERS/release-lock.ts" "$TASK_ID" 2>/dev/null || true
  rm -f "$PID_FILE"
  # Clean up any temp files
  for f in "${TEMP_FILES[@]}"; do
    rm -f "$f" 2>/dev/null || true
  done
  # Signal watcher to dispatch next pending tasks
  touch "$WORKSPACE/.index/.wake"
}
trap cleanup EXIT

# Read max_review_iterations from config
read_config() {
  local CONFIG=""
  if [ -f "$HOME/config.yml" ]; then
    CONFIG="$HOME/config.yml"
  elif [ -f "$APP_DIR/defaults/config.yml" ]; then
    CONFIG="$APP_DIR/defaults/config.yml"
  fi
  MAX_REVIEW_ITERATIONS=5
  if [ -n "$CONFIG" ]; then
    local PARSED
    PARSED=$(python3 -c "import yaml, sys; print(yaml.safe_load(open(sys.argv[1])).get('workers',{}).get('max_review_iterations', 5))" "$CONFIG" 2>/dev/null) || true
    if [ -n "$PARSED" ]; then
      MAX_REVIEW_ITERATIONS="$PARSED"
    fi
  fi
}

# Save session metrics to DB (already uses parameterized queries via Python)
save_session_metrics() {
  local JSON_FILE="$1" SESSION_TYPE="$2" TRIGGER_NAME="$3"
  local STARTED_AT="$4" ENDED_AT="$5" EXIT_CODE="${6:-0}"
  [ -f "$JSON_FILE" ] || return 0
  python3 - "$JSON_FILE" "$SESSION_TYPE" "$TRIGGER_NAME" \
            "$STARTED_AT" "$ENDED_AT" "$EXIT_CODE" << 'PYEOF'
import json, sys, sqlite3, os
f, stype, tname, started, ended, exit_code = sys.argv[1:]
try:
    d = json.load(open(f))
except:
    d = {}
usage = d.get('usage') or {}
db_path = os.environ.get('HOME', '') + '/.index/atlas.db'
conn = sqlite3.connect(db_path)
conn.execute('''INSERT INTO session_metrics
  (session_type, session_id, trigger_name, started_at, ended_at,
   duration_ms, input_tokens, output_tokens, cache_read_tokens,
   cache_creation_tokens, cost_usd, num_turns, is_error)
  VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)''', (
    stype,
    d.get('session_id', '') or '',
    tname or '',
    started, ended,
    int(d.get('duration_ms') or 0),
    int(usage.get('input_tokens') or 0),
    int(usage.get('output_tokens') or 0),
    int(usage.get('cache_read_input_tokens') or 0),
    int(usage.get('cache_creation_input_tokens') or 0),
    float(d.get('total_cost_usd') or d.get('cost_usd') or 0),
    int(d.get('num_turns') or 0),
    1 if str(exit_code) != '0' else 0,
))
conn.commit()
conn.close()
PYEOF
}

# Safe task updates via parameterized helper (no SQL injection)
task_update() {
  local CMD="$1"
  shift
  if [ "$#" -gt 0 ]; then
    bun run "$TASK_HELPERS/update-task.ts" "$TASK_ID" "$CMD" "$@" 2>/dev/null || true
  else
    bun run "$TASK_HELPERS/update-task.ts" "$TASK_ID" "$CMD" 2>/dev/null || true
  fi
}

# Pipe value to task update (for large/unsafe content)
task_update_stdin() {
  local CMD="$1"
  bun run "$TASK_HELPERS/update-task.ts" "$TASK_ID" "$CMD" 2>/dev/null || true
}

# Mark task as failed with error message
mark_failed() {
  local ERROR_MSG="$1"
  printf '%s' "$ERROR_MSG" | task_update_stdin "failed"
  # Wake trigger with error
  bun run "$TASK_HELPERS/wake-trigger.ts" "$TASK_ID" "Task failed: $ERROR_MSG" 2>/dev/null || true
}

# Extract fields from Claude's JSON output using jq
extract_result() {
  jq -r '.result // ""' "$1" 2>/dev/null || echo ""
}

extract_session_id() {
  jq -r '.session_id // ""' "$1" 2>/dev/null || echo ""
}

# === MAIN ===

log "Starting task runner"
read_config

# 1. Read task from DB
TASK_JSON=$(sqlite3 -json "$DB" "SELECT * FROM tasks WHERE id=$TASK_ID AND status='pending' LIMIT 1;" 2>/dev/null || echo "[]")
if [ "$TASK_JSON" = "[]" ] || [ -z "$TASK_JSON" ]; then
  log "Task $TASK_ID not found or not pending, exiting"
  exit 0
fi

TASK_CONTENT=$(printf '%s' "$TASK_JSON" | jq -r '.[0].content')
TASK_PATH=$(printf '%s' "$TASK_JSON" | jq -r '.[0].path // empty')
TASK_REVIEW=$(printf '%s' "$TASK_JSON" | jq -r '.[0].review // 1')
TRIGGER_NAME=$(printf '%s' "$TASK_JSON" | jq -r '.[0].trigger_name // ""')

log "Task loaded: path=${TASK_PATH:-<none>} review=$TASK_REVIEW"

# 2. Acquire path lock (if path is set)
if [ -n "$TASK_PATH" ]; then
  LOCK_RESULT=$(bun run "$TASK_HELPERS/acquire-lock.ts" "$TASK_ID" "$TASK_PATH" "$$" 2>/dev/null)
  if [ "$LOCK_RESULT" != "acquired" ]; then
    log "Path lock conflict ($LOCK_RESULT), leaving task pending"
    # Don't mark failed — just exit and let watcher retry later
    rm -f "$PID_FILE"
    trap - EXIT  # Don't run cleanup (which would release lock and touch .wake)
    exit 0
  fi
  log "Path lock acquired: $TASK_PATH"
fi

# 3. Set task to processing
task_update "processing"

# 4. Determine working directory
WORK_DIR="$WORKSPACE"
if [ -n "$TASK_PATH" ] && [ -d "$TASK_PATH" ]; then
  WORK_DIR="$TASK_PATH"
fi

# 5. Spawn ephemeral worker session
log "Spawning worker session (cwd=$WORK_DIR)"
WORKER_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
WORKER_OUT=$(mktemp /tmp/worker-out-XXXXXX.json)
TEMP_FILES+=("$WORKER_OUT")
WORKER_SESSION_ID=""

set +e
(cd "$WORK_DIR" && claude-atlas --mode worker-ephemeral --output-format json \
  --dangerously-skip-permissions \
  -p "$TASK_CONTENT" > "$WORKER_OUT" 2>>"$LOG")
WORKER_EXIT=$?
set -e

WORKER_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
WORKER_SESSION_ID=$(extract_session_id "$WORKER_OUT")
WORKER_RESULT=$(extract_result "$WORKER_OUT")

save_session_metrics "$WORKER_OUT" "worker" "$TRIGGER_NAME" "$WORKER_START" "$WORKER_END" "$WORKER_EXIT"

if [ "$WORKER_EXIT" -ne 0 ] && [ -z "$WORKER_RESULT" ]; then
  log "Worker session failed with exit $WORKER_EXIT"
  mark_failed "Worker session crashed (exit code $WORKER_EXIT)"
  exit 1
fi

log "Worker session completed (exit=$WORKER_EXIT)"

# Store worker result in DB (safe, via stdin)
printf '%s' "$WORKER_RESULT" | task_update_stdin "worker_result"

# 6. Review loop (if review is enabled)
if [ "$TASK_REVIEW" = "1" ]; then
  REVIEW_ITERATION=0
  REVIEWER_SESSION_ID=""

  while [ "$REVIEW_ITERATION" -lt "$MAX_REVIEW_ITERATIONS" ]; do
    REVIEW_ITERATION=$((REVIEW_ITERATION + 1))
    log "Review iteration $REVIEW_ITERATION/$MAX_REVIEW_ITERATIONS"

    # Update task status
    task_update "reviewing" "$REVIEW_ITERATION"

    # Build reviewer prompt
    REVIEWER_PROMPT="## Task Under Review

### Original Task Description
$TASK_CONTENT

### Worker Result (Iteration $REVIEW_ITERATION)
$WORKER_RESULT"

    if [ -n "$TASK_PATH" ]; then
      REVIEWER_PROMPT="$REVIEWER_PROMPT

### Working Directory
$TASK_PATH

Note: This is a code task. In addition to checking completeness against the acceptance criteria, also review changed files for code quality, security, and performance using the established review standards."
    fi

    # Spawn reviewer session
    REVIEW_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    REVIEW_OUT=$(mktemp /tmp/review-out-XXXXXX.json)
    TEMP_FILES+=("$REVIEW_OUT")

    set +e
    if [ -n "$REVIEWER_SESSION_ID" ]; then
      (cd "$WORK_DIR" && claude-atlas --mode reviewer --output-format json \
        --resume "$REVIEWER_SESSION_ID" \
        -p "$REVIEWER_PROMPT" > "$REVIEW_OUT" 2>>"$LOG")
    else
      (cd "$WORK_DIR" && claude-atlas --mode reviewer --output-format json \
        -p "$REVIEWER_PROMPT" > "$REVIEW_OUT" 2>>"$LOG")
    fi
    REVIEW_EXIT=$?
    set -e

    REVIEW_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    REVIEWER_SESSION_ID=$(extract_session_id "$REVIEW_OUT")
    REVIEW_RESULT=$(extract_result "$REVIEW_OUT")

    save_session_metrics "$REVIEW_OUT" "reviewer" "$TRIGGER_NAME" "$REVIEW_START" "$REVIEW_END" "$REVIEW_EXIT"
    rm -f "$REVIEW_OUT"

    if [ "$REVIEW_EXIT" -ne 0 ] && [ -z "$REVIEW_RESULT" ]; then
      log "Reviewer crashed (exit=$REVIEW_EXIT), accepting worker result as-is"
      break
    fi

    # Parse verdict from reviewer result (handles nested JSON like issues arrays)
    VERDICT=$(python3 -c "
import json, sys, re
text = sys.argv[1]
# Find all JSON objects (including nested braces) using a brace-depth counter
def find_json_objects(s):
    results = []
    i = 0
    while i < len(s):
        if s[i] == '{':
            depth = 0
            start = i
            while i < len(s):
                if s[i] == '{': depth += 1
                elif s[i] == '}': depth -= 1
                if depth == 0:
                    results.append(s[start:i+1])
                    break
                i += 1
        i += 1
    return results
for candidate in find_json_objects(text):
    try:
        d = json.loads(candidate)
        if 'verdict' in d:
            print(d['verdict'])
            sys.exit(0)
    except: continue
# Fallback: look for the last occurrence of verdict keyword near end of text
# (reviewer is instructed to put verdict at the end)
lower = text.lower()
last_revise = lower.rfind('\"revise\"')
last_approve = lower.rfind('\"approve\"')
if last_revise > last_approve:
    print('revise')
else:
    print('approve')
" "$REVIEW_RESULT" 2>/dev/null || echo "approve")

    log "Review verdict: $VERDICT"

    if [ "$VERDICT" = "approve" ]; then
      log "Review approved"
      break
    fi

    # Verdict is "revise" — feed back to worker
    if [ "$REVIEW_ITERATION" -ge "$MAX_REVIEW_ITERATIONS" ]; then
      log "Max review iterations reached ($MAX_REVIEW_ITERATIONS), accepting current result"
      break
    fi

    log "Sending review feedback to worker"

    FEEDBACK_PROMPT="## Review Feedback (Iteration $REVIEW_ITERATION)

The reviewer has identified issues with your work. Please address the following feedback and re-submit your result.

### Reviewer Feedback
$REVIEW_RESULT

### Original Task
$TASK_CONTENT

Please fix the identified issues and provide an updated result."

    # Resume worker session with feedback
    task_update "processing"

    WORKER_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    WORKER_OUT2=$(mktemp /tmp/worker-out-XXXXXX.json)
    TEMP_FILES+=("$WORKER_OUT2")

    set +e
    if [ -n "$WORKER_SESSION_ID" ]; then
      (cd "$WORK_DIR" && claude-atlas --mode worker-ephemeral --output-format json \
        --dangerously-skip-permissions \
        --resume "$WORKER_SESSION_ID" \
        -p "$FEEDBACK_PROMPT" > "$WORKER_OUT2" 2>>"$LOG")
    else
      (cd "$WORK_DIR" && claude-atlas --mode worker-ephemeral --output-format json \
        --dangerously-skip-permissions \
        -p "$FEEDBACK_PROMPT" > "$WORKER_OUT2" 2>>"$LOG")
    fi
    WORKER_EXIT=$?
    set -e

    WORKER_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    WORKER_SESSION_ID=$(extract_session_id "$WORKER_OUT2")
    WORKER_RESULT=$(extract_result "$WORKER_OUT2")

    save_session_metrics "$WORKER_OUT2" "worker" "$TRIGGER_NAME" "$WORKER_START" "$WORKER_END" "$WORKER_EXIT"
    rm -f "$WORKER_OUT2"

    # Update worker result in DB (safe, via stdin)
    printf '%s' "$WORKER_RESULT" | task_update_stdin "worker_result"

    if [ "$WORKER_EXIT" -ne 0 ] && [ -z "$WORKER_RESULT" ]; then
      log "Worker crashed during revision (exit=$WORKER_EXIT)"
      mark_failed "Worker crashed during revision iteration $REVIEW_ITERATION"
      exit 1
    fi
  done
fi

# 7. Task complete — mark as done (safe, via stdin)
printf '%s' "$WORKER_RESULT" | task_update_stdin "done"

log "Task completed successfully"

# 8. Wake trigger that created this task
bun run "$TASK_HELPERS/wake-trigger.ts" "$TASK_ID" "$WORKER_RESULT" 2>>"$LOG" || true

log "Task runner finished"
