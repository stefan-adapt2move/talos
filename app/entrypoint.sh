#!/bin/bash
# Entrypoint: fix volume mount permissions, then drop to agent user.
# Runs as root (container default) to chown mounted volumes, then
# execs supervisord as the agent user.
set -e

# Fix ownership on mounted volumes (may be root from previous deploy)
chown -R agent:agent /home/agent /atlas/logs

# Fix runtime directories (tmpfs, reset on container start)
chown agent:agent /var/run
mkdir -p /var/log/nginx /var/lib/nginx/body
chown -R agent:agent /var/log/nginx /var/lib/nginx

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

# Drop to agent user and start supervisord
# Pass PATH explicitly — sudo env_reset strips the Dockerfile ENV PATH otherwise
exec sudo -u agent \
  PATH="/atlas/app/bin:/home/agent/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  HOME="/home/agent" \
  AGENT_NAME="$AGENT_NAME" \
  /usr/bin/supervisord -c /etc/supervisor/conf.d/atlas.conf
