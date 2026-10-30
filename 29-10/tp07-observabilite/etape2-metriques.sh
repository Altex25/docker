#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

TP04=../tp04-compose-entreprise
LIMIT_FILE=$PWD/compose.api-64m.yml
DEV=(-f "$TP04/compose.yml" -f "$TP04/compose.override.yml")
BASE=(-f "$TP04/compose.yml")
TMP=$(mktemp -d)

run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; printf '[code retour %s]\n' "$?"; }
compose() { docker compose --project-directory "$TP04" "$@"; }
cg() { colima ssh -- sh -c "grep -E '^(max|oom_kill) ' /sys/fs/cgroup/docker/$(docker inspect shop-api-1 -f '{{.Id}}')/memory.events 2>/dev/null | paste -sd' ' - | grep . || echo 'cgroup absent (conteneur en cours de redémarrage)'"; }
state() { docker inspect shop-api-1 --format 'OOMKilled={{.State.OOMKilled}} RestartCount={{.RestartCount}} état={{.State.Status}} exit={{.State.ExitCode}} limite={{.HostConfig.Memory}}'; }

scenario() {
  local title=$1 limit=$2; shift 2
  sed "s/memory: .*/memory: $limit/" "$LIMIT_FILE" > "$TMP/limit.yml"
  echo
  echo "== $title"
  docker update --restart no shop-api-1 > /dev/null 2>&1
  docker stop -t 5 shop-api-1 > /dev/null 2>&1
  compose "$@" -f "$TMP/limit.yml" up -d --no-deps --wait --wait-timeout 60 api > /dev/null 2>&1
  echo "commande : $(docker inspect shop-api-1 --format '{{json .Config.Cmd}}')   au repos : $(docker stats --no-stream --format '{{.MemUsage}} ({{.MemPerc}})' shop-api-1)"
  docker events --filter container=shop-api-1 --filter event=oom --filter event=die --filter event=start \
    --format '{{.Time}} {{.Action}} exitCode={{index .Actor.Attributes "exitCode"}}' > "$TMP/events" &
  local ev=$!
  CONCURRENCY=200 ./load.sh 6000 | sed 's/^/  /'
  sleep 4
  kill "$ev" 2>/dev/null
  echo "pendant la charge (docker events) :"
  if [ -s "$TMP/events" ]; then
    sort "$TMP/events" | head -6 | while read -r t rest; do echo "  $(date -r "$t" +%H:%M:%S) $rest"; done
  else
    echo "  aucun événement oom/die/start"
  fi
  echo "état : $(state)"
  echo "cgroup memory.events : $(cg)"
  docker logs --since 1m shop-api-1 2>&1 | grep -vE '^\{' | tail -2 | sed 's/^/  stdout : /'
}

echo "== docker stats"
run docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}' $(docker ps -q --filter label=com.docker.compose.project=shop)

echo
echo "== docker system df -v (extrait)"
docker system df
docker system df -v 2>/dev/null > "$TMP/df"
grep -E '^shop_' "$TMP/df" | awk '{printf "volume %-16s liens=%s taille=%s\n", $1, $2, $3}'
docker ps -s --filter label=com.docker.compose.project=shop --format 'conteneur {{.Names}} couche RW={{.Size}}'

echo
echo "== docker events --filter type=container --since 10m (extrait)"
docker events --filter type=container --since 10m --until "$(date +%s)" --format '{{.Time}} {{.Actor.Attributes.name}} {{.Action}}' \
  | grep -vE 'exec_(create|start|die)' | tail -8 | while read -r t rest; do echo "$(date -r "$t" +%H:%M:%S) $rest"; done

scenario "A. dev (node --watch) limité à 64 Mo" 64M "${DEV[@]}"
scenario "B. dev (node --watch) limité à 40 Mo" 40M "${DEV[@]}"
scenario "C. image seule (node src/server.js en PID 1) limitée à 64 Mo" 64M "${BASE[@]}"
scenario "D. image seule limitée à 24 Mo" 24M "${BASE[@]}"
run docker inspect shop-api-1 --format '{{.State.OOMKilled}}'

echo
echo "== Retour à la configuration dev du TP04 (sans limite)"
docker update --restart no shop-api-1 > /dev/null 2>&1
docker stop -t 5 shop-api-1 > /dev/null 2>&1
compose "${DEV[@]}" up -d --no-deps --wait api > /dev/null 2>&1
echo "état : $(state)"
rm -f "$TMP/limit.yml" "$TMP/events" "$TMP/df" && rmdir "$TMP"
