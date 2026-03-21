---
name: mcp-install
description: How to install and configure MCP servers. Use when adding new MCP tools, configuring MCPs for specific session types, or managing MCP config files.
---

# Installing MCP Servers

## How MCP Config Works

**Trigger sessions** (the main agent sessions) load MCP servers programmatically:

1. **System servers** (work, memory) — always loaded, built into `trigger-runner`
2. **User servers** — loaded from `~/.atlas-mcp/user.json` and `~/.mcp.json` (both are checked; pick one)

**Worker/agent sessions** (spawned by trigger sessions via `Agent(...)`) inherit the parent's MCP config or receive their own via the SDK `mcpServers` option.

## Adding an MCP Server

Edit either `~/.atlas-mcp/user.json` or `~/.mcp.json` — both work, pick one location to keep things simple.

```json
{
  "mcpServers": {
    "my-tool": {
      "command": "node",
      "args": ["/path/to/mcp-server.js"]
    }
  }
}
```

Changes take effect on the **next session start**.

## Stdio vs URL-Based Servers

**Stdio** — spawns a subprocess per session. Use this for most servers:

```json
{
  "command": "node",
  "args": ["/path/to/mcp-server.js"]
}
```

**URL-based (SSE/HTTP)** — connects to an already-running server. These are **NOT supported in trigger sessions** (they cause silent exit issues). Use stdio instead, or connect to already-running services like Playwright via the built-in config.

Already-running services available in the container:

| Service | URL | Notes |
|---------|-----|-------|
| Playwright | `http://localhost:8931/sse` | Already configured in default user.json |

## Running an MCP Server as a Daemon (supervisord)

For servers that need to persist across sessions, run them via supervisord and connect via stdio from a wrapper script. Or, if URL transport is needed (worker sessions only), register the daemon:

Create `/etc/supervisor/conf.d/my-mcp.conf`:

```ini
[program:my-mcp]
command=node /path/to/mcp-server.js --port 9000
autostart=true
autorestart=true
stdout_logfile=/atlas/logs/my-mcp.log
stderr_logfile=/atlas/logs/my-mcp.log
```

Then reload:

```bash
supervisorctl reread && supervisorctl update
supervisorctl start my-mcp
```

To persist across container restarts, add the config to `~/user-extensions.sh`:

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

## Persisting Across Container Restarts

`~/.atlas-mcp/user.json` and `~/.mcp.json` are in `$HOME` and survive restarts. If your MCP server requires a package install (npm, pip, etc.), add that install to `~/user-extensions.sh`.
