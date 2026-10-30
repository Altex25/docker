#!/bin/sh
set -eu
DRAIN_FILE=${DRAIN_FILE:-/tmp/geststock-drain}
rm -f "$DRAIN_FILE"

if [ "$#" -gt 0 ] && [ "$1" != apache2-foreground ]; then
  exec "$@"
fi

apache2-foreground &
pid=$!
drain() {
  touch "$DRAIN_FILE"
  echo "{\"time\":\"$(date -Iseconds)\",\"level\":\"info\",\"app\":\"geststock\",\"msg\":\"SIGTERM : drain ${DRAIN_SECONDS:-5}s puis arrêt gracieux d'Apache\"}" >&2
  sleep "${DRAIN_SECONDS:-5}"
  kill -WINCH "$pid" 2>/dev/null || true
}
trap drain TERM
trap 'kill -WINCH "$pid" 2>/dev/null || true' INT
set +e
wait "$pid"
status=$?
while kill -0 "$pid" 2>/dev/null; do
  wait "$pid"
  status=$?
done
wait "$pid" 2>/dev/null
last=$?
[ "$last" -ne 127 ] && status=$last
exit "$status"
