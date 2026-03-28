# Development Guide

Building and running Talos for development.

## Build

```bash
docker compose build
```

## Start

```bash
docker compose up -d
```

The Web-UI is available at http://localhost:8080.

## OAuth Login (One-Time)

```bash
docker run -it --rm -v $(pwd)/volume:/home/agent talos claude login
```

This stores credentials in `volume/.claude/` for persistence across restarts.

## View Logs

```bash
# All logs
docker compose logs -f

# Specific services
docker compose logs -f talos

# Inside container
docker compose exec talos tail -f /talos/logs/init.log
docker compose exec talos tail -f /talos/logs/trigger-<name>.log
docker compose exec talos tail -f /talos/logs/talos-mcp.log
```

## Service Status

```bash
docker compose exec talos supervisorctl status
```

Services managed by supervisord:
- `nginx` — Reverse proxy (port 8080)
- `web-ui` — Dashboard (port 3000)
- `talos-mcp` — Path locking MCP server (stdio)
- `playwright-mcp` — Playwright browser automation (port 8931)
- `supercronic` — Cron runner

## Rebuild After Code Changes

```bash
docker compose build && docker compose up -d
```

## Access Container Shell

```bash
docker compose exec talos bash
```

## Database Access

```bash
docker compose exec talos sqlite3 /home/agent/.index/talos.db
```

## Test Webhook Locally

```bash
curl -X POST http://localhost:8080/api/webhook/test-trigger \
  -H "Content-Type: application/json" \
  -d '{"message": "Hello from curl"}'
```

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `TALOS_TRIGGER` | Set to trigger name when running as trigger session |
| `TALOS_TRIGGER_CHANNEL` | Channel for trigger context (internal, signal, email, web) |
| `TALOS_TRIGGER_SESSION_KEY` | Session key for persistent triggers |
| `CLAUDE_SESSION_ID` | Current session ID (set by Claude Code) |

## File Locations in Container

| Path | Purpose |
|------|---------|
| `/talos/app/` | Core code (read-only) |
| `/home/agent/` | Persistent data |
| `/talos/logs/` | Log files |
| `/home/agent/.claude/` | Claude Code config |
