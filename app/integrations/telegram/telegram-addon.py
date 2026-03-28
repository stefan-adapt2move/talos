#!/usr/bin/env python3
"""
Telegram Communication Add-on for Talos.

All Telegram operations in one module: polling Bot API, injecting messages,
sending/replying, and contact/conversation tracking. Uses its own SQLite
database per bot token.

Subcommands:
  poll     [--once]              Poll Telegram Bot API for new messages
  incoming <chat_id> <message>   Inject a message: write to DB + inbox, fire trigger
  send     <chat_id> <message>   Send a Telegram message (supports --photo for images)
  contacts [--limit N]           List known contacts
  history  <chat_id> [--limit]   Show message history with a contact
"""

import argparse
import json
import os
import re
import socket as _socket_mod
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

# Add integrations directory to path for transcribe module
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# --- Paths ---
CONFIG_PATH = os.environ["HOME"] + "/config.yml"
APP_NAME_LOWER = os.environ.get("APP_NAME", "Atlas").lower()
TALOS_DB_PATH = os.environ["HOME"] + f"/.index/{APP_NAME_LOWER}.db"
TELEGRAM_DB_DIR = os.environ["HOME"] + "/.index/telegram"
WAKE_PATH = os.environ["HOME"] + "/.index/.wake"
TRIGGER_SCRIPT = os.environ.get("TELEGRAM_TRIGGER_SCRIPT", "/atlas/app/triggers/trigger-runner")
TRIGGER_NAME = os.environ.get("TELEGRAM_TRIGGER_NAME", "telegram-chat")


# --- Config ---

def load_config():
    """Load Telegram config from config.yml, with env overrides."""
    cfg = {}
    if os.path.exists(CONFIG_PATH):
        try:
            import yaml
            with open(CONFIG_PATH) as f:
                data = yaml.safe_load(f) or {}
            cfg = data.get("telegram", {})
        except ImportError:
            pass

    token = os.environ.get("TELEGRAM_BOT_TOKEN", cfg.get("bot_token", ""))

    # Support token_file for secure storage
    if not token and cfg.get("token_file"):
        tf = Path(cfg["token_file"])
        if tf.exists():
            token = tf.read_text().strip()

    return {
        "bot_token": token,
        "whitelist": cfg.get("whitelist", []),  # list of allowed chat_ids (ints or strings)
    }


# --- Telegram Bot API ---

API_BASE = "https://api.telegram.org/bot{token}/{method}"


def api_call(token, method, params=None, files=None):
    """Call the Telegram Bot API. Returns parsed JSON response."""
    url = API_BASE.format(token=token, method=method)

    if files:
        # Multipart form data for file uploads
        boundary = "----TalosTelegramBoundary"
        body = b""
        for key, value in (params or {}).items():
            body += f"--{boundary}\r\n".encode()
            body += f'Content-Disposition: form-data; name="{key}"\r\n\r\n'.encode()
            body += f"{value}\r\n".encode()
        for key, (filename, filedata, content_type) in files.items():
            body += f"--{boundary}\r\n".encode()
            body += f'Content-Disposition: form-data; name="{key}"; filename="{filename}"\r\n'.encode()
            body += f"Content-Type: {content_type}\r\n\r\n".encode()
            body += filedata + b"\r\n"
        body += f"--{boundary}--\r\n".encode()

        req = urllib.request.Request(url, data=body)
        req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    else:
        data = json.dumps(params or {}).encode()
        req = urllib.request.Request(url, data=data)
        req.add_header("Content-Type", "application/json")

    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        error_body = e.read().decode()
        raise RuntimeError(f"Telegram API error ({e.code}): {error_body}")
    except urllib.error.URLError as e:
        raise RuntimeError(f"Telegram API connection error: {e.reason}")


# --- Voice message transcription ---

VOICE_CACHE_DIR = os.path.join(os.environ.get("HOME", "/home/agent"), ".cache", "telegram-voice")


