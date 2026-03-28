#!/bin/bash
# Watchdog: detect and kill stuck trigger-runner processes
#
# A trigger-runner holding a lock for more than MAX_AGE_MIN minutes
# is considered stuck. Kill it + child processes, clean up lock file,
# then re-fire the trigger so the session resumes and catches up on
# any messages that were skipped while the lock was held.
#
# Usage: Run via cron every 5 minutes:
#   */5 * * * * /atlas/app/scripts/watchdog-triggers.sh
#
# Configuration (env vars):
#   MAX_AGE_MIN   - Minutes before a trigger is considered stuck (default: 30)
#   WATCHDOG_LOG  - Log file path (default: /atlas/logs/watchdog-triggers.log)

MAX_AGE_MIN=${MAX_AGE_MIN:-30}
LOG="${WATCHDOG_LOG:-/atlas/logs/watchdog-triggers.log}"
MAX_AGE_SEC=$((MAX_AGE_MIN * 60))
TRIGGER_SH="/atlas/app/triggers/trigger.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# Collect trigger info from stuck processes before killing them
REFIRE_LIST=""

# Find trigger-runner processes
PIDS=$(pgrep -f 'trigger-runner' 2>/dev/null)
[ -z "$PIDS" ] && exit 0

KILLED=0
for PID in $PIDS; do
    # Skip zombies
    STATE=$(ps -o stat= -p "$PID" 2>/dev/null)
    [[ "$STATE" == *Z* ]] && continue

    # Check process age in seconds
    ELAPSED=$(ps -o etimes= -p "$PID" 2>/dev/null | tr -d ' ')
    [ -z "$ELAPSED" ] && continue

    if [ "$ELAPSED" -gt "$MAX_AGE_SEC" ]; then
        # Get process details for logging
        CMD=$(ps -o args= -p "$PID" 2>/dev/null)
        ELAPSED_MIN=$((ELAPSED / 60))
        log "STUCK: PID=$PID running ${ELAPSED_MIN}m — ${CMD:0:200}"

        # Extract trigger name and session key from command line
        # Format: trigger-runner <trigger-name> <json-payload> <session-key>
        TRIGGER_NAME=$(echo "$CMD" | sed -n 's/.*trigger-runner \([^ ]*\).*/\1/p')
        SESSION_KEY=$(echo "$CMD" | awk '{print $NF}')

        # Kill child processes first (claude agent SDK spawns subprocesses)
        CHILDREN=$(pgrep -P "$PID" 2>/dev/null)
        for CPID in $CHILDREN; do
            GRANDCHILDREN=$(pgrep -P "$CPID" 2>/dev/null)
            for GPID in $GRANDCHILDREN; do
                kill "$GPID" 2>/dev/null
                log "  Killed grandchild PID=$GPID"
            done
            kill "$CPID" 2>/dev/null
            log "  Killed child PID=$CPID"
        done

        # Kill the trigger-runner itself
        kill "$PID" 2>/dev/null
        log "  Killed trigger-runner PID=$PID"

        # Wait briefly then force-kill if needed
        sleep 2
        kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null && log "  Force-killed PID=$PID"

        KILLED=$((KILLED + 1))

        # Remember for re-firing
        if [ -n "$TRIGGER_NAME" ] && [ -n "$SESSION_KEY" ]; then
            REFIRE_LIST="${REFIRE_LIST}${TRIGGER_NAME} ${SESSION_KEY}\n"
        fi
    fi
done

# Clean up orphan lock files whose PID is dead
for LOCKFILE in /tmp/.trigger-*.flock; do
    [ -f "$LOCKFILE" ] || continue
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null | tr -d ' ')
    [ -z "$LOCK_PID" ] && continue
    if ! kill -0 "$LOCK_PID" 2>/dev/null; then
        log "STALE LOCK: $LOCKFILE (PID=$LOCK_PID dead) — removing"
        rm -f "$LOCKFILE"
    fi
done

# Re-fire triggers so sessions resume and catch up on missed messages
if [ -n "$REFIRE_LIST" ]; then
    sleep 3
    echo -e "$REFIRE_LIST" | while read -r T_NAME T_KEY; do
        [ -z "$T_NAME" ] && continue
        RECOVERY_PAYLOAD="{\"watchdog_recovery\": true, \"message\": \"Session was stuck and recovered by watchdog. Check for unread messages using the channel history command, then respond to any unanswered messages.\"}"
        log "RE-FIRE: $T_NAME (key=$T_KEY)"
        nohup "$TRIGGER_SH" "$T_NAME" "$RECOVERY_PAYLOAD" "$T_KEY" \
            >> "$LOG" 2>&1 &
    done
fi

if [ "$KILLED" -gt 0 ]; then
    log "Watchdog killed $KILLED stuck trigger(s), re-fired for recovery"
fi
