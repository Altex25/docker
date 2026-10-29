#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; printf '[code retour %s]\n' "$?"; }
products() { curl -s -m8 -o /dev/null -D - http://localhost:8081/products | grep -iE '^HTTP|x-cache' | tr -d '\r' | paste -sd' ' -; }

echo "== Départ à zéro (projet incident uniquement)"
docker compose down -v --remove-orphans > /dev/null 2>&1
start=$(date +%s)
run docker compose up -d --wait
echo "stack saine en $(( $(date +%s) - start )) s"
run docker compose ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'

echo
echo "== Objectif : catalogue puis X-Cache: HIT"
for i in 1 2; do echo "appel $i : $(products)"; done
run curl -s http://localhost:8081/products
run curl -s http://localhost:8081/ready

echo
echo "== Changement d'IP de l'API : nginx re-résout api via 127.0.0.11 (valid=10s)"
ips() { docker compose ps -q api | xargs docker inspect --format '{{.NetworkSettings.Networks.incident_public.IPAddress}}' | sort | paste -sd' ' -; }
before=$(ips)
docker compose stop api > /dev/null 2>&1
docker run -d --rm --name tp06-ipthief --network incident_public alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc sleep 120 > /dev/null
docker run -d --rm --name tp06-ipthief2 --network incident_public alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc sleep 120 > /dev/null
docker compose up -d --no-deps --wait api > /dev/null 2>&1
after=$(ips)
echo "IP api avant : $before / après : $after (anciennes IP prises par tp06-ipthief*)"
sleep 11
for i in 1 2 3; do echo "appel $i : $(products)"; done
docker rm -f tp06-ipthief tp06-ipthief2 > /dev/null 2>&1

echo
echo "== Répartition sur les 2 réplicas"
run docker compose exec front nslookup api 127.0.0.11
count() { for c in $(docker compose ps -q api); do docker logs "$c" 2>&1 | grep -c '"url":"/products"'; done | paste -sd' ' -; }
c0=$(count)
for i in $(seq 20); do curl -s -o /dev/null http://localhost:8081/products; done
echo "requêtes /products par réplica avant : $c0 / après 20 appels : $(count)"

echo
echo "== Politique de redémarrage : crash simulé (kill -9 du processus node depuis la VM)"
victim=$(docker compose ps -q api | head -1)
pid=$(docker inspect "$victim" --format '{{.State.Pid}}')
printf '\n$ colima ssh -- sudo kill -9 %s\n' "$pid"
colima ssh -- sudo kill -9 "$pid"
echo "pendant le redémarrage : $(products)"
sleep 6
run docker inspect "$victim" --format '{{.Name}} restart={{.HostConfig.RestartPolicy.Name}} RestartCount={{.RestartCount}} état={{.State.Status}} santé={{.State.Health.Status}}'

echo
echo "== Isolation réseau"
run docker network inspect incident_backend --format 'internal={{.Internal}} membres={{range .Containers}}{{.Name}} {{end}}'
run docker network inspect incident_public --format 'internal={{.Internal}} membres={{range .Containers}}{{.Name}} {{end}}'
run docker compose exec front getent hosts db
run docker compose exec db sh -c 'wget -q -T3 -O /dev/null http://example.com'
run docker compose exec api sh -c 'nc -z -w2 db 5432 && echo api joint db:5432'
printf '\n$ colima ssh -- ss -tln | grep 6379\n'
colima ssh -- sh -c 'ss -tln | grep 6379 || echo "aucun port 6379 ouvert sur la VM"'

echo
echo "== Secrets"
run docker top "$(docker compose ps -q redis)" -o pid,args
run docker compose exec redis redis-cli ping
run docker compose exec redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping'
run git -C .. check-ignore -v tp06-reseau-debug/.env

echo
echo "== Healthchecks"
for c in $(docker compose ps -q); do docker inspect "$c" --format '{{.Name}} {{.State.Health.Status}} {{json .Config.Healthcheck.Test}}'; done