def download_telegram_file(token, file_id):
    """Download a file from Telegram by file_id. Returns local path."""
    os.makedirs(VOICE_CACHE_DIR, exist_ok=True)

    # Get file path from Telegram
    result = api_call(token, "getFile", {"file_id": file_id})
    if not result.get("ok"):
        raise RuntimeError(f"getFile failed: {result}")

    file_path = result["result"]["file_path"]
    download_url = f"https://api.telegram.org/file/bot{token}/{file_path}"

    # Download to cache
    ext = os.path.splitext(file_path)[1] or ".ogg"
    local_path = os.path.join(VOICE_CACHE_DIR, f"{file_id}{ext}")

    req = urllib.request.Request(download_url)
    with urllib.request.urlopen(req, timeout=30) as resp:
        with open(local_path, "wb") as f:
            f.write(resp.read())

    return local_path


def transcribe_voice(audio_path):
    """Transcribe an audio file using faster-whisper. Returns text or None."""
    try:
        from transcribe import transcribe_audio
        result = transcribe_audio(audio_path)
        return result.get("text", "").strip() or None
    except Exception as e:
        print(f"[{datetime.now()}] Transcription failed: {e}", file=sys.stderr)
        return None


# --- Telegram Database ---

def get_telegram_db(config):
    """Open (or create) the per-bot Telegram database."""
    os.makedirs(TELEGRAM_DB_DIR, exist_ok=True)

    # Use last part of token as identifier (bot ID)
    token = config.get("bot_token", "default")
    bot_id = token.split(":")[0] if ":" in token else "default"
    db_path = os.path.join(TELEGRAM_DB_DIR, f"{bot_id}.db")

    db = sqlite3.connect(db_path)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA busy_timeout=5000")

    db.executescript("""
        CREATE TABLE IF NOT EXISTS contacts (
            chat_id         TEXT PRIMARY KEY,
            username        TEXT NOT NULL DEFAULT '',
            first_name      TEXT NOT NULL DEFAULT '',
            last_name       TEXT NOT NULL DEFAULT '',
            chat_type       TEXT NOT NULL DEFAULT 'private',
            chat_title      TEXT NOT NULL DEFAULT '',
            message_count   INTEGER NOT NULL DEFAULT 0,
            first_seen      TEXT NOT NULL DEFAULT (datetime('now')),
            last_seen       TEXT NOT NULL DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS messages (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            chat_id         TEXT NOT NULL,
            direction       TEXT NOT NULL DEFAULT 'in',
            body            TEXT NOT NULL DEFAULT '',
            telegram_msg_id INTEGER,
            timestamp       TEXT NOT NULL DEFAULT '',
            inbox_msg_id    INTEGER,
            created_at      TEXT NOT NULL DEFAULT (datetime('now')),
            FOREIGN KEY (chat_id) REFERENCES contacts(chat_id)
        );

        CREATE TABLE IF NOT EXISTS state (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL DEFAULT ''
        );

        CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(chat_id);
        CREATE INDEX IF NOT EXISTS idx_messages_direction ON messages(direction);
    """)

    return db


def update_contact(db, chat_id, username="", first_name="", last_name="",
                   chat_type="private", chat_title=""):
    """Update or create contact in the Telegram DB."""
    db.execute("""
        INSERT INTO contacts (chat_id, username, first_name, last_name,
                              chat_type, chat_title, message_count, last_seen)
        VALUES (?, ?, ?, ?, ?, ?, 1, datetime('now'))
        ON CONFLICT(chat_id) DO UPDATE SET
            username = CASE WHEN excluded.username != '' THEN excluded.username ELSE contacts.username END,
            first_name = CASE WHEN excluded.first_name != '' THEN excluded.first_name ELSE contacts.first_name END,
            last_name = CASE WHEN excluded.last_name != '' THEN excluded.last_name ELSE contacts.last_name END,
            chat_type = CASE WHEN excluded.chat_type != '' THEN excluded.chat_type ELSE contacts.chat_type END,
            chat_title = CASE WHEN excluded.chat_title != '' THEN excluded.chat_title ELSE contacts.chat_title END,
            message_count = contacts.message_count + 1,
            last_seen = datetime('now')
    """, (str(chat_id), username, first_name, last_name, chat_type, chat_title))


