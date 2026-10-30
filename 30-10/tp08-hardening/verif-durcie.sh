#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

TP04=../../29-10/tp04-compose-entreprise
COMPOSE=(docker compose --project-directory "$TP04" -f "$TP04/compose.yml" -f "$PWD/compose.hardened.yml" --profile tools)
CURL=curlimages/curl:8.10.1@sha256:d9b4541e214bcd85196d6e92e2753ac6d0ea699f0af5741f8c6cccbfcf00ef4b

echo "== Effet réel dans chaque conteneur (lu dans /proc et le cgroup, pas dans la config)"
printf '%-12s %-24s %-18s %-12s %-14s %-10s %s\n' service "uid/gid (id)" CapEff NoNewPrivs "écriture /" memory.max pids.max
for svc in socket-proxy traefik db redis api worker adminer; do
  c=$("${COMPOSE[@]}" ps -q "$svc")
  r=$(docker exec "$c" sh -c '
    ids="$(id -u):$(id -g)"
    cap=$(grep CapEff /proc/self/status | cut -f2)
    nnp=$(grep NoNewPrivs /proc/self/status | cut -f2)
    if touch /probe-tp08 2> /dev/null; then w=possible; else w=refusée; fi
    mem=$(cat /sys/fs/cgroup/memory.max)
    pids=$(cat /sys/fs/cgroup/pids.max)
    echo "$ids|$cap|$nnp|$w|$mem|$pids"' 2>&1)
  IFS='|' read -r ids cap nnp w mem pids <<< "$r"
  printf '%-12s %-24s %-18s %-12s %-14s %-10s %s\n' "$svc" "$ids" "$cap" "$nnp" "$w" "$mem" "$pids"
done

echo
echo "== La socket Docker n'est plus dans Traefik"
docker exec "$("${COMPOSE[@]}" ps -q traefik)" sh -c 'ls -l /var/run/docker.sock 2>&1; echo "endpoint : $TRAEFIK_PROVIDERS_DOCKER_ENDPOINT"'

echo
echo "== Ce que le proxy laisse passer (depuis le réseau socket, comme Traefik)"
net=$(docker inspect "$("${COMPOSE[@]}" ps -q socket-proxy)" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')
for req in "GET /version" "GET /containers/json" "GET /events?since=0&until=1" "GET /images/json" "GET /info" "GET /secrets" "POST /containers/create" "DELETE /containers/shop-api-1" "POST /containers/shop-api-1/exec"; do
  m=${req%% *}; p=${req#* }
  printf '  %-6s %-30s -> %s\n' "$m" "$p" "$(docker run --rm --network "$net" "$CURL" -s -o /dev/null -w '%{http_code}' -X "$m" "http://socket-proxy:2375/v1.47$p")"
done
echo "réseau $net : internal=$(docker network inspect "$net" --format '{{.Internal}}'), membres : $(docker network inspect "$net" --format '{{range .Containers}}{{.Name}} {{end}}')"
echo "l'API peut-elle joindre le proxy ? $(docker exec "$("${COMPOSE[@]}" ps -q api)" node -e "require('net').connect(2375, 'socket-proxy').on('connect', () => { console.log('oui'); process.exit(0) }).on('error', e => { console.log('non (' + e.code + ')'); process.exit(0) })")"
