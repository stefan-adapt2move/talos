#!/bin/bash
# Wait for cloudflared to register its URL
sleep 10

# Extract the tunnel URL from cloudflared logs
TUNNEL_URL=$(grep -oP "https://[a-z0-9-]+\.trycloudflare\.com" /atlas/logs/cloudflared-error.log | tail -1)

if [ -z "$TUNNEL_URL" ]; then
    echo "[$(date)] ERROR: Could not find tunnel URL" >&2
    exit 1
fi

echo "[$(date)] Tunnel URL: $TUNNEL_URL"

# Requires ANTON_CALENDAR_TOKEN and ANTON_BOT_TOKEN env vars
CAL_TOKEN="${ANTON_CALENDAR_TOKEN:?ANTON_CALENDAR_TOKEN env var required}"
ANTON_TOKEN="${ANTON_BOT_TOKEN:?ANTON_BOT_TOKEN env var required}"
MENU_URL="${TUNNEL_URL}/mini-app/anton-calendar?token=${CAL_TOKEN}"

python3 << PYEOF
import urllib.request, json, os

token = os.environ["ANTON_BOT_TOKEN"]
url = "${MENU_URL}"

# Set default menu button
params = json.dumps({
    "menu_button": {
        "type": "web_app",
        "text": "\ud83d\udcc5 Kalender",
        "web_app": {"url": url}
    }
}).encode()
req = urllib.request.Request(
    "https://api.telegram.org/bot" + token + "/setChatMenuButton",
    data=params,
    headers={"Content-Type": "application/json"}
)
resp = urllib.request.urlopen(req, timeout=10)
print("Default menu button:", resp.read().decode())

# Per-chat for configured users
chat_ids = os.environ.get("ANTON_MENU_CHAT_IDS", "").split(",")
for cid in chat_ids:
    cid = cid.strip()
    if not cid:
        continue
    params2 = json.dumps({
        "chat_id": int(cid),
        "menu_button": {
            "type": "web_app",
            "text": "\ud83d\udcc5 Kalender",
            "web_app": {"url": url}
        }
    }).encode()
    req2 = urllib.request.Request(
        "https://api.telegram.org/bot" + token + "/setChatMenuButton",
        data=params2,
        headers={"Content-Type": "application/json"}
    )
    try:
        resp2 = urllib.request.urlopen(req2, timeout=10)
        print("chat_id=%s: %s" % (cid, resp2.read().decode()))
    except Exception as e:
        print("chat_id=%s: ERROR - %s" % (cid, e))
PYEOF

echo "[$(date)] Menu buttons updated with $TUNNEL_URL"