# --- POLL command (Telegram Bot API → incoming) ---

def cmd_poll(config, once=False):
    """Poll Telegram Bot API for new messages and process each via cmd_incoming."""
    token = config["bot_token"]
    if not token:
        print(f"[{datetime.now()}] ERROR: No Telegram bot token configured", file=sys.stderr)
        sys.exit(1)

    db = get_telegram_db(config)

    # Get last update_id
    row = db.execute("SELECT value FROM state WHERE key='last_update_id'").fetchone()
    last_update_id = int(row[0]) if row and row[0].isdigit() else 0

    params = {"timeout": 30, "allowed_updates": ["message"]}
    if last_update_id > 0:
        params["offset"] = last_update_id + 1

    try:
        result = api_call(token, "getUpdates", params)
    except RuntimeError as e:
        print(f"[{datetime.now()}] ERROR: {e}", file=sys.stderr)
        db.close()
        return

    if not result.get("ok") or not result.get("result"):
        db.close()
        return

    max_update_id = last_update_id
    for update in result["result"]:
        update_id = update.get("update_id", 0)
        max_update_id = max(max_update_id, update_id)

        msg = update.get("message", {})
        if not msg:
            continue

        chat = msg.get("chat", {})
        chat_id = str(chat.get("id", ""))
        text = msg.get("text", "")
        from_user = msg.get("from", {})
        username = from_user.get("username", "")
        first_name = from_user.get("first_name", "")
        last_name = from_user.get("last_name", "")
        chat_type = chat.get("type", "private")
        chat_title = chat.get("title", "")
        ts = str(msg.get("date", ""))
        telegram_msg_id = msg.get("message_id", 0)

        # Handle non-text messages (photos, documents, etc.)
        if not text:
            if msg.get("photo"):
                text = "[Photo]"
                caption = msg.get("caption", "")
                if caption:
                    text = f"[Photo] {caption}"
            elif msg.get("document"):
                doc = msg["document"]
                text = f"[Document: {doc.get('file_name', 'unknown')}]"
                caption = msg.get("caption", "")
                if caption:
                    text += f" {caption}"
            elif msg.get("voice"):
                voice = msg["voice"]
                file_id = voice.get("file_id", "")
                duration = voice.get("duration", 0)
                if file_id:
                    try:
                        audio_path = download_telegram_file(token, file_id)
                        transcript = transcribe_voice(audio_path)
                        if transcript:
                            text = f"[Voice message, {duration}s] {transcript}"
                        else:
                            text = "[Voice message - transcription failed]"
                        # Cleanup
                        try:
                            os.remove(audio_path)
                        except OSError:
                            pass
                    except Exception as e:
                        print(f"[{datetime.now()}] Voice download failed: {e}", file=sys.stderr)
                        text = "[Voice message - download failed]"
                else:
                    text = "[Voice message]"
            elif msg.get("audio"):
                audio = msg["audio"]
                file_id = audio.get("file_id", "")
                title = audio.get("title", audio.get("file_name", "audio"))
                if file_id:
                    try:
                        audio_path = download_telegram_file(token, file_id)
                        transcript = transcribe_voice(audio_path)
                        if transcript:
                            text = f"[Audio: {title}] {transcript}"
                        else:
                            text = f"[Audio: {title} - transcription failed]"
                        try:
                            os.remove(audio_path)
                        except OSError:
                            pass
                    except Exception as e:
                        print(f"[{datetime.now()}] Audio download failed: {e}", file=sys.stderr)
                        text = f"[Audio: {title}]"
                else:
                    text = f"[Audio: {title}]"
            elif msg.get("sticker"):
                text = f"[Sticker: {msg['sticker'].get('emoji', '')}]"
            elif msg.get("location"):
                loc = msg["location"]
                text = f"[Location: {loc.get('latitude')}, {loc.get('longitude')}]"
            else:
                continue  # Skip unsupported message types

        if not chat_id:
            continue

        cmd_incoming(config, chat_id, text,
                     username=username, first_name=first_name,
                     last_name=last_name, chat_type=chat_type,
                     chat_title=chat_title, timestamp=ts,
                     telegram_msg_id=telegram_msg_id)

    # Persist update_id state
    if max_update_id > last_update_id:
        db.execute("INSERT OR REPLACE INTO state (key, value) VALUES ('last_update_id', ?)",
                   (str(max_update_id),))
        db.commit()

    db.close()


