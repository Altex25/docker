#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."

BASE=(-f compose.yml)
ALIAS=(-f compose.yml -f bonus/compose.b2-alias.yml --profile bascule)
SWITCH=("${ALIAS[@]}" -f bonus/compose.b2-bascule.yml)

ip() { docker inspect "incident-$1-1" --format '{{.NetworkSettings.Networks.incident_backend.IPAddress}}'; }
resolve() { docker exec incident-api-1 getent hosts database | awk '{print $1}' | paste -sd' ' -; }
apis() { docker compose "${BASE[@]}" ps -q api | cut -c1-12 | paste -sd' ' -; }
catalogue() {
  docker compose "${BASE[@]}" exec -T redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli del products' > /dev/null
  curl -s http://localhost:8081/products | jq -r 'map(.name) | join(", ")'
}

echo "== 1. alias database sur db, l'API pointe sur database"
docker compose "${ALIAS[@]}" up -d --wait db api front > /dev/null 2>&1
echo "DATABASE_URL de l'API : $(docker exec incident-api-1 printenv DATABASE_URL | sed 's#//shop:[^@]*@#//shop:***@#')"
echo "DNSNames de db        : $(docker inspect incident-db-1 --format '{{json .NetworkSettings.Networks.incident_backend.DNSNames}}')"
echo "database -> $(resolve)   (db = $(ip db))"
echo "catalogue : $(catalogue)"

echo
echo "== 2. nouvelle base db-next préparée à côté (sans alias)"
docker compose "${ALIAS[@]}" up -d --wait db-next > /dev/null 2>&1
docker exec incident-db-next-1 psql -U shop -d shop -qc "UPDATE products SET name = name || ' [db-next]'"
echo "db-next = $(ip db-next), database -> $(resolve)"
echo "catalogue : $(catalogue)"

echo
echo "== 3. bascule : l'alias database passe de db à db-next (aucune modification de l'API)"
api_before=$(apis)
url_before=$(docker exec incident-api-1 printenv DATABASE_URL)
start=$(date +%s)
docker compose "${SWITCH[@]}" up -d --wait db db-next 2>&1 | grep -E 'Recreate|Restart' | sort -u
echo "bascule en $(( $(date +%s) - start )) s"
echo "conteneurs api avant : $api_before / après : $(apis)"
[ "$url_before" = "$(docker exec incident-api-1 printenv DATABASE_URL)" ] && echo "DATABASE_URL inchangée"
echo "DNSNames db      : $(docker inspect incident-db-1 --format '{{json .NetworkSettings.Networks.incident_backend.DNSNames}}')"
echo "DNSNames db-next : $(docker inspect incident-db-next-1 --format '{{json .NetworkSettings.Networks.incident_backend.DNSNames}}')"
echo "database -> $(resolve)   (db-next = $(ip db-next))"
echo "catalogue : $(catalogue)"
curl -s http://localhost:8081/ready; echo

echo
echo "== 4. retour à la configuration nominale"
docker compose "${BASE[@]}" up -d --wait --remove-orphans > /dev/null 2>&1
docker volume rm incident_pgdata-next > /dev/null
echo "conteneurs : $(docker compose "${BASE[@]}" ps --format '{{.Name}}={{.Health}}' | paste -sd' ' -)"
echo "catalogue : $(catalogue)"
