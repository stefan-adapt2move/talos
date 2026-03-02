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

## MCP Transport Types

**stdio (recommended)** — spawns a subprocess, communicates via stdin/stdout:
```json
{
  "command": "node",
  "args": ["/path/to/mcp-server.js"]
}
```

**SSE (HTTP)** — connects to a running HTTP server:
```json
{
  "url": "http://localhost:PORT/sse"
}
```

Prefer stdio — SSE servers depend on a running HTTP process and may have startup issues.

## Making an SSE Server Persistent

If the MCP requires an HTTP server, add it to `user-extensions.sh` so it starts with the container:

```bash
# Start MCP server as background daemon
nohup node /path/to/mcp-server.js --port 9000 > /atlas/logs/my-mcp.log 2>&1 &
```

Or register it in supervisord for proper process management.

## Persisting across container restarts

The `~/.atlas-mcp/` directory survives restarts (it's in `$HOME`). But if you install a new npm/pip package for an MCP server, add that install to `user-extensions.sh` too.

## Notes

- Changes to `~/.atlas-mcp/*.json` take effect on the **next session start**
- `system.json` is auto-recreated by `claude-atlas` if deleted — don't edit it directly
- `atlas.json` is yours to manage freely