# --- INCOMING command (core: inject message into session) ---

def cmd_incoming(config, chat_id, message, username="", first_name="",
                 last_name="", chat_type="private", chat_title="",
                 timestamp="", telegram_msg_id=0):
    """Inject an incoming message: store in DB, write to inbox, fire trigger."""
    chat_id = str(chat_id)

    # Whitelist check
    if config["whitelist"]:
        allowed = [str(x) for x in config["whitelist"]]
        if chat_id not in allowed:
            print(f"Blocked: {chat_id} not in whitelist", file=sys.stderr)
            return

    db = get_telegram_db(config)
    ts = timestamp or datetime.now().isoformat()

    # Build display name
    display_name = " ".join(filter(None, [first_name, last_name]))
    if username:
        display_name = f"{display_name} (@{username})" if display_name else f"@{username}"
    if chat_type in ("group", "supergroup") and chat_title:
        display_name = f"{display_name} in {chat_title}" if display_name else chat_title

    # 1. Store in telegram DB
    update_contact(db, chat_id, username, first_name, last_name, chat_type, chat_title)
    db.execute("""
        INSERT INTO messages (chat_id, direction, body, telegram_msg_id, timestamp)
        VALUES (?, 'in', ?, ?, ?)
    """, (chat_id, message[:8000], telegram_msg_id, ts))

    # 2. Write to talos inbox
    talos_db = sqlite3.connect(TALOS_DB_PATH)
    talos_db.execute("PRAGMA busy_timeout=5000")
    cursor = talos_db.execute(
        "INSERT INTO messages (channel, sender, content) VALUES (?, ?, ?)",
        ("telegram", display_name or chat_id, message),
    )
    inbox_msg_id = cursor.lastrowid
    talos_db.commit()
    talos_db.close()

    # Update telegram DB with inbox reference
    db.execute("UPDATE messages SET inbox_msg_id = ? WHERE rowid = last_insert_rowid()",
               (inbox_msg_id,))
    db.commit()
    db.close()

    # Touch .wake so main session picks up the message
    Path(WAKE_PATH).touch()

    print(f"[{datetime.now()}] Telegram from {display_name or chat_id}: "
          f"{message[:80]}... (inbox={inbox_msg_id})")

    # Check for /new command — reset session
    if message.strip().lower() == "/new":
        cmd_new_session(config, chat_id, inbox_msg_id,
                        display_name=display_name, timestamp=ts)
        return

    # 3. Fire trigger
    payload = json.dumps({
        "inbox_message_id": inbox_msg_id,
        "sender": display_name or chat_id,
        "chat_id": chat_id,
        "username": username,
        "chat_type": chat_type,
        "message": message[:4000],
        "timestamp": ts,
    })

    try:
        subprocess.Popen(
            [TRIGGER_SCRIPT, TRIGGER_NAME, payload, chat_id],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception as e:
        print(f"Failed to fire trigger: {e}", file=sys.stderr)


# --- /new SESSION RESET ---

FAREWELL_TEMPLATE_PATH = "/atlas/app/prompts/trigger-channel-telegram-farewell.md"


def _inject_ipc(socket_path, message):
    """Inject a message into a running Claude session via IPC socket."""
    s = _socket_mod.socket(_socket_mod.AF_UNIX, _socket_mod.SOCK_STREAM)
    s.settimeout(10)
    try:
        s.connect(socket_path)
        s.sendall(json.dumps({"action": "send", "text": message, "submit": True}).encode() + b"\n")
    finally:
        s.close()


def _wait_for_socket_gone(socket_path, timeout=120):
    """Wait for IPC socket to disappear (session finished processing)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not os.path.exists(socket_path):
            return True
        time.sleep(2)
    return False


def _load_farewell_message():
    """Load the farewell prompt template with today's date substituted."""
    today = datetime.now().strftime("%Y-%m-%d")
    if os.path.exists(FAREWELL_TEMPLATE_PATH):
        with open(FAREWELL_TEMPLATE_PATH) as f:
            return f.read().replace("{{today}}", today)
    # Use the signal farewell template as fallback, then inline fallback
    signal_farewell = "/atlas/app/prompts/trigger-channel-signal-farewell.md"
    if os.path.exists(signal_farewell):
        with open(signal_farewell) as f:
            return f.read().replace("{{today}}", today)
    return (
        "<session-ending reason=\"user-requested-new-session\">\n"
        "The user sent /new to start a fresh conversation. This session is being retired.\n\n"
        f"Save important context to memory/journal/{today}.md (create or append):\n"
        "- Summary of this conversation's key topics\n"
        "- Decisions made and tasks created/completed\n"
        "- Open questions or commitments\n"
        "- Context the next session should know\n\n"
        "Update memory/MEMORY.md only for genuinely new long-term information.\n\n"
        "IMPORTANT: Do NOT send any Telegram messages. Save to memory silently.\n"
        "</session-ending>"
    )


def _resume_with_farewell(session_id, chat_id, farewell):
    """Resume an inactive session with a farewell message so it can save to memory."""
    env = os.environ.copy()
    env[f"{APP_NAME_LOWER.upper()}_TRIGGER"] = TRIGGER_NAME
    env[f"{APP_NAME_LOWER.upper()}_TRIGGER_CHANNEL"] = "telegram"
    env[f"{APP_NAME_LOWER.upper()}_TRIGGER_SESSION_KEY"] = chat_id
    env.pop("CLAUDECODE", None)
    subprocess.run(
        ["claude", "--mode", "trigger",
         "-p", "--dangerously-skip-permissions",
         "--resume", session_id,
         "--output-format", "json",
         farewell],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        timeout=180,
        env=env,
    )


def cmd_new_session(config, chat_id, inbox_msg_id, display_name="", timestamp=""):
    """Handle /new command: instruct old session to save to memory, then start fresh."""
    ts = timestamp or datetime.now().isoformat()

    talos_db = sqlite3.connect(TALOS_DB_PATH)
    talos_db.execute("PRAGMA busy_timeout=5000")

    # Find existing session for this chat
    row = talos_db.execute(
        "SELECT session_id FROM trigger_sessions WHERE trigger_name=? AND session_key=?",
        (TRIGGER_NAME, chat_id),
    ).fetchone()

    old_session_id = row[0] if row else None
    farewell_sent = False

    if old_session_id:
        farewell = _load_farewell_message()
        socket_path = f"/tmp/claudec-{old_session_id}.sock"

        if os.path.exists(socket_path):
            try:
                _inject_ipc(socket_path, farewell)
                farewell_sent = True
                print(f"[{datetime.now()}] /new: Injected farewell into running session {old_session_id}")
                _wait_for_socket_gone(socket_path, timeout=120)
            except Exception as e:
                print(f"[{datetime.now()}] /new: Failed to inject farewell: {e}", file=sys.stderr)
        else:
            try:
                _resume_with_farewell(old_session_id, chat_id, farewell)
                farewell_sent = True
                print(f"[{datetime.now()}] /new: Resumed session {old_session_id} for farewell")
            except subprocess.TimeoutExpired:
                print(f"[{datetime.now()}] /new: Farewell resume timed out", file=sys.stderr)
            except Exception as e:
                print(f"[{datetime.now()}] /new: Failed to resume for farewell: {e}", file=sys.stderr)

        talos_db.execute(
            "DELETE FROM trigger_sessions WHERE trigger_name=? AND session_key=?",
            (TRIGGER_NAME, chat_id),
        )
        talos_db.commit()
        print(f"[{datetime.now()}] /new: Cleared session for {chat_id}")

    talos_db.close()

    # Fire fresh trigger
    payload = json.dumps({
        "inbox_message_id": inbox_msg_id,
        "sender": display_name or chat_id,
        "chat_id": chat_id,
        "message": "/new",
        "timestamp": ts,
    })

    try:
        subprocess.Popen(
            [TRIGGER_SCRIPT, TRIGGER_NAME, payload, chat_id],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception as e:
        print(f"[{datetime.now()}] /new: Failed to fire fresh trigger: {e}", file=sys.stderr)

    print(f"[{datetime.now()}] /new: Fresh session fired for {chat_id} (farewell_sent={farewell_sent})")


# --- SEND command ---

def cmd_send(config, chat_id, message, photo=None, reply_to=None):
    """Send a Telegram message, optionally with a photo."""
    token = config["bot_token"]
    if not token:
        print("ERROR: No Telegram bot token configured", file=sys.stderr)
        sys.exit(1)

    db = get_telegram_db(config)
    chat_id = str(chat_id)

    try:
        if photo:
            if not os.path.isfile(photo):
                print(f"ERROR: Photo file not found: {photo}", file=sys.stderr)
                sys.exit(1)

            with open(photo, "rb") as f:
                photo_data = f.read()

            # Determine content type
            ext = os.path.splitext(photo)[1].lower()
            content_types = {".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                             ".png": "image/png", ".gif": "image/gif"}
            ct = content_types.get(ext, "application/octet-stream")

            params = {"chat_id": chat_id}
            if message:
                params["caption"] = message
            if reply_to:
                params["reply_to_message_id"] = reply_to

            result = api_call(token, "sendPhoto", params,
                              files={"photo": (os.path.basename(photo), photo_data, ct)})
        else:
            params = {"chat_id": chat_id, "text": message}
            if reply_to:
                params["reply_to_message_id"] = reply_to
            result = api_call(token, "sendMessage", params)

        if not result.get("ok"):
            raise RuntimeError(f"API returned error: {result}")

        sent_msg = result.get("result", {})
        telegram_msg_id = sent_msg.get("message_id", 0)

        # Store in DB
        update_contact(db, chat_id)
        stored_msg = message
        if photo:
            stored_msg = f"[Photo: {os.path.basename(photo)}] {message}" if message else f"[Photo: {os.path.basename(photo)}]"
        db.execute("""
            INSERT INTO messages (chat_id, direction, body, telegram_msg_id, timestamp)
            VALUES (?, 'out', ?, ?, ?)
        """, (chat_id, stored_msg[:8000], telegram_msg_id, datetime.now().isoformat()))
        db.commit()

        photo_info = f" (with photo)" if photo else ""
        print(f"Telegram message sent to {chat_id}{photo_info}")

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        db.close()


# --- CONTACTS command ---

def cmd_contacts(config, limit=20):
    """List known Telegram contacts."""
    db = get_telegram_db(config)
    rows = db.execute("""
        SELECT chat_id, username, first_name, last_name, chat_type,
               chat_title, message_count, last_seen
        FROM contacts ORDER BY last_seen DESC LIMIT ?
    """, (limit,)).fetchall()

    if not rows:
        print("No Telegram contacts found.")
        db.close()
        return

    print(f"{'Chat ID':<15} {'Name':<25} {'Username':<18} {'Type':<10} {'Msgs':>5}  {'Last Seen'}")
    print("-" * 100)
    for row in rows:
        chat_id = str(row[0])[:13]
        name = " ".join(filter(None, [row[2], row[3]]))[:23] or row[5][:23] or "-"
        username = f"@{row[1]}" if row[1] else "-"
        chat_type = row[4][:8]
        count = row[6]
        last_seen = row[7][:16]
        print(f"{chat_id:<15} {name:<25} {username[:16]:<18} {chat_type:<10} {count:>5}  {last_seen}")

    db.close()


# --- HISTORY command ---

def cmd_history(config, chat_id, limit=20):
    """Show message history with a contact."""
    chat_id = str(chat_id)
    db = get_telegram_db(config)

    contact = db.execute("SELECT * FROM contacts WHERE chat_id = ?",
                         (chat_id,)).fetchone()
    if not contact:
        print(f"Contact {chat_id} not found.", file=sys.stderr)
        db.close()
        sys.exit(1)

    cols = [d[0] for d in db.execute("SELECT * FROM contacts LIMIT 0").description]
    data = dict(zip(cols, contact))
    name = " ".join(filter(None, [data["first_name"], data["last_name"]]))
    if data["username"]:
        name = f"{name} (@{data['username']})" if name else f"@{data['username']}"
    print(f"Contact: {data['chat_id']} ({name or 'unknown'})")
    print(f"Type: {data['chat_type']}, Messages: {data['message_count']}, First seen: {data['first_seen']}")
    print()

    messages = db.execute("""
        SELECT direction, body, created_at
        FROM messages WHERE chat_id = ? ORDER BY created_at DESC LIMIT ?
    """, (chat_id, limit)).fetchall()

    for m in reversed(messages):
        direction = "\u2192" if m[0] == "out" else "\u2190"
        print(f"{direction} ({m[2][:16]})")
        print(f"  {m[1][:200]}{'...' if len(m[1] or '') > 200 else ''}")
        print()

    db.close()


# --- Main CLI ---

def main():
    parser = argparse.ArgumentParser(
        description="Talos Telegram Add-on",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  telegram-addon.py poll --once                    # Check Telegram once
  telegram-addon.py poll                           # Continuous polling
  telegram-addon.py incoming 123456 "Hello!"       # Inject incoming message
  telegram-addon.py send 123456 "Hi!"              # Send outgoing message
  telegram-addon.py send 123456 "Look!" --photo img.jpg
  telegram-addon.py contacts                       # List contacts
  telegram-addon.py history 123456                 # Conversation history
        """,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # poll
    p_poll = sub.add_parser("poll", help="Poll Telegram Bot API for new messages")
    p_poll.add_argument("--once", action="store_true", help="Check once and exit")

    # incoming
    p_in = sub.add_parser("incoming", help="Inject an incoming message")
    p_in.add_argument("chat_id", help="Chat ID")
    p_in.add_argument("message", help="Message text")
    p_in.add_argument("--username", default="", help="Sender username")
    p_in.add_argument("--first-name", default="", help="Sender first name")
    p_in.add_argument("--last-name", default="", help="Sender last name")
    p_in.add_argument("--timestamp", default="", help="Message timestamp")

    # send
    p_send = sub.add_parser("send", help="Send a Telegram message")
    p_send.add_argument("chat_id", help="Chat ID")
    p_send.add_argument("message", nargs="?", default="", help="Message text")
    p_send.add_argument("--photo", default=None, metavar="FILE",
                        help="Send a photo with optional caption")
    p_send.add_argument("--reply-to", type=int, default=None,
                        help="Reply to a specific message ID")

    # contacts
    p_contacts = sub.add_parser("contacts", help="List known contacts")
    p_contacts.add_argument("--limit", type=int, default=20)

    # history
    p_history = sub.add_parser("history", help="Message history with a contact")
    p_history.add_argument("chat_id", help="Chat ID")
    p_history.add_argument("--limit", type=int, default=20)

    args = parser.parse_args()
    config = load_config()

    if args.command == "poll":
        if args.once:
            cmd_poll(config, once=True)
        else:
            interval = int(os.environ.get("TELEGRAM_POLL_INTERVAL", 5))
            print(f"[{datetime.now()}] Telegram polling starting "
                  f"(interval={interval}s)")
            while True:
                cmd_poll(config, once=True)
                time.sleep(interval)
    elif args.command == "incoming":
        cmd_incoming(config, args.chat_id, args.message,
                     username=args.username, first_name=args.first_name,
                     last_name=args.last_name, timestamp=args.timestamp)
    elif args.command == "send":
        if not args.message and not args.photo:
            print("ERROR: Must provide message text or --photo", file=sys.stderr)
            sys.exit(1)
        cmd_send(config, args.chat_id, args.message,
                 photo=args.photo, reply_to=args.reply_to)
    elif args.command == "contacts":
        cmd_contacts(config, limit=args.limit)
    elif args.command == "history":
        cmd_history(config, args.chat_id, limit=args.limit)


if __name__ == "__main__":
    main()
