#!/bin/bash
# email-poller.sh — Check for new emails, notify via Telegram, and trigger AI auto-reply.
#
# Required env vars: OUTLOOK_TENANT_ID, OUTLOOK_CLIENT_ID, OUTLOOK_CLIENT_SECRET,
#                    OUTLOOK_MAILBOX, OUTLOOK_ALLOWED_SENDERS
# State file: /home/agent/.index/email-poller-seen.txt
# Logs:       stderr (captured by supervisor to /home/agent/.logs/email-poller.err)

set -euo pipefail

OUTLOOK="/atlas/app/bin/outlook"
TELEGRAM="/atlas/app/bin/telegram"
TRIGGER_SCRIPT="/atlas/app/triggers/trigger-runner"
STEFAN_CHAT_ID="${EMAIL_NOTIFY_CHAT_ID:-129584068}"
STATE_FILE="/home/agent/.index/email-poller-seen.txt"
STATE_MAX_IDS=500
CALENDAR_FILE="/home/agent/projects/atlas/app/data/mvp-travel-assistant/calendar.json"

# Ensure directories exist
mkdir -p /home/agent/.index /home/agent/.logs

# Create state file if missing
[[ -f "$STATE_FILE" ]] || touch "$STATE_FILE"

# ---------------------------------------------------------------------------
# Fetch unread inbox
# ---------------------------------------------------------------------------

inbox_output=$("$OUTLOOK" inbox --unread --limit 20 2>/tmp/email-poller-outlook-err) || {
    err=$(cat /tmp/email-poller-outlook-err 2>/dev/null || true)
    echo "[email-poller] ERROR: outlook inbox failed: $err" >&2
    exit 1
}

if echo "$inbox_output" | grep -q '^\[error\]'; then
    echo "[email-poller] ERROR: outlook returned an error:" >&2
    echo "$inbox_output" >&2
    exit 1
fi

if [[ -z "$inbox_output" ]] || echo "$inbox_output" | grep -q '^No messages found\.$'; then
    echo "[email-poller] No unread messages." >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Parse inbox blocks — extract ID, From, Subject, Preview
# ---------------------------------------------------------------------------

declare -A seen_ids
while IFS= read -r line; do
    [[ -n "$line" ]] && seen_ids["$line"]=1
done < "$STATE_FILE"

new_ids=()

parsed=$(echo "$inbox_output" | awk '
BEGIN { id = ""; from_val = ""; subject_val = ""; preview_val = "" }
/^  ID     :/ { id = $0; sub(/^  ID     : /, "", id) }
/^  From   :/ { from_val = $0; sub(/^  From   : /, "", from_val) }
/^  Subject:/ { subject_val = $0; sub(/^  Subject: /, "", subject_val) }
/^  Preview:/ { preview_val = $0; sub(/^  Preview: /, "", preview_val) }
/^-{10,}/ {
    if (id != "") print id "\t" from_val "\t" subject_val "\t" preview_val
    id = ""; from_val = ""; subject_val = ""; preview_val = ""
}
END { if (id != "") print id "\t" from_val "\t" subject_val "\t" preview_val }
')

if [[ -z "$parsed" ]]; then
    echo "[email-poller] No parseable messages." >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Process each new message
# ---------------------------------------------------------------------------

while IFS=$'\t' read -r msg_id from_val subject_val preview_val; do
    [[ -z "$msg_id" ]] && continue
    [[ -n "${seen_ids[$msg_id]:-}" ]] && continue

    # Read full email content for the trigger
    email_content=$("$OUTLOOK" read "$msg_id" 2>/dev/null) || {
        echo "[email-poller] WARNING: Could not read message $msg_id" >&2
        new_ids+=("$msg_id")
        seen_ids["$msg_id"]=1
        continue
    }

    # Load calendar
    calendar_content=""
    if [[ -f "$CALENDAR_FILE" ]]; then
        calendar_content=$(cat "$CALENDAR_FILE" 2>/dev/null || echo "{}")
    fi

    # Build trigger payload
    payload=$(python3 -c "
import json, sys
print(json.dumps({
    'message_id': sys.argv[1],
    'from': sys.argv[2],
    'subject': sys.argv[3],
    'email': sys.argv[4],
    'calendar': sys.argv[5],
}))
" "$msg_id" "$from_val" "$subject_val" "$email_content" "$calendar_content")

    # Fire the travel-request trigger
    if "$TRIGGER_SCRIPT" travel-request "$payload" "email-$msg_id" >>/atlas/logs/trigger-travel-request-spawn.log 2>&1; then
        echo "[email-poller] Triggered travel-request for: $subject_val" >&2
    else
        echo "[email-poller] WARNING: Trigger failed for $msg_id, sending notification instead" >&2
        # Fallback: just notify Stefan
        preview_short="${preview_val:0:100}"
        "$TELEGRAM" send "$STEFAN_CHAT_ID" "New email (auto-reply failed)
From: ${from_val}
Subject: ${subject_val}
Preview: ${preview_short}" 2>/dev/null || true
    fi

    new_ids+=("$msg_id")
    seen_ids["$msg_id"]=1

done <<< "$parsed"

# ---------------------------------------------------------------------------
# Update state file
# ---------------------------------------------------------------------------

if [[ ${#new_ids[@]} -gt 0 ]]; then
    printf '%s\n' "${new_ids[@]}" >> "$STATE_FILE"
    echo "[email-poller] Appended ${#new_ids[@]} new ID(s) to state file." >&2

    line_count=$(wc -l < "$STATE_FILE")
    if [[ "$line_count" -gt "$STATE_MAX_IDS" ]]; then
        tmp_file=$(mktemp)
        tail -n "$STATE_MAX_IDS" "$STATE_FILE" > "$tmp_file"
        mv "$tmp_file" "$STATE_FILE"
        echo "[email-poller] State file trimmed to last ${STATE_MAX_IDS} IDs." >&2
    fi
else
    echo "[email-poller] No new messages." >&2
fi
