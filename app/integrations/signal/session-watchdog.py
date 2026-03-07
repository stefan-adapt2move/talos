#!/usr/bin/env python3
"""
Signal session watchdog for Atlas.

Monitors active Signal chat sessions and detects stale ones by checking
JSONL file modification times. If a session has no activity for 30 minutes,
it is terminated and a heartbeat message is sent via Signal.

Designed to run as a supervisord service or via cron every minute.
"""

import glob
import json
import os
import signal
import sqlite3
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ATLAS_DB = os.environ["HOME"] + "/.index/atlas.db"
TRIGGER_NAME = "signal-chat"
STALE_THRESHOLD = 300      # 5 minutes — mark as stale
KILL_THRESHOLD = 1800      # 30 minutes — kill session
CHECK_INTERVAL = 60        # check every minute
LOG_FILE = "/atlas/logs/signal-watchdog.log"


def log(msg):
    line = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def get_session_jsonl(session_id):
    """Find the JSONL file for a session."""
    pattern = os.path.expanduser(f"~/.claude/projects/*/sessions/{session_id}.jsonl")
    matches = glob.glob(pattern)
    return matches[0] if matches else None


def get_jsonl_last_modified(jsonl_path):
    """Get the mtime of the JSONL file (last write = last activity)."""
    try:
        return os.path.getmtime(jsonl_path)
    except OSError:
        return 0


def kill_session(session_id):
    """Kill a Claude session by removing its socket and killing its process."""
    socket_path = f"/tmp/claudec-{session_id}.sock"

    # Find and kill the process that owns this socket
    try:
        result = subprocess.run(
            ["fuser", socket_path],
            capture_output=True, text=True, timeout=5
        )
        if result.stdout.strip():
            pids = result.stdout.strip().split()
            for pid in pids:
                try:
                    os.kill(int(pid), signal.SIGTERM)
                except (ProcessLookupError, ValueError):
                    pass
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    # Wait briefly then force kill if needed
    time.sleep(3)
    try:
        if os.path.exists(socket_path):
            result = subprocess.run(
                ["fuser", socket_path],
                capture_output=True, text=True, timeout=5
            )
            if result.stdout.strip():
                for pid in result.stdout.strip().split():
                    try:
                        os.kill(int(pid), signal.SIGKILL)
                    except (ProcessLookupError, ValueError):
                        pass
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    # Clean up socket
    try:
        os.unlink(socket_path)
    except OSError:
        pass


def send_heartbeat(sender):
    """Send a heartbeat message via Signal informing about timeout."""
    msg = "⏱ Sitzung wurde wegen Inaktivität beendet. Schreib einfach erneut, um fortzufahren."
    try:
        subprocess.run(
            ["signal", "send", sender, msg],
            timeout=30, check=False,
            stdin=subprocess.DEVNULL,
        )
        log(f"Heartbeat sent to {sender}")
    except Exception as e:
        log(f"Failed to send heartbeat to {sender}: {e}")


def check_sessions():
    """Check all active signal sessions for staleness."""
    try:
        db = sqlite3.connect(ATLAS_DB)
        db.execute("PRAGMA busy_timeout=5000")
    except sqlite3.Error as e:
        log(f"DB error: {e}")
        return

    rows = db.execute(
        "SELECT session_id, session_key, updated_at FROM trigger_sessions WHERE trigger_name=?",
        (TRIGGER_NAME,)
    ).fetchall()

    now = time.time()

    for session_id, session_key, updated_at in rows:
        socket_path = f"/tmp/claudec-{session_id}.sock"

        # Only check sessions that appear to be running (socket exists)
        if not os.path.exists(socket_path):
            continue

        # Check JSONL file activity
        jsonl_path = get_session_jsonl(session_id)
        if not jsonl_path:
            continue

        last_modified = get_jsonl_last_modified(jsonl_path)
        idle_seconds = now - last_modified

        if idle_seconds >= KILL_THRESHOLD:
            log(f"KILL: Session {session_id} (sender={session_key}) idle for {int(idle_seconds)}s — terminating")
            kill_session(session_id)
            # Clear from DB
            db.execute(
                "DELETE FROM trigger_sessions WHERE trigger_name=? AND session_key=?",
                (TRIGGER_NAME, session_key)
            )
            db.commit()
            # Send heartbeat
            send_heartbeat(session_key)
        elif idle_seconds >= STALE_THRESHOLD:
            log(f"STALE: Session {session_id} (sender={session_key}) idle for {int(idle_seconds)}s")

    db.close()


def main():
    """Run the watchdog loop."""
    log("Signal session watchdog starting")

    # Support --once flag for cron usage
    if "--once" in sys.argv:
        check_sessions()
        return

    while True:
        try:
            check_sessions()
        except Exception as e:
            log(f"Error in check cycle: {e}")
        time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    main()
