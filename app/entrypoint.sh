#!/bin/bash
# Entrypoint: fix volume mount permissions, then drop to atlas user.
# Runs as root (container default) to chown mounted volumes, then
# execs supervisord as the atlas user.
set -e

# Fix ownership on mounted volumes (may be root from previous deploy)
chown -R atlas:atlas /home/atlas /atlas/logs

# Fix runtime directories (tmpfs, reset on container start)
chown atlas:atlas /var/run
mkdir -p /var/log/nginx /var/lib/nginx/body
chown -R atlas:atlas /var/log/nginx /var/lib/nginx

# Clean up stale QMD PID files from previous runs
rm -f /home/atlas/.cache/qmd/*.pid /tmp/qmd*.pid 2>/dev/null || true

# Clean stale state from previous container run (new PID namespace = all stale)
if [ -f "/home/atlas/.index/atlas.db" ]; then
  sqlite3 "/home/atlas/.index/atlas.db" "
    DELETE FROM path_locks;
    UPDATE tasks SET status='failed', response_summary='Container restarted' WHERE status='processing';
  " 2>/dev/null || true
fi

# Drop to atlas user and start supervisord
# Pass PATH explicitly — sudo env_reset strips the Dockerfile ENV PATH otherwise
exec sudo -u atlas \
  PATH="/atlas/app/bin:/home/atlas/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  HOME="/home/atlas" \
  /usr/bin/supervisord -c /etc/supervisor/conf.d/atlas.conf
