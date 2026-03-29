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

# Collect container env vars to forward to agent user.
# sudo env_reset strips all env vars, so we rebuild the env explicitly.
# Captures all app-relevant vars (ANTHROPIC_*, ATLAS_*, S3_*, etc.)
# while excluding Kubernetes-injected service vars (noise).
ENV_ARGS="PATH=/atlas/app/bin:/home/agent/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV_ARGS="$ENV_ARGS HOME=/home/agent"
ENV_ARGS="$ENV_ARGS AGENT_NAME=$AGENT_NAME"
while IFS='=' read -r key value; do
  case "$key" in
    ANTHROPIC_*|ATLAS_*|UNCLUTTER_*|S3_*|SIGNAL_*|TRIGGER_*|TZ|LANG|LC_*)
      ENV_ARGS="$ENV_ARGS $key=$value" ;;
  esac
done < <(env)

# Drop to agent user and start supervisord
# shellcheck disable=SC2086
exec sudo -u agent $ENV_ARGS \
  /usr/bin/supervisord -c /etc/supervisor/conf.d/atlas.conf
