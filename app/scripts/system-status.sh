#!/bin/bash
# System status check for Travel Agent — sends Telegram update
# Runs via supercronic every 30 minutes

set -euo pipefail

KUBECONFIG="$HOME/secrets/kubeconfig-dev.yaml"
CHAT_ID="${STATUS_NOTIFY_CHAT_ID:-129584068}"
NAMESPACE="production"
TELEGRAM="/talos/app/bin/telegram"
NOW=$(date +%H:%M)

# --- Pod Health ---
POD_INFO=$(kubectl --kubeconfig "$KUBECONFIG" get pods -n "$NAMESPACE" --no-headers 2>/dev/null || echo "FETCH_FAILED")
if [ "$POD_INFO" = "FETCH_FAILED" ]; then
    POD_STATUS="K8s nicht erreichbar"
    POD_TOTAL=0
    POD_RUNNING=0
else
    POD_TOTAL=$(echo "$POD_INFO" | wc -l)
    POD_RUNNING=$(echo "$POD_INFO" | grep -c "Running" || true)
    POD_NOT_RUNNING=$(echo "$POD_INFO" | grep -v "Running" || true)
    if [ "$POD_RUNNING" -eq "$POD_TOTAL" ]; then
        POD_STATUS="Alle $POD_TOTAL Pods running"
    else
        POD_STATUS="$POD_RUNNING/$POD_TOTAL Pods running"
    fi
fi

# --- Get travel-agent pod name ---
TA_POD=$(kubectl --kubeconfig "$KUBECONFIG" get pods -n "$NAMESPACE" -l app=travel-agent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$TA_POD" ]; then
    $TELEGRAM send "$CHAT_ID" "Status [$NOW]

$POD_STATUS
Travel Agent Pod nicht gefunden"
    exit 0
fi

# --- DB Metrics ---
DB_PATH="/home/agent/.index/travel-agent.db"

METRICS=$(kubectl --kubeconfig "$KUBECONFIG" exec "$TA_POD" -n "$NAMESPACE" -- sqlite3 "$DB_PATH" "
SELECT 'TOTAL_CONVOS:' || COUNT(*) FROM conversations WHERE trigger_name='whatsapp-chat';
SELECT 'UNIQUE_USERS:' || COUNT(DISTINCT session_key) FROM conversations WHERE trigger_name='whatsapp-chat';
SELECT 'NEW_USERS_30M:' || COUNT(DISTINCT session_key) FROM conversations WHERE trigger_name='whatsapp-chat' AND created_at > datetime('now', '-30 minutes');
SELECT 'MSGS_30M:' || COUNT(*) FROM messages WHERE created_at > datetime('now', '-30 minutes');
SELECT 'MSGS_24H:' || COUNT(*) FROM messages WHERE created_at > datetime('now', '-24 hours');
SELECT 'RUNS_30M:' || COUNT(*) FROM trigger_runs WHERE started_at > datetime('now', '-30 minutes');
SELECT 'STUCK_RUNS:' || COUNT(*) FROM trigger_runs WHERE started_at > datetime('now', '-30 minutes') AND completed_at IS NULL AND started_at < datetime('now', '-5 minutes');
SELECT 'RATE_LIMITED:' || COUNT(*) FROM rate_limits WHERE message_count >= message_limit AND sender NOT LIKE '+49170TEST%';
SELECT 'FEEDBACK_PENDING:' || COUNT(*) FROM rate_limits WHERE feedback_state = 'awaiting_feedback' AND sender NOT LIKE '+49170TEST%';
SELECT 'FEEDBACK_DONE:' || COUNT(*) FROM rate_limits WHERE feedback_state = 'completed' AND sender NOT LIKE '+49170TEST%';
SELECT 'WAITLIST:' || COUNT(*) FROM rate_limits WHERE message_count >= message_limit AND feedback_state != 'completed' AND sender NOT LIKE '+49170TEST%';
" 2>/dev/null || echo "DB_FAILED")

if echo "$METRICS" | grep -q "DB_FAILED"; then
    $TELEGRAM send "$CHAT_ID" "Status [$NOW]

$POD_STATUS
DB-Abfrage fehlgeschlagen"
    exit 0
fi

# Parse metrics
get_val() { echo "$METRICS" | grep "^$1:" | cut -d: -f2; }
TOTAL_CONVOS=$(get_val TOTAL_CONVOS)
UNIQUE_USERS=$(get_val UNIQUE_USERS)
NEW_USERS=$(get_val NEW_USERS_30M)
MSGS_30M=$(get_val MSGS_30M)
MSGS_24H=$(get_val MSGS_24H)
RUNS_30M=$(get_val RUNS_30M)
STUCK=$(get_val STUCK_RUNS)
RATE_LIMITED=$(get_val RATE_LIMITED)
FEEDBACK=$(get_val FEEDBACK_PENDING)
FEEDBACK_DONE=$(get_val FEEDBACK_DONE)
WAITLIST=$(get_val WAITLIST)

# --- Error check in logs ---
ERRORS=$(kubectl --kubeconfig "$KUBECONFIG" logs "$TA_POD" -n "$NAMESPACE" --since=30m 2>/dev/null | grep -ciE "error|exception|traceback|fatal" || true)
ERROR_SAMPLE=""
if [ "$ERRORS" -gt 0 ]; then
    ERROR_SAMPLE=$(kubectl --kubeconfig "$KUBECONFIG" logs "$TA_POD" -n "$NAMESPACE" --since=30m 2>/dev/null | grep -iE "error|exception|traceback|fatal" | tail -2 | head -c 200)
fi

# --- Build status ---
if [ "$STUCK" -gt 0 ] || [ "$ERRORS" -gt 5 ] || [ "$POD_RUNNING" -lt "$POD_TOTAL" ]; then
    HEALTH="RED"
elif [ "$ERRORS" -gt 0 ]; then
    HEALTH="YELLOW"
else
    HEALTH="GREEN"
fi

# --- Compose message ---
MSG="Systemstatus [$NOW]

[$HEALTH] $POD_STATUS
$UNIQUE_USERS WhatsApp-User gesamt"

if [ "$NEW_USERS" -gt 0 ]; then
    MSG="$MSG (+$NEW_USERS neue, 30min)"
fi

MSG="$MSG
$MSGS_30M Nachrichten (30min) / $MSGS_24H (24h)
$RUNS_30M Trigger-Runs (30min)"

if [ "$STUCK" -gt 0 ]; then
    MSG="$MSG / $STUCK stuck"
fi

MSG="$MSG
$WAITLIST Warteliste / $FEEDBACK warten auf Feedback / $FEEDBACK_DONE Feedback erhalten"

if [ "$ERRORS" -gt 0 ]; then
    MSG="$MSG
$ERRORS Log-Fehler (30min)"
    if [ -n "$ERROR_SAMPLE" ]; then
        MSG="$MSG
$ERROR_SAMPLE"
    fi
fi

$TELEGRAM send "$CHAT_ID" "$MSG"
