#!/bin/bash
# Generic daemon health check — restarts a supervisord service if not running
#
# Usage: check-daemon-health.sh <service-name> [alert-threshold]
#
# Run via cron every 5 minutes:
#   */5 * * * * /talos/app/scripts/check-daemon-health.sh telegram-poller
#   */5 * * * * /talos/app/scripts/check-daemon-health.sh signal-daemon 5
#
# Arguments:
#   service-name     - supervisord service name to monitor
#   alert-threshold  - consecutive failures before logging alert (default: 3)

DAEMON_NAME="${1:?Usage: check-daemon-health.sh <service-name> [alert-threshold]}"
ALERT_THRESHOLD="${2:-3}"
ALERT_FILE="/tmp/.daemon-health-${DAEMON_NAME}"

STATUS=$(supervisorctl status "$DAEMON_NAME" 2>/dev/null | awk '{print $2}')

if [ "$STATUS" != "RUNNING" ]; then
    echo "[$(date)] $DAEMON_NAME not running (status=$STATUS), restarting..."
    supervisorctl restart "$DAEMON_NAME" 2>/dev/null

    # Count consecutive failures
    COUNT=0
    [ -f "$ALERT_FILE" ] && COUNT=$(cat "$ALERT_FILE")
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$ALERT_FILE"

    # Log alert after threshold consecutive failures
    if [ "$COUNT" -ge "$ALERT_THRESHOLD" ]; then
        echo "[$(date)] WARNING: $DAEMON_NAME has failed $COUNT consecutive times"
        echo "0" > "$ALERT_FILE"
    fi
else
    # Reset failure counter on success
    [ -f "$ALERT_FILE" ] && echo "0" > "$ALERT_FILE"
fi
