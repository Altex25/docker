#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."

BASE=(-f compose.yml)
ICC=(-f compose.yml -f bonus/compose.b3-icc.yml)

run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; printf '[code retour %s]\n' "$?"; }
timed() { curl -s -m 40 -o /dev/null -w "HTTP %{http_code} en %{time_total}s" "$1"; }

echo "== 1. backend avec enable_icc=false (réseau recréé, donc --force-recreate)"
docker compose "${ICC[@]}" up -d --force-recreate --wait > /dev/null 2>&1
echo "état : $(docker compose "${BASE[@]}" ps --format '{{.Service}}={{.Health}}' | sort -u | paste -sd' ' -)"
run docker network inspect incident_backend --format 'internal={{.Internal}} options={{json .Options}}'

echo
echo "== 2. effets"
run docker compose exec -T api getent hosts db
run docker compose exec -T api sh -c 'nc -z -w3 db 5432 && echo db:5432 joignable'
run docker compose exec -T api sh -c 'nc -z -w3 redis 6379 && echo redis:6379 joignable'
run docker compose exec -T front wget -q -T3 -O- http://api:3000/health
echo
echo "/health via le port publié : $(timed http://localhost:8081/health)"
echo "/ready via le port publié  : $(timed http://localhost:8081/ready)"
echo "/products                  : $(timed http://localhost:8081/products)"
printf '\n$ docker compose logs front | grep upstream\n'
docker compose "${BASE[@]}" logs --no-log-prefix --since 2m front 2>&1 | grep -E 'upstream timed out' | sed -E 's/, client.*upstream: / upstream: /; s/, host.*//' | head -2

echo
echo "== 3. règle posée par Docker dans la VM"
br=br-$(docker network inspect incident_backend --format '{{.Id}}' | cut -c1-12)
printf '\n$ colima ssh -- sudo iptables -S DOCKER-FORWARD | grep %s\n' "$br"
colima ssh -- sudo iptables -S DOCKER-FORWARD 2>/dev/null | grep "$br" || colima ssh -- sudo iptables -S FORWARD | grep "$br"
printf '\n$ colima ssh -- sudo nft list ruleset | grep %s\n' "$br"
colima ssh -- sudo nft list ruleset 2>/dev/null | grep "$br" | head -6

echo
echo "== 4. retour à la configuration nominale"
docker compose "${BASE[@]}" up -d --force-recreate --wait > /dev/null 2>&1
echo "état : $(docker compose "${BASE[@]}" ps --format '{{.Service}}={{.Health}}' | sort -u | paste -sd' ' -)"
echo "options backend : $(docker network inspect incident_backend --format '{{json .Options}}')"
echo "/ready : $(curl -s http://localhost:8081/ready)"
