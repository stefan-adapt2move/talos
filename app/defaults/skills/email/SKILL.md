---
name: email
description: Send and receive emails. Use for email composition, replies, thread management, and inbox checking.
---

# Email

Send, receive, and manage emails via the configured mail server (IMAP/SMTP).

## CLI Commands

The email integration is at `/atlas/app/integrations/email/email-addon.py`.

### Send a new email
```bash
python3 /atlas/app/integrations/email/email-addon.py send "recipient@example.com" "Subject line" "Email body text"
```

### Send with attachments
```bash
python3 /atlas/app/integrations/email/email-addon.py send "recipient@example.com" "Report" "Please find attached." --attach /path/to/file.pdf --attach /path/to/other.csv
```

### Reply to a thread
```bash
python3 /atlas/app/integrations/email/email-addon.py reply "thread-id-here" "Reply body text"
```

### Check for new emails (one-time)
```bash
python3 /atlas/app/integrations/email/email-addon.py poll --once
```

### List email threads
```bash
python3 /atlas/app/integrations/email/email-addon.py threads --limit 20
```

### Show thread detail
```bash
python3 /atlas/app/integrations/email/email-addon.py thread "thread-id-here"
```

## Configuration

Email is configured in `~/config.yml` under the `email:` section:

```yaml
email:
  imap_host: "mailcow.mail.svc.cluster.local"  # IMAP server
  imap_port: 143                                 # 993 for TLS, 143 for STARTTLS
  imap_starttls: true                            # Use STARTTLS on port 143
  smtp_host: "mailcow.mail.svc.cluster.local"   # SMTP server
  smtp_port: 587                                  # SMTP submission port
  username: "agent@ai.unclutter.pro"             # Email address
  password_file: "/home/agent/secrets/email-password"
  ssl_verify: false                               # false for self-signed certs
  folder: "INBOX"
  whitelist: []                                   # Empty = accept all
  mark_read: true
```

Alternatively, use environment variables: `EMAIL_IMAP_HOST`, `EMAIL_SMTP_HOST`, `EMAIL_USERNAME`, `EMAIL_PASSWORD`, etc.

## Background Polling

The email poller runs as a background process (managed by supervisord) using IMAP IDLE for real-time notifications. New emails trigger a Claude session via the `email-handler` trigger.

To start manually:
```bash
python3 /atlas/app/integrations/email/email-addon.py poll
```

## Thread Tracking

Every email conversation is tracked as a thread with a unique ID. Replies preserve proper email threading headers (In-Reply-To, References) so recipients see a clean conversation thread in their mail client.

## Email Files

Received emails are saved as searchable markdown files in `~/.index/email/messages/<thread-id>/`. Attachments are saved in `~/.index/email/attachments/<thread-id>/`.

## Notes

- The email addon supports both implicit TLS (port 993/465) and STARTTLS (port 143/587)
- For internal Mailcow with self-signed certificates, set `ssl_verify: false`
- The `whitelist` setting filters incoming emails — leave empty to accept all
- Email credentials should be stored as K8s secrets and mounted as files
