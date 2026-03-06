# Directory Structure

Atlas uses three main filesystem locations with different access patterns.

## /atlas/app/ (Read-Only)

Core application code. Copied into the container image at build time. Not modified at runtime.

```
app/
├── bin/                        # CLI wrappers
│   ├── claude-atlas           # Trigger session launcher (injects system prompt + MCP config)
│   ├── email                  # Email CLI wrapper
│   └── signal                 # Signal CLI wrapper
├── defaults/                   # Default configs seeded on first run
│   ├── config.yml             # Default configuration
│   ├── crontab                # Default cron entries
│   ├── IDENTITY.md            # Default agent identity
│   ├── SOUL.md                # Default agent soul
│   ├── agents/                # Default agent specs (symlinked into .claude/agents/)
│   └── skills/                # System skills (symlinked into .claude/skills/)
├── hooks/                      # Claude Code lifecycle hooks
│   ├── session-start.sh       # Loads memory into context (all sessions)
│   ├── stop.sh                # Path lock cleanup + journal reminder (trigger sessions)
│   ├── pre-compact-auto.sh    # Memory flush before compaction
│   ├── pre-compact-manual.sh  # Memory flush on manual compaction
│   ├── subagent-stop.sh       # Quality gate script (legacy, kept for reference)
│   └── generate-settings.ts  # Generates ~/.claude/settings.json with hooks config
├── atlas-mcp/                  # MCP server (path locking tools)
│   ├── index.ts               # Main MCP server
│   ├── db.ts                  # Database initialization, schema, migrations
│   └── locks.ts               # Path locking module
├── web-ui/                     # Hono.js dashboard
│   └── index.ts               # Web server
├── triggers/                   # Trigger runner scripts
│   ├── trigger.sh             # Generic trigger runner (spawns/resumes trigger sessions)
│   ├── manage.ts              # Trigger management CLI
│   ├── sync-crontab.ts        # Crontab auto-generation from DB
│   └── cron/                  # Cron-specific scripts
├── prompts/                    # Prompt templates
│   ├── trigger-system-prompt.md     # Core trigger session system prompt
│   ├── trigger-channel-*.md         # Channel-specific system prompt additions
│   ├── trigger-*-inject.md          # IPC injection templates (persistent sessions)
│   └── trigger-*-pre-compact.md     # Pre-compaction memory flush prompts
├── nginx.conf                  # nginx reverse proxy config
├── entrypoint.sh               # Container entrypoint (permission fix + supervisord)
└── init.sh                     # Container startup script
```

## /home/atlas/ (Read-Write)

Persistent home directory. Mounted as a Docker volume (`./home:/home/atlas`). Contains all user data.

```
home/
├── .claude/                    # Claude Code configuration
│   ├── settings.json          # Hooks config (written by generate-settings.ts)
│   ├── skills/                # Merged skill directory (per-skill symlinks)
│   │   └── <skill-name> →     # Symlinks to system or user skills
│   └── agents/                # Merged agent directory (per-agent symlinks)
│       └── <agent-name>.md →  # Symlinks to system or user agent specs
├── .atlas-mcp/                 # MCP config for trigger sessions (generated)
│   ├── system.json            # Atlas MCP + memory servers
│   ├── atlas.json             # User-extended MCP servers
│   ├── user.json              # Playwright + other user MCPs
│   └── .merged.json           # Merged MCP config (generated on each trigger run)
├── .index/                     # System state
│   ├── atlas.db               # SQLite database (WAL mode)
│   ├── .trigger-<name>.flock  # Per-trigger flock file (concurrency control)
│   └── signal/, email/        # Channel-specific databases
├── memory/                     # Long-term memory
│   ├── MEMORY.md              # Persistent knowledge base
│   ├── journal/               # Daily journal entries
│   │   └── YYYY-MM-DD.md
│   └── projects/              # Project-specific notes
├── projects/                   # Working directories
├── skills/                     # Atlas-created skills
├── agents/                     # Atlas-created agent specs
├── triggers/                   # Custom trigger prompts
│   └── <trigger-name>/
│       └── prompt.md          # Prompt fallback if DB prompt is empty
├── mcps/                       # User-installed MCP servers
├── secrets/                    # API keys, credentials (denylist)
├── bin/                        # User scripts
├── supervisor.d/               # Supervisord config overrides
├── IDENTITY.md                 # Agent personality
├── SOUL.md                     # Agent soul (core values)
├── config.yml                  # System configuration
├── crontab                     # Generated crontab (managed by sync-crontab.ts)
└── user-extensions.sh          # Custom package installs (runs on container start)
```

## Key Files Reference

| Path | Description |
|------|-------------|
| `app/bin/claude-atlas` | Trigger session launcher: injects system prompt, model, MCP config |
| `app/triggers/trigger.sh` | Trigger runner: spawns or resumes Claude sessions per event |
| `app/hooks/session-start.sh` | Loads memory context on session start |
| `app/hooks/stop.sh` | Path lock cleanup and journal reminder |
| `app/atlas-mcp/index.ts` | MCP server with path locking tools |
| `app/web-ui/index.ts` | Hono.js dashboard server |
| `app/defaults/agents/` | System agent specs (developer, reviewer, etc.) |
| `app/defaults/skills/` | System skills (symlinked into `.claude/skills/`) |
| `/home/atlas/.index/atlas.db` | SQLite database (messages, triggers, sessions, path_locks) |
| `/home/atlas/memory/MEMORY.md` | Long-term memory storage |
| `/home/atlas/IDENTITY.md` | Agent identity/personality |
| `/home/atlas/config.yml` | Runtime configuration |
