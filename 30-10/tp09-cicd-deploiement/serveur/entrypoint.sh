#!/bin/sh
set -e
ssh-keygen -A > /dev/null
if [ -n "${DEPLOY_AUTHORIZED_KEY:-}" ]; then
  printf '%s\n' "$DEPLOY_AUTHORIZED_KEY" > /home/deploy/.ssh/authorized_keys
  chown deploy:deploy /home/deploy/.ssh/authorized_keys
  chmod 0600 /home/deploy/.ssh/authorized_keys
fi
/usr/sbin/sshd -e
exec dockerd-entrypoint.sh "$@"
