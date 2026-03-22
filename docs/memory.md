# Memory System

Atlas uses a file-based memory system with plain Markdown files, YAML frontmatter, and `[[wikilinks]]` for cross-referencing. Memory retrieval is done directly via grep, glob, and file reads — no external indexing daemon required.

## Architecture

Memory lives in `workspace/memory/` as structured Markdown files. Two specialized sub-agents handle reading and writing:

- **memory-searcher** (haiku) — Finds information using grep/glob/read across the memory directory
- **memory-writer** (sonnet) — Persists new knowledge into the correct files with proper frontmatter

Both agents operate on the filesystem directly. No MCP server or indexing process is needed.

## Directory Structure

```
~/memory/
├── MEMORY.md              — High-level index (max 200 lines)
├── entities/              — Services, platforms, people, companies
│   └── <name>.md
├── decisions/             — Key decisions with rationale
│   └── <YYYY-MM-DD>-<slug>.md
├── workflows/             — Learned procedures, playbooks, patterns
│   └── <name>.md
├── journal/               — Daily session logs (full detail, never compressed)
│   └── YYYY-MM-DD.md
└── projects/              — Project-specific notes and architecture
    └── <project-name>.md
```

## Frontmatter Format

All memory files use YAML frontmatter:

```yaml
---
type: entity | decision | workflow | journal | project
date: YYYY-MM-DD
tags: [infrastructure, mapstudio, ...]
related: ["[[other-file]]", "[[another-file]]"]
status: active | completed | superseded | archived
expires: YYYY-MM-DD  # optional
---
```

## Retrieval Strategy

The memory-searcher agent uses a layered approach:

1. **MEMORY.md first** — The index often points directly to the right file
2. **Filename search** — Glob patterns to find files by name (`entities/*signal*.md`)
3. **Content search** — Grep across memory for keywords, dates, or patterns
4. **Frontmatter filtering** — Grep on `type:`, `status:`, `tags:` to narrow results
5. **Wikilink traversal** — Follow `[[wikilinks]]` in `related:` fields to find connected info
6. **Full file reads** — Read complete files once identified

This approach is more reliable than semantic search for structured data and gives deterministic results.

## Writing Strategy

The memory-writer agent classifies incoming information and routes it:

- **New service/tool/person** → `entities/<name>.md`
- **Decision with rationale** → `decisions/<date>-<slug>.md`
- **Repeatable process** → `workflows/<name>.md`
- **Project update** → `projects/<project>.md`
- **User preferences** → Relevant entity, project, or MEMORY.md

The journal (`journal/YYYY-MM-DD.md`) is always written by the team lead, never by sub-agents.

## Configuration

```yaml
memory:
  load_memory_md: true         # Load full MEMORY.md on session start
  load_journal_days: 7         # Show recent journal entry titles on start
```

## Usage in Sessions

Claude uses memory-searcher automatically for recall:

```
"What did we decide about the auth system last week?"
→ memory-searcher: Grep(pattern="auth", path="~/memory/decisions/")
→ Found in decisions/2026-02-20-auth-system.md: "Decided to use JWT with refresh tokens..."
```

And memory-writer for persistence:

```
"We decided to use Postgres instead of SQLite for the new service"
→ memory-writer: Creates decisions/2026-03-21-postgres-over-sqlite.md with context and rationale
```
