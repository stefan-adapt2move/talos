#!/bin/bash
# Entrypoint: fix volume mount permissions, then start supervisord.
# Runs as agent user (Dockerfile USER directive). Uses sudo for
# privileged operations (chown on mounted volumes).
set -e

# Fix ownership on mounted volumes (may be root-owned from host mounts)
sudo chown -R agent:agent /home/agent

# /atlas/logs: root-owned, group-writable for agent.
# Agent can write logs but cannot delete or tamper with them.
sudo chown -R root:agent /atlas/logs
sudo chmod -R 775 /atlas/logs

# Fix runtime directories (tmpfs, reset on container start)
sudo chown agent:agent /var/run
sudo mkdir -p /var/log/nginx /var/lib/nginx/body
sudo chown -R agent:agent /var/log/nginx /var/lib/nginx

# Clean stale state from previous container run (new PID namespace = all stale)
if [ -f "/home/agent/.index/atlas.db" ]; then
  sqlite3 "/home/agent/.index/atlas.db" "DELETE FROM path_locks;" 2>/dev/null || true
fi

# Resolve agent display name: AGENT_NAME env > config.yml agent.name > "Atlas"
if [ -z "${AGENT_NAME:-}" ]; then
  if [ -f "/home/agent/config.yml" ]; then
    AGENT_NAME=$(grep -A1 '^agent:' "/home/agent/config.yml" 2>/dev/null | grep 'name:' | sed 's/.*name: *"\?\([^"#]*\)"\?.*/\1/' | xargs) || true
  fi
fi
export AGENT_NAME="${AGENT_NAME:-Atlas}"

# Start supervisord directly as agent — all env vars are inherited naturally
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/atlas.conf
