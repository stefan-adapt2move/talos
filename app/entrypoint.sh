#!/bin/bash
# Entrypoint: fix home directory permissions, then start supervisord.
# Runs as agent user (Dockerfile USER directive).
set -e

# Fix ownership on home directory volume mount (may be root-owned from host)
# Uses CHOWN capability (granted in pod securityContext) — no sudo needed
# Exclude lost+found (ext4 journal dir, root-owned, may not be chownable)
find /home/agent -maxdepth 1 ! -name lost+found ! -path /home/agent -exec chown -R agent:agent {} + 2>/dev/null
chown agent:agent /home/agent 2>/dev/null || true

# Configurable app name (default: Atlas)
APP_NAME="${APP_NAME:-Atlas}"
APP_NAME_LOWER=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]')
DB_FILENAME="${APP_NAME_LOWER}.db"
export APP_NAME APP_NAME_LOWER DB_FILENAME

# Clean stale state from previous container run (new PID namespace = all stale)
if [ -f "/home/agent/.index/$DB_FILENAME" ]; then
  sqlite3 "/home/agent/.index/$DB_FILENAME" "DELETE FROM path_locks;" 2>/dev/null || true
fi

# Resolve agent display name: AGENT_NAME env > config.yml agent.name > APP_NAME
if [ -z "${AGENT_NAME:-}" ]; then
  if [ -f "/home/agent/config.yml" ]; then
    AGENT_NAME=$(grep -A1 '^agent:' "/home/agent/config.yml" 2>/dev/null | grep 'name:' | sed 's/.*name: *"\?\([^"#]*\)"\?.*/\1/' | xargs) || true
  fi
fi
export AGENT_NAME="${AGENT_NAME:-$APP_NAME}"

# Start supervisord directly as agent — all env vars are inherited naturally
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/atlas.conf
