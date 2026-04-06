---
name: dependencies
description: Use when installing system packages, Python libs, or JS/TS modules persistent. Use when you need a tool or library that isn't pre-installed, or when the user asks to install something.
---

# Installing Dependencies

You have **no root or sudo access**. Everything outside `~/` (`/home/agent/`) is lost on container restart. Use the tools below to install what you need.

| What | How | Example |
|------|-----|---------|
| System packages | `brew install <pkg>` | `brew install imagemagick` |
| Python packages | `pip install <pkg>` | `pip install requests` |

Search for Homebrew packages: `brew search <name>` or https://formulae.brew.sh

Remove a Homebrew package: `brew uninstall <package>`

## Survive Restarts

Packages installed via Homebrew persist across restarts (stored in `/home/linuxbrew/.linuxbrew/`). Python packages installed via pip outside the home directory may be lost — use `pip install --user <pkg>` or add install commands to `~/user-extensions.sh`:

```bash
#!/bin/bash
pip install requests
```

This script runs automatically on every container start.

## Gotchas

- **Never use `apt-get` or `sudo`** — you don't have access. Use `brew install` instead.
- Homebrew package names usually match what you expect (e.g. `brew install python3`, `brew install ffmpeg`).
- First `brew install` may be slow (updates tap). Use `HOMEBREW_NO_AUTO_UPDATE=1 brew install <pkg>` to skip.
- No Docker daemon available — you cannot run `docker` commands.

## Pre-installed

Bun, Node.js, Python, git, sqlite3, curl, wget, jq, ripgrep, ffmpeg, pandoc, typst, chromium, browser (headless web CLI — see browser skill)
