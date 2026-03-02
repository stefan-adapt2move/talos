---
name: mcp-install
description: How to install and configure MCP servers in Atlas. Use when adding new MCP tools, configuring MCPs for specific session types, or managing the ~/.atlas-mcp/ directory.
---

# Installing MCP Servers

Atlas uses a three-file MCP config in `~/.atlas-mcp/`:

| File | Available in | Purpose |
|------|-------------|---------|
| `system.json` | Trigger only | inbox + memory (system-managed, don't edit) |
| `atlas.json` | Trigger only | Atlas-managed MCPs — add your own here |
| `user.json` | All sessions | User MCPs like Playwright |

`claude-atlas` selects configs via `--mcp-config ... --strict-mcp-config` per `--mode`. `~/.mcp.json` is fully ignored by all Atlas sessions.

## Add an MCP for All Sessions (trigger + worker)

Edit `~/.atlas-mcp/user.json`:

```json
{
  "mcpServers": {
    "playwright": {
      "url": "http://localhost:8931/sse"
    },
    "my-tool": {
      "command": "node",
      "args": ["/path/to/server.js"]
    }
  }
}
```

## Add an MCP for Trigger Sessions Only

Edit `~/.atlas-mcp/atlas.json` (Atlas-managed):

```json
{
  "mcpServers": {
    "my-atlas-tool": {
      "command": "npx",
      "args": ["-y", "@example/mcp-server"]
    }
  }
}
```

## Pre-running Services (use URL transport)

Several MCP servers are already running in the container via supervisord — reference them by URL instead of spawning new processes:

| Service | URL | Notes |
|---------|-----|-------|
| QMD (memory) | `http://localhost:8181/mcp` | Already in `system.json` |
| Playwright | `http://localhost:8931/sse` | Already in `user.json` |

```json
{ "url": "http://localhost:8181/mcp" }
```

## MCP Transport Types

**SSE/HTTP** — connects to an already-running HTTP server (preferred for daemons):
```json
{ "url": "http://localhost:PORT/sse" }
```
Use `/sse` or `/mcp` depending on what the server supports (`/mcp` for QMD, `/sse` for Playwright).

**stdio** — spawns a fresh subprocess per session (use when no daemon is running):
```json
{
  "command": "node",
  "args": ["/path/to/mcp-server.js"]
}
```

## Running a New MCP Server as a Daemon (supervisord)

For MCP servers that need to persist across sessions, register them with supervisord:

Create `/etc/supervisor/conf.d/my-mcp.conf`:
```ini
[program:my-mcp]
command=node /path/to/mcp-server.js --port 9000
autostart=true
autorestart=true
stdout_logfile=/atlas/logs/my-mcp.log
stderr_logfile=/atlas/logs/my-mcp.log
```

Then reload supervisord:
```bash
supervisorctl reread && supervisorctl update
supervisorctl start my-mcp
```

To make it survive container restarts, add the config to `user-extensions.sh`:
```bash
cat > /etc/supervisor/conf.d/my-mcp.conf << 'EOF'
[program:my-mcp]
command=node /path/to/mcp-server.js --port 9000
autostart=true
autorestart=true
stdout_logfile=/atlas/logs/my-mcp.log
stderr_logfile=/atlas/logs/my-mcp.log
EOF
supervisorctl reread && supervisorctl update
```

## Persisting across container restarts

The `~/.atlas-mcp/` directory survives restarts (it's in `$HOME`). But if you install a new npm/pip package for an MCP server, add that install to `user-extensions.sh` too.

## Notes

- Changes to `~/.atlas-mcp/*.json` take effect on the **next session start**
- `system.json` is auto-recreated by `claude-atlas` if deleted — don't edit it directly
- `atlas.json` is yours to manage freely
