# Triggers

Triggers are autonomous agent sessions that process events independently. Each trigger spawns its own Claude session, acts as a project manager, and delegates work to ephemeral task-runners.

## Architecture

```
Event arrives (cron / webhook / manual)
         │
         ▼
┌─────────────────────────────┐
│  trigger.sh <trigger-name>  │
│  Spawns own Claude session  │
│  (PM role, MCP access)      │
└──────────┬──────────────────┘
           │
     ┌─────┴──────┐
     │  Can handle │
     │  itself?    │
     └─────┬──────┘
       Yes │        No
       ┌───┘        └───┐
       ▼                ▼
┌──────────────┐  ┌──────────────────────┐
│ Respond      │  │ task_create() with   │
│ directly     │  │ content, path, review│
│ (CLI tools,  │  │ → .wake-task-<id>    │
│  MCP action) │  │ → watcher dispatches │
└──────────────┘  │ → task-runner.sh     │
                  │ → result via .wake   │
                  └──────────────────────┘
```

### Session Types

| | Trigger Session | Ephemeral Worker | Review Agent |
|---|---|---|---|
| **Role** | Project manager, user communication | Execute a single task | Verify worker output |
| **Access** | Workspace (PM scope) | Read/write workspace | Read workspace |
| **MCPs** | inbox-mcp, qmd | Playwright only | Playwright only |
| **Spawned by** | `trigger.sh` per event | `task-runner.sh` per task | `task-runner.sh` after worker |
| **Session persistence** | Configurable per trigger | Fresh per task | Fresh per task |

### Session Modes

Each trigger has a configurable `session_mode`:

| Mode | Behavior | Use Case |
|------|----------|----------|
| `ephemeral` | New session per run, discarded after | Cron jobs, one-off webhooks |
| `persistent` | Resume session based on session key | Signal channel, email thread, ongoing context |

### Session Key

Persistent triggers use a **session key** to determine which session to resume. The key is passed as the 3rd argument to `trigger.sh`:

```bash
trigger.sh <trigger-name> [payload] [session-key]
```

The `(trigger_name, session_key)` pair maps to a session ID in the `trigger_sessions` table. This means one trigger can manage many independent sessions:

| Trigger | Session Key | Effect |
|---------|-------------|--------|
| `email-handler` | `thread-4821` | Resumes the session for that email thread |
| `email-handler` | `thread-9944` | Different session for a different thread |
| `signal-chat` | `+49170123456` | Per-contact conversation session |
| `deploy-hook` | `repo-myapp` | Per-repository deployment context |
| `daily-standup` | *(none)* | `_default` key — one global session |

If no session key is provided, it defaults to `_default` (one session per trigger).

## Trigger Types

### Cron

Scheduled execution via supercronic. Uses standard cron syntax.

| Schedule | Meaning |
|----------|---------|
| `*/15 * * * *` | Every 15 minutes |
| `0 * * * *` | Every hour |
| `0 9 * * 1-5` | Weekdays at 9:00 |
| `0 6 * * *` | Daily at 6:00 |
| `0 8 * * 1` | Mondays at 8:00 |

Typically `ephemeral` — each run is independent.

The crontab at `workspace/crontab` is auto-generated from the triggers database. Static entries (like the daily cleanup) are preserved above the `AUTO-GENERATED` marker. Manage cron triggers via the web-ui or MCP tools.

### Webhook

HTTP endpoints that accept POST requests:

```
POST /api/webhook/<trigger-name>
```

The request payload is injected into the prompt template via `{{payload}}`. Optional authentication via `X-Webhook-Secret` header.

Typically `ephemeral` per event, but can be `persistent` if webhook events relate to an ongoing conversation.

### Manual

On-demand triggers. Fire via the web-ui "Run" button or by asking Claude.

## Creating Triggers

### Via Web-UI

