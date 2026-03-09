---
name: skills-guide
description: How to create, structure, and maintain skills. Use when creating a new skill or improving an existing one.
---

# Skills

Skills are structured knowledge packs that teach Atlas how to handle specific domains — document generation, trigger management, dependency installation, design, etc. They are loaded on demand when relevant to the current task.

Skills use **progressive disclosure** (three levels):
1. **Frontmatter** — always loaded in the system prompt; tells Atlas *when* to use the skill
2. **SKILL.md body** — loaded when the skill is triggered; contains full instructions
3. **Linked files** — `references/`, `scripts/`, `assets/` loaded only when needed

## When to Create a Skill

Create a skill when:
- A task type keeps recurring and needs consistent instructions
- There are CLI tools, templates, or conventions to remember
- Domain knowledge is too large for MEMORY.md but needs to be referenceable

Do **not** create a skill for:
- One-off procedures (use memory/journal instead)
- Project-specific notes (use memory/projects/)
- Simple facts (use MEMORY.md)

## Directory Structure

```
~/skills/<skill-name>/
├── SKILL.md              # Main skill document (required)
├── references/           # Documentation loaded as needed (optional)
│   ├── topic-a.md
│   └── topic-b.md
├── scripts/              # Executable code (optional)
│   └── validate.sh
└── assets/               # Templates, fonts, icons (optional)
    └── template.typ
```

- **`SKILL.md`** — The main entry point. Keep it focused, actionable, and under ~5000 words.
- **`references/`** — Supplementary docs: templates, detailed specs, lookup tables. One topic per file.
- **`scripts/`** — Executable code (Python, Bash, etc.) the skill can invoke.
- **`assets/`** — Static files used in output (templates, fonts, icons).

**Important:** Do NOT include a `README.md` inside the skill folder. All documentation goes in SKILL.md or references/.

User-created skills live in `~/skills/` (persist across rebuilds).
System skills live in `app/defaults/skills/` (shipped with the container image).
Both are symlinked into `~/.claude/skills/` on every container start.

## SKILL.md Format

### Frontmatter (required)

```yaml
---
name: my-skill
description: What it does. Use when user asks to [specific triggers].
---
```

#### Naming rules

- **Folder name**: kebab-case only (`my-cool-skill`). No spaces, underscores, or capitals.
- **`name` field**: must match the folder name, kebab-case.
- **`SKILL.md`**: must be exactly `SKILL.md` (case-sensitive). No variations (SKILL.MD, skill.md).
- Names with "claude" or "anthropic" prefix are reserved.

#### The `description` field

This is the most important part — it determines when Atlas loads the skill. Structure it as:

```
[What it does] + [When to use it] + [Key capabilities]
```

Requirements:
- Must include BOTH what the skill does AND when to use it (trigger conditions)
- Under 1024 characters
- No XML angle brackets (`<` or `>`) — security restriction (frontmatter appears in the system prompt)
- Include specific phrases users might say
- Mention relevant file types if applicable

Good examples:
```yaml
# Specific and actionable
description: Generate PDFs, DOCX files, and other documents using Typst, Pandoc, and Playwright. Use when creating invoices, reports, letters, or converting between document formats.

# Includes trigger phrases
description: How to install packages persistently in the container. Use when you need to install system packages, pip packages, or npm tools.
```

Bad examples:
```yaml
# Too vague
description: Useful information about documents.

# Missing triggers
description: Creates sophisticated multi-page documentation systems.

# Too technical, no user triggers
description: Implements the document entity model with hierarchical relationships.
```

#### Optional frontmatter fields

```yaml
---
name: my-skill
description: ...
license: MIT                              # For open-source skills
compatibility: Requires Typst CLI         # Environment requirements (1-500 chars)
allowed-tools: "Bash(python:*) WebFetch"  # Restrict tool access
metadata:
  author: Your Name
  version: 1.0.0
  mcp-server: server-name                 # If skill enhances an MCP server
---
```

### Body

Structure the body for quick scanning:

1. **Quick reference table** — what tool/command for which scenario (if applicable)
2. **Core concepts** — brief explanation of the domain
3. **Practical instructions** — CLI commands, code snippets, step-by-step guides
4. **Examples** — common scenarios with expected input/output
5. **Troubleshooting** — common errors, causes, and solutions

Best practices:
- **Be specific and actionable** — `Run \`python scripts/validate.py --input {file}\`` beats `Validate the data`
- **Include error handling** — document common failures and how to fix them
- **Reference linked files clearly** — `See \`references/invoice.md\` for a ready-to-use template`
- **Use progressive disclosure** — keep SKILL.md focused; move detailed docs to `references/`
- **Critical instructions at the top** — don't bury important rules
- **Composability** — your skill may be loaded alongside others; don't assume exclusivity

## Reference Files

Each file in `references/` should be self-contained about one topic:

```markdown
# Invoice Template (Typst)

A professional invoice with company header, line items table, and payment details.

\```typst
// ... template code ...
\```
```

Guidelines:
- **One topic per file** — don't combine unrelated references
- **Descriptive filename** — `invoice.md`, `api-endpoints.md`, not `ref1.md`
- **Self-contained** — each file should make sense on its own
- **Reference from SKILL.md** — mention available references so they can be found

## Creating a User Skill

```bash
mkdir -p ~/skills/my-skill/references
```

Write `~/skills/my-skill/SKILL.md` with frontmatter and body. Add reference files as needed.

The skill is available immediately — no restart required. The next session that matches the description will load it.

To verify it's linked:
```bash
ls -la ~/.claude/skills/my-skill
```

If the symlink is missing (e.g., created after container start), re-link manually:
```bash
ln -sfn ~/skills/my-skill ~/.claude/skills/my-skill
```

## Discovering Skills

List all available skills:
```bash
ls ~/.claude/skills/
```

## Iteration Tips

- **Undertriggering?** Add more trigger phrases and keywords to the description
- **Overtriggering?** Be more specific; add negative triggers (e.g., "Do NOT use for simple data exploration")
- **Instructions ignored?** Keep them concise, use bullet points, put critical rules at the top
- **Skill feels slow?** Move detailed content to `references/`; keep SKILL.md lean
