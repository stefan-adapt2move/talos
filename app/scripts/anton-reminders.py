#!/usr/bin/env python3
"""
Anton Reminder System — sends calendar reminders via Telegram.
No AI. Two modes:
1. Per-minute: Only sends reminders for events with an explicit "reminder" field
2. Weekly briefing: Every Sunday at 19:00, sends a summary of next week's events
"""
import json
import os
import subprocess
import sys
from datetime import datetime, date, timedelta

CALENDAR_PATH = os.path.expanduser("~/memory/anton-calendar.json")
STATE_PATH = os.path.expanduser("~/.index/anton-reminders-sent.json")
GROUP_CHAT_ID = os.environ.get("ANTON_GROUP_CHAT_ID", "-5084058522")
ANTON_CLI = "/atlas/app/bin/anton"

def load_calendar():
    try:
        with open(CALENDAR_PATH) as f:
            return json.load(f).get("events", [])
    except (FileNotFoundError, json.JSONDecodeError):
        return []

def load_sent():
    try:
        with open(STATE_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def save_sent(sent):
    os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
    with open(STATE_PATH, "w") as f:
        json.dump(sent, f)

def event_matches_date(event, check_date):
    """Check if event is active on a given date (start <= date <= end, handles recurrence)."""
    try:
        start = datetime.strptime(event["start"], "%Y-%m-%d").date()
        end = datetime.strptime(event.get("end", event["start"]), "%Y-%m-%d").date()
    except (ValueError, KeyError):
        return False

    if event.get("recurrence") == "yearly":
        # Check month+day range (ignoring year)
        s = start.replace(year=check_date.year)
        e = end.replace(year=check_date.year)
        return s <= check_date <= e
    return start <= check_date <= end

def event_starts_on(event, check_date):
    """Check if event starts on a given date (handles recurrence)."""
    try:
        start = datetime.strptime(event["start"], "%Y-%m-%d").date()
    except (ValueError, KeyError):
        return False

    if event.get("recurrence") == "yearly":
        return start.month == check_date.month and start.day == check_date.day
    return start == check_date

def format_reminder(event):
    """Format a single event reminder message."""
    msg = f"\U0001f514 Erinnerung: {event['title']}"
    if event.get("location"):
        msg += f"\n\U0001f4cd {event['location']}"
    if event.get("notes"):
        msg += f"\n\U0001f4dd {event['notes']}"
    if event.get("time"):
        msg += f"\n\U0001f550 {event['time']} Uhr"
    return msg

def format_date_de(d):
    """Format date as 'Do 13.03.'"""
    days = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
    return f"{days[d.weekday()]} {d.strftime('%d.%m.')}"

def format_weekly_briefing(events, today):
    """Format a weekly briefing of upcoming events."""
    # Next 7 days (Mon-Sun of coming week)
    monday = today + timedelta(days=1)  # Tomorrow is Monday
    sunday = monday + timedelta(days=6)

    upcoming = []
    for event in events:
        try:
            start = datetime.strptime(event["start"], "%Y-%m-%d").date()
            end = datetime.strptime(event.get("end", event["start"]), "%Y-%m-%d").date()
        except (ValueError, KeyError):
            continue

        if event.get("recurrence") == "yearly":
            start = start.replace(year=today.year)
            end = end.replace(year=today.year)

        # Event overlaps with next week?
        if start <= sunday and end >= monday:
            upcoming.append((max(start, monday), event))

    if not upcoming:
        return None

    upcoming.sort(key=lambda x: x[0])

    msg = "\U0001f4cb Wochenbriefing \u2014 kommende Woche:\n"
    for event_start, event in upcoming:
        try:
            end = datetime.strptime(event.get("end", event["start"]), "%Y-%m-%d").date()
            if event.get("recurrence") == "yearly":
                end = end.replace(year=today.year)
        except (ValueError, KeyError):
            end = event_start

        if event_start == end:
            msg += f"\n\U0001f4c5 {format_date_de(event_start)} \u2014 {event['title']}"
        else:
            msg += f"\n\U0001f4c5 {format_date_de(event_start)}\u2013{format_date_de(end)} \u2014 {event['title']}"

        if event.get("time"):
            msg += f" ({event['time']} Uhr)"
        if event.get("location"):
            msg += f" \U0001f4cd {event['location']}"

    return msg

def send_message(chat_id, message):
    """Send a message via Anton CLI."""
    try:
        subprocess.run(
            [ANTON_CLI, "send", str(chat_id), message],
            capture_output=True, timeout=30
        )
        return True
    except Exception as e:
        print(f"Failed to send: {e}", file=sys.stderr)
        return False

def main():
    now = datetime.now()
    today = now.date()
    current_time = now.strftime("%H:%M")
    today_str = today.isoformat()

    events = load_calendar()
    sent = load_sent()

    # Clean old entries (keep current month only)
    sent = {k: v for k, v in sent.items() if k >= today_str[:8]}

    # --- Mode 1: Individual reminders (only for events with explicit "reminder" field) ---
    for event in events:
        if not event.get("reminder"):
            continue  # Skip events without explicit reminder

        if not event_starts_on(event, today):
            continue

        reminder_time = event["reminder"]
        event_id = event.get("id", event.get("title", "unknown"))
        sent_key = f"{today_str}:{event_id}"

        if sent_key in sent:
            continue

        if current_time == reminder_time:
            message = format_reminder(event)
            if send_message(GROUP_CHAT_ID, message):
                sent[sent_key] = now.isoformat()
                save_sent(sent)
                print(f"[{now}] Sent reminder for: {event_id}")

    # --- Mode 2: Weekly briefing (Sunday 19:00) ---
    if today.weekday() == 6 and current_time == "19:00":  # Sunday
        briefing_key = f"{today_str}:weekly-briefing"
        if briefing_key not in sent:
            briefing = format_weekly_briefing(events, today)
            if briefing:
                if send_message(GROUP_CHAT_ID, briefing):
                    sent[briefing_key] = now.isoformat()
                    save_sent(sent)
                    print(f"[{now}] Sent weekly briefing")
            else:
                # No events next week — still mark as sent
                sent[briefing_key] = now.isoformat()
                save_sent(sent)

if __name__ == "__main__":
    main()
