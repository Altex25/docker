#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."

PROJECT=${PROJECT:-shop}
TP04=../tp04-compose-entreprise
MEM_MAX=${MEM_MAX:-90}
CPU_MAX=${CPU_MAX:-80}
INTERVAL=${INTERVAL:-10}
ROUNDS=${ROUNDS:-0}
WEBHOOK=${WEBHOOK:-}
STATE=$(mktemp -d)

EXPECTED="api:node worker:python db:postgres redis:redis-server traefik:traefik"

alert() {
  local key=$1 msg=$2
  [ -e "$STATE/$key" ] && return 0
  : > "$STATE/$key"
  echo "$(date +%H:%M:%S) ALERTE $msg"
  [ -n "$WEBHOOK" ] && curl -s -m 3 -o /dev/null -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg m "$msg" --arg k "$key" '{source: "b4-alerte-minimale", key: $k, message: $m}')" "$WEBHOOK"
  return 0
}
resolve() {
  [ -e "$STATE/$1" ] || return 0
  rm -f "$STATE/$1"
  echo "$(date +%H:%M:%S) RÉSOLU $1"
}

check() {
  local line name svc proc pair top mem cpu limit
  while IFS= read -r line; do
    name=$(jq -r .Name <<< "$line")
    mem=$(jq -r '.MemPerc | rtrimstr("%") | tonumber | floor' <<< "$line")
    cpu=$(jq -r '.CPUPerc | rtrimstr("%") | tonumber | floor' <<< "$line")
    limit=$(docker inspect "$name" --format '{{.HostConfig.Memory}}')
    if [ "$limit" != 0 ] && [ "$mem" -ge "$MEM_MAX" ]; then
      alert "mem-$name" "$name : mémoire à $mem % de sa limite ($(jq -r .MemUsage <<< "$line"))"
    else
      resolve "mem-$name"
    fi
    if [ "$cpu" -ge "$CPU_MAX" ]; then alert "cpu-$name" "$name : CPU à $cpu %"; else resolve "cpu-$name"; fi
  done < <(docker stats --no-stream --format json $(docker ps -q --filter "label=com.docker.compose.project=$PROJECT"))

  for pair in $EXPECTED; do
    svc=${pair%%:*} proc=${pair#*:}
    top=$(docker compose --project-directory "$TP04" -p "$PROJECT" top "$svc" 2> /dev/null)
    if grep -q "$proc" <<< "$top"; then
      resolve "proc-$svc"
    else
      alert "proc-$svc" "service $svc : aucun processus $proc (docker compose top)"
    fi
  done

  while IFS=' ' read -r name restarts oom health; do
    [ "$restarts" -gt 0 ] && alert "restart-$name-$restarts" "$name : $restarts redémarrage(s)"
    [ "$oom" = true ] && alert "oom-$name" "$name : OOMKilled=true"
    if [ "$health" = unhealthy ]; then alert "health-$name" "$name : unhealthy"; else resolve "health-$name"; fi
  done < <(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" | xargs docker inspect --format '{{.Name}} {{.RestartCount}} {{.State.OOMKilled}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' | sed 's#^/##')
}

echo "$(date +%H:%M:%S) surveillance du projet $PROJECT : mémoire >= $MEM_MAX % de la limite, CPU >= $CPU_MAX %, processus attendus, redémarrages, OOM, santé"
n=0
while :; do
  check
  n=$((n + 1))
  [ "$ROUNDS" -gt 0 ] && [ "$n" -ge "$ROUNDS" ] && break
  sleep "$INTERVAL"
done
rm -rf "$STATE"