1. Navigate to `/triggers`
2. Click **+ New Trigger**
3. Fill in the form:
   - **Name:** Lowercase slug (e.g. `github-check`)
   - **Type:** Cron, Webhook, or Manual
   - **Schedule:** Cron expression (for cron triggers)
   - **Session Mode:** `ephemeral` (default) or `persistent`
   - **Webhook Secret:** Optional auth token (for webhooks)
   - **Channel:** Inbox channel for generated messages (default: `internal`)
   - **Prompt:** What the trigger session should do. Use `{{payload}}` for webhook data.
4. Click **Create Trigger**

### Via MCP

```json
{
  "name": "github-issues",
  "type": "cron",
  "schedule": "0 * * * *",
  "session_mode": "ephemeral",
  "description": "Hourly GitHub issue check",
  "prompt": "Check GitHub repos for new issues. If there are critical issues, create tasks via task_create."
}
```

### Via curl

```bash
curl -X POST http://localhost:8080/triggers \
  -d "name=my-trigger" \
  -d "type=manual" \
  -d "session_mode=ephemeral" \
  -d "description=Test trigger" \
  -d "prompt=Hello, this is a test trigger."
```

## Webhook Integration

### Setup

1. Create a webhook trigger (via web-ui or MCP):
   - Name: `github-push`
   - Type: Webhook
   - Secret: `my-secret-token` (optional)
   - Prompt: `A push event was received:\n\n{{payload}}\n\nSummarize the changes.`

2. Configure the external service to POST to your Atlas instance:
   ```
   URL:    https://your-atlas-host:8080/api/webhook/github-push
   Secret: my-secret-token  (as X-Webhook-Secret header)
   ```

### Request Format

Webhooks accept any content type:

**JSON:**
```bash
curl -X POST http://localhost:8080/api/webhook/github-push \
  -H "X-Webhook-Secret: my-secret-token" \
  -H "Content-Type: application/json" \
  -d '{"ref": "refs/heads/main", "commits": [{"message": "fix: resolve login bug"}]}'
```

**Form data:**
```bash
curl -X POST http://localhost:8080/api/webhook/contact-form \
  -H "X-Webhook-Secret: my-secret-token" \
  -d "name=Alice&email=alice@example.com&message=Hello"
```

**Plain text:**
```bash
curl -X POST http://localhost:8080/api/webhook/alert \
  -H "X-Webhook-Secret: my-secret-token" \
  -d "Server CPU at 95%"
```

### Response

```json
{ "ok": true, "trigger": "github-push", "message": "Trigger session started" }
```

### Authentication

If `webhook_secret` is set, the webhook validates the `X-Webhook-Secret` header (or `?secret=` query parameter). Requests without a matching secret are rejected with 401.

If no secret is configured, the webhook accepts all requests.

### Payload in Prompts

The `{{payload}}` placeholder is replaced with the request body:

| Content-Type | Payload Format |
|-------------|----------------|
| `application/json` | Pretty-printed JSON |
| `application/x-www-form-urlencoded` | JSON of parsed form fields |
| Anything else | Raw text body |

## Task Delegation

Trigger sessions act as project managers. The delegation flow:

1. **Trigger session processes the event** using its prompt
2. **Simple case**: Handle directly — respond via CLI tools (`signal send` / `email reply`), take quick actions, done
3. **Complex case**: Create one or more tasks via `task_create(content, path?, review?)`
4. `task_create` writes `.wake-task-<id>` → watcher dispatches task-runner
5. Task-runner spawns ephemeral worker (and optional reviewer)
6. On completion, trigger session is re-awakened with the result

### Single Task Delegation

```
task_create(content="Review and fix issue #42: login page crashes on Safari", path="/home/atlas/projects/webapp")
```

### Multi-Task Delegation (Parallel)

Tasks with non-overlapping paths run in parallel:

