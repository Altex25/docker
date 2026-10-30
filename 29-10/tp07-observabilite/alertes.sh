#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

firing() { curl -s localhost:9090/api/v1/alerts | jq -r '[.data.alerts[] | select(.state == "firing") | .labels.alertname] | unique | join(" ")'; }
summary() { curl -s localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | "  \(.state)\t\(.labels.alertname)\t\(.labels.name // .labels.instance // "")\t\(.annotations.summary)"' | sort; }
log() { echo "$(date +%H:%M:%S) $*"; }
trafic() { local end=$((SECONDS + $2)); while [ $SECONDS -lt $end ]; do CONCURRENCY=$1 ./load.sh 40 > /dev/null 2>&1; done; }
wait_for() {
  for _ in $(seq 60); do
    [[ " $(firing) " == *" $1 "* ]] && return 0
    sleep 5
  done
  return 1
}

start=$(date +%s000)

log "phase 1 : $(./pannes.sh memoire-api)"
trafic 100 30
wait_for ContainerOomKilled
log "phase 1 : $(./pannes.sh crash shop-worker-1)"
wait_for ContainerRestarting
log "alertes firing : $(firing)"
log "$(./pannes.sh restore | head -1)"

trafic 2 1200 &
load_pid=$!
log "phase 2 : $(./pannes.sh latence-db)"
wait_for ApiHighLatencyP95
log "alertes firing : $(firing)"

log "phase 3 : $(./pannes.sh fuite-memoire)"
wait_for ContainerMemoryNearLimit
log "alertes firing : $(firing)"

kill "$load_pid" 2> /dev/null
wait "$load_pid" 2> /dev/null
stop=$(date +%s000)
echo
echo "== /api/v1/alerts"
summary
echo
FROM=$((start - 60000)) TO=$stop ALERTS=1 ./captures.sh alertes-firing
echo
log "$(./pannes.sh restore | head -1)"
