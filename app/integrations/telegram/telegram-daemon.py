#!/usr/bin/env python3
"""
Telegram Bot Daemon.

Long-polls the Telegram Bot API for new messages and routes them
through the trigger system via `telegram incoming`.

Run as a supervisord service: see ~/supervisor.d/telegram.conf
"""

import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.error

BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
POLL_TIMEOUT = 30  # seconds for long poll
TELEGRAM_CLI = "/talos/app/bin/telegram"


def get_token():
    """Get bot token from env or config."""
    if BOT_TOKEN:
        return BOT_TOKEN
    # Try config.yml
    try:
        import yaml
        config_path = os.environ["HOME"] + "/config.yml"
        if os.path.exists(config_path):
            with open(config_path) as f:
                cfg = yaml.safe_load(f) or {}
            return cfg.get("telegram", {}).get("bot_token", "")
    except Exception:
        pass
    return ""


def api_call(token: str, method: str, data: dict = None) -> dict:
    """Make a Telegram Bot API call."""
    url = f"https://api.telegram.org/bot{token}/{method}"
    if data:
        body = json.dumps(data).encode()
        req = urllib.request.Request(url, data=body, method="POST")
        req.add_header("Content-Type", "application/json")
    else:
        req = urllib.request.Request(url)

    with urllib.request.urlopen(req, timeout=POLL_TIMEOUT + 10) as resp:
        return json.loads(resp.read())


def log(msg: str):
    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def process_message(msg: dict):
    """Route an incoming Telegram message through the CLI."""
    chat = msg.get("chat", {})
    chat_id = str(chat.get("id", ""))
    text = msg.get("text", "")
    from_user = msg.get("from", {})
    name = f"{from_user.get('first_name', '')} {from_user.get('last_name', '')}".strip()
    username = from_user.get("username", "")
    ts = msg.get("date", "")
    if isinstance(ts, int):
        ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ts))

    if not chat_id or not text:
        return

    # Skip /start command (just a greeting)
    if text.strip() == "/start":
        # Send welcome message
        token = get_token()
        if token:
            api_call(token, "sendMessage", {
                "chat_id": chat_id,
                "text": f"Hallo{' ' + name if name else ''}! Ich bin dein Assistent. Schreib mir einfach, was du brauchst.",
            })
        return

    log(f"Incoming from {name or username or chat_id}: {text[:80]}")

    cmd = [
        TELEGRAM_CLI, "incoming", chat_id, text,
        "--name", name,
    ]
    if username:
        cmd += ["--username", username]
    if ts:
        cmd += ["--timestamp", ts]

    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    token = get_token()
    if not token:
        log("ERROR: No TELEGRAM_BOT_TOKEN configured. Set in config.yml or env.")
        log("Run 'telegram setup' for instructions.")
        sys.exit(1)

    # Verify token
    try:
        me = api_call(token, "getMe")
        if not me.get("ok"):
            log("ERROR: Invalid bot token")
            sys.exit(1)
        bot_name = me["result"].get("username", "?")
        log(f"Connected as @{bot_name}")
    except Exception as e:
        log(f"ERROR: Could not connect to Telegram API: {e}")
        sys.exit(1)

    offset = 0
    log("Starting long-poll loop...")

    while True:
        try:
            result = api_call(token, "getUpdates", {
                "offset": offset,
                "timeout": POLL_TIMEOUT,
                "allowed_updates": ["message"],
            })

            if not result.get("ok"):
                log(f"API error: {result}")
                time.sleep(5)
                continue

            for update in result.get("result", []):
                offset = update["update_id"] + 1
                msg = update.get("message")
                if msg:
                    process_message(msg)

        except urllib.error.URLError as e:
            log(f"Network error: {e}, retrying in 5s...")
            time.sleep(5)
        except Exception as e:
            log(f"Unexpected error: {e}, retrying in 5s...")
            time.sleep(5)


if __name__ == "__main__":
    main()
