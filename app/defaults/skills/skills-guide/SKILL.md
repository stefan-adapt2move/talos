---
name: skills-guide
description: How to create, structure, and maintain skills. Use when creating a new skill or improving an existing one.
---

# Skills

Skills are structured knowledge packs that teach Atlas how to handle specific domains — document generation, trigger management, dependency installation, design, etc. They are loaded on demand when relevant to the current task.

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
└── references/           # Supporting reference files (optional)
    ├── topic-a.md
    └── topic-b.md
```

- **`SKILL.md`** — The main entry point. Loaded into context when the skill is invoked. Keep it focused and actionable.
- **`references/`** — Supplementary material: templates, detailed specs, lookup tables, examples. Each file covers one topic. Referenced from SKILL.md but only loaded when specifically needed.

System skills live in `app/defaults/skills/` (shipped with the container image).
User-created skills live in `~/skills/` (persist across rebuilds).
Both are symlinked into `~/.claude/skills/` on every container start.

## SKILL.md Format

### Frontmatter (required)

```yaml
---
name: my-skill
description: One-line description of when to use this skill. Be specific about triggers.
---
```

The `description` field is critical — it determines when Claude loads this skill. Write it as a trigger condition:
- Good: `"Generate PDFs, DOCX files, and other documents using Typst, Pandoc, and Playwright."`
- Good: `"How to install packages persistently in the container. Use when you need to install system packages, pip packages, or npm tools."`
- Bad: `"Useful information about documents"`

### Body

Structure the body for quick scanning:

1. **Quick reference table** — what tool/command for which scenario (if applicable)
2. **Core concepts** — brief explanation of the domain
3. **Practical instructions** — CLI commands, code snippets, step-by-step guides
4. **Best practices** — pitfalls to avoid, conventions to follow

Keep SKILL.md under ~200 lines. Move detailed content (templates, large examples, lookup tables) into `references/`.

## Reference Files

Each file in `references/` should be a self-contained document about one topic:

```markdown
# Invoice Template (Typst)

A professional invoice with company header, line items table, tax calculation, and payment details.

\```typst
// ... template code ...
\```
```

Guidelines:
- **One topic per file** — don't combine unrelated references
- **Descriptive filename** — `invoice.md`, `api-endpoints.md`, not `ref1.md`
- **Self-contained** — each file should make sense on its own, include a brief description at the top
- **Reference from SKILL.md** — mention available references so they can be found:
  ```
  See `references/invoice.md` for a ready-to-use invoice template.
  ```

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

If the symlink is missing (e.g., created after container start), re-run skill discovery:
```bash
ln -sfn ~/skills/my-skill ~/.claude/skills/my-skill
```

## Updating System Skills

System skills in `app/defaults/skills/` are part of the container image. To modify them:

1. Edit the files in the repo (`app/defaults/skills/<name>/`)
2. Create a PR, merge, and rebuild the image

User skills in `~/skills/` override system skills with the same name (the symlink from `~/skills/` wins over `app/defaults/skills/`).

## Discovering Skills

List all available skills:
```bash
ls ~/.claude/skills/
```
