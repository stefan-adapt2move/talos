---
name: reminders
description: Schedule one-time reminder events. Use when you need to be reminded about something at a specific time.
---

# Reminders

Schedule one-time events that fire at a specific time. Each reminder runs a Claude session with the given prompt when the time arrives.

## CLI Commands

### Add a reminder
```bash
reminder add --title="Team standup" --at="2026-03-08 09:00" --prompt="Send Max the daily standup summary via Signal"
reminder add --title="Deploy check" --at="+2h" --prompt="Check if the deployment succeeded"
reminder add --title="Quick note" --at="+30m" --prompt="Remind Max about the meeting"
```

### Time formats for --at
- Full datetime: `"2026-03-08 14:00"` or `"2026-03-08T14:00:00"` (local timezone)
- Time only (today): `"14:00"`
- Relative: `"+30m"`, `"+2h"`, `"+1d"`

### List reminders
```bash
reminder list          # pending only
reminder list --all    # include fired/cancelled
```

### Cancel/delete a reminder
```bash
reminder cancel --id=5  # mark as cancelled (keeps history)
reminder delete --id=5  # permanently remove
```

## How It Works

- Reminders are stored in the SQLite database (`~/.index/atlas.db`) in the `reminders` table
- A cron job checks for due reminders every minute: `* * * * * bun /atlas/app/triggers/manage-reminders.ts check`
- When a reminder fires, it spawns a `claude-atlas --mode trigger` session with the reminder's prompt
- Fired and cancelled reminders older than 30 days are automatically cleaned up by the daily cleanup job

## Notes

- The `--at` time is stored in UTC internally; it is displayed in local time when listing
- Each reminder fires exactly once — use recurring cron triggers for repeating events
- The `--channel` flag (default: `internal`) sets the `ATLAS_TRIGGER_CHANNEL` environment variable for the spawned session
