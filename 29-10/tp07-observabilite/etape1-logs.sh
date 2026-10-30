#!/usr/bin/env bash
set -uo pipefail

ALPINE=alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
API=${API:-shop-api-1}

run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; printf '[code retour %s]\n' "$?"; }
vm() { colima ssh -- sudo sh -c "$1"; }
logdir() { echo "/var/lib/docker/containers/$(docker inspect "$1" -f '{{.Id}}')"; }
size() { vm "du -cb $(logdir "$1")/*-json.log* $(logdir "$1")/local-logs/* 2>/dev/null | tail -1 | cut -f1"; }
cleanup() { docker rm -f tp07-nolimit tp07-limit tp07-local tp07-blocking tp07-nonblocking > /dev/null 2>&1; }
flood() { echo "yes 'ligne de log applicative de 64 octets pour remplir le disque.....' | head -n $1"; }

cleanup

echo "== Logs JSON structurés (pino)"
printf '\n$ docker logs --since 5m --timestamps %s | jq\n' "$API"
docker logs --since 5m --timestamps "$API" 2>&1 | tail -1 | cut -d' ' -f2- | jq -c '{level, time, msg, method: .req.method, url: .req.url, status: .res.statusCode, responseTime}'
run docker inspect "$API" --format '{{json .HostConfig.LogConfig}}'
run docker inspect "$API" --format '{{.LogPath}}'
printf '\n$ sudo ls -la %s/\n' "$(logdir "$API")"
vm "ls -la $(logdir "$API")/"
printf '\nformat brut d'"'"'une ligne du fichier json-file :\n'
vm "tail -1 $(logdir "$API")/*-json.log" | cut -c1-220

echo
echo "== Driver none"
run docker run --rm --log-driver none "$ALPINE" echo "pas loggé"
c=$(docker run -d --log-driver none "$ALPINE" echo "pas loggé")
sleep 1
run docker logs "$c"
docker rm "$c" > /dev/null

echo
echo "== Sans max-size : 2 000 000 lignes (130 Mo de texte) en quelques secondes"
docker run -d --name tp07-nolimit "$ALPINE" sh -c "$(flood 2000000)" > /dev/null
docker run -d --name tp07-limit --log-opt max-size=1m --log-opt max-file=3 "$ALPINE" sh -c "$(flood 2000000)" > /dev/null
docker run -d --name tp07-local --log-driver local --log-opt max-size=1m --log-opt max-file=3 "$ALPINE" sh -c "$(flood 2000000)" > /dev/null
docker wait tp07-nolimit tp07-limit tp07-local > /dev/null
for c in tp07-nolimit tp07-limit tp07-local; do
  printf '%-13s %-32s disque : %s octets\n' "$c" "$(docker inspect "$c" --format '{{.HostConfig.LogConfig.Type}} {{json .HostConfig.LogConfig.Config}}')" "$(size "$c")"
done
vm "ls -la $(logdir tp07-limit)/ | grep json.log"
vm "ls -la $(logdir tp07-local)/local-logs/"
echo "lignes encore lisibles par docker logs : nolimit=$(docker logs tp07-nolimit 2>&1 | wc -l | tr -d ' ') limit=$(docker logs tp07-limit 2>&1 | wc -l | tr -d ' ') local=$(docker logs tp07-local 2>&1 | wc -l | tr -d ' ')"

echo
echo "== Mode blocking vs non-blocking (max-buffer-size=4k), 300 000 lignes"
docker run -d --name tp07-blocking "$ALPINE" sh -c "$(flood 300000)" > /dev/null
docker run -d --name tp07-nonblocking --log-opt mode=non-blocking --log-opt max-buffer-size=4k "$ALPINE" sh -c "$(flood 300000)" > /dev/null
docker wait tp07-blocking tp07-nonblocking > /dev/null
for c in tp07-blocking tp07-nonblocking; do
  d=$(docker inspect "$c" --format '{{.State.StartedAt}} {{.State.FinishedAt}}')
  printf '%-17s lignes conservées : %6s / 300000   durée : %s\n' "$c" "$(docker logs "$c" 2>&1 | wc -l | tr -d ' ')" \
    "$(python3 -c "import sys,datetime as d;a,b=[d.datetime.fromisoformat(x[:26].rstrip('Z')) for x in sys.argv[1:]];print(f'{(b-a).total_seconds():.2f} s')" $d)"
done

cleanup
echo
echo "== conteneurs tp07-* supprimés"