```
task_create(content="Update CHANGELOG.md with v2.3.0 release notes", path="/home/atlas/projects/webapp")
task_create(content="Run post-deploy smoke tests and report results", review=false)
task_create(content="Notify stakeholders about the v2.3.0 release", review=false)
```

## Integration Examples

### GitHub Webhooks (Filter + Delegate)

```
Name:           github-push
Type:           Webhook
Session Mode:   ephemeral
Secret:         (generate one)
Prompt:         A push event was received:

                {{payload}}

                Analyze the commits. If there are only docs changes, just log it.
                If there are code changes, create a task via task_create with a summary
                of what changed and what needs review.
```

### Signal Channel (Persistent Session)

```
Name:           signal-alice
Type:           Webhook
Session Mode:   persistent
Channel:        signal
Prompt:         New message from Signal:

                {{payload}}

                Respond conversationally. If the message requests a complex task
                (code changes, research report, etc.), delegate via task_create.
```

### Daily Standup (Ephemeral Cron)

```
Name:           standup-reminder
Type:           Cron
Schedule:       0 9 * * 1-5
Session Mode:   ephemeral
Prompt:         Prepare a standup summary using qmd_search to check recent memory.
                If there are pending items that need attention, create tasks for them
                via task_create.
```

### Health Check (Filter, Delegate Only on Problems)

```
Name:           health-check
Type:           Cron
Schedule:       */30 * * * *
Session Mode:   ephemeral
Prompt:         Run a system health check (disk, memory, services).
                Only create a task if something needs attention.
                Otherwise, silently succeed.
```

## Managing Triggers

### Web-UI

The `/triggers` page provides full CRUD:
- **List** all triggers with type, status, session mode, schedule/URL, last run, run count
- **Toggle** enable/disable (HTMX live update)
- **Run** any trigger manually (even cron triggers)
- **Edit** description, schedule, prompt, secret, channel, session mode
- **Delete** with confirmation

### MCP Tools

| Tool | Description |
|------|-------------|
| `trigger_list` | List all triggers (optional filter by type) |
| `trigger_create` | Create with name, type, schedule, prompt, session_mode, secret |
| `trigger_update` | Update fields by name |
| `trigger_delete` | Delete by name |

### Prompt Fallback

If a trigger's `prompt` field is empty, `trigger.sh` looks for:
```
workspace/triggers/cron/<trigger-name>/event-prompt.md
```

## Crontab Sync

When cron triggers are created, updated, or deleted, the crontab is automatically regenerated:

1. Static entries (above `AUTO-GENERATED` marker) are preserved
2. All enabled cron triggers from the database are appended
3. supercronic detects the file change and reloads

## How It All Connects

```
                           ┌─────────────┐
                           │  supercronic │
                           │  (crontab)   │
                           └──────┬──────┘
                                  │ schedule fires
                                  ▼
┌───────────┐         ┌──────────────────┐         ┌──────────────┐
│ External   │  POST   │    Web-UI        │  button  │  Claude      │
│ Service    │────────▸│  /api/webhook/   │◂────────│  MCP: trigger│
└───────────┘         │  /triggers/:id/  │         │  _create     │
                      │  run             │         └──────────────┘
                      └────────┬─────────┘
                               │
                               ▼
                    ┌────────────────────┐
                    │ trigger.sh <name>  │
                    │ Spawns trigger     │
                    │ Claude session     │
                    │ (PM role + MCPs)   │
                    └────────┬───────────┘
                             │
                   ┌─────────┴─────────┐
                   │                   │
              Handles it          Delegates via
              directly            task_create()
                   │                   │
                   ▼                   ▼
              ┌─────────┐    ┌────────────────┐
              │  Done   │    │ .wake-task-<id>│
              └─────────┘    └───────┬────────┘
                                     │
                                     ▼
                            ┌────────────────┐
                            │ watcher.sh     │
                            │ → task-runner  │
                            │ → worker/review│
                            │ → trigger wakes│
                            └────────────────┘
```
