#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."

OBS=(-f compose.observability.yml -f bonus/compose.b1-fluentbit.yml)
ALPINE=alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
DRIVER=(--log-driver fluentd --log-opt fluentd-address=127.0.0.1:24224 --log-opt tag=docker.{{.Name}}
  --log-opt labels=com.docker.compose.service,com.docker.compose.project
  --label com.docker.compose.service=b1-demo --label com.docker.compose.project=tp07)
DEMO='for i in 1 2 3 4 5; do echo "{\"level\":\"INFO\",\"msg\":\"ligne $i envoyée par le driver fluentd\"}"; done; echo "{\"level\":\"ERROR\",\"msg\":\"erreur de démonstration\"}" >&2'

run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; printf '[code retour %s]\n' "$?"; }
logq() { docker exec observability-grafana-1 wget -qO- "http://loki:3100/loki/api/v1/query_range?limit=10&since=5m&query=$(jq -rn --arg q "$1" '$q|@uri')"; }
cleanup() { docker rm -f tp07-b1-demo tp07-b1-async > /dev/null 2>&1; }

cleanup
echo "== fluent-bit (input forward :24224 -> Loki)"
docker compose "${OBS[@]}" up -d --wait fluent-bit 2>&1 | tail -1

echo
echo "== Conteneur avec --log-driver fluentd"
docker run -d --name tp07-b1-demo "${DRIVER[@]}" "$ALPINE" sh -c "$DEMO; sleep 600" > /dev/null
sleep 6
run docker inspect tp07-b1-demo --format '{{json .HostConfig.LogConfig}}'
echo
echo "docker logs fonctionne encore grâce au cache local (dual logging, Docker >= 20.10) :"
docker logs tp07-b1-demo 2>&1 | sed 's/^/  /'
echo
echo "dans Loki, {job=\"fluent-bit\", container_name=\"/tp07-b1-demo\"} :"
logq '{job="fluent-bit", container_name="/tp07-b1-demo"}' | jq -r '.data.result[] | "  labels=\(.stream | del(.job) | tojson)\n" + (.values | map("    " + .[1]) | join("\n"))'

echo
echo "== Panne du collecteur : fluent-bit arrêté"
docker compose "${OBS[@]}" stop fluent-bit 2>&1 | tail -1
run docker run --rm "${DRIVER[@]}" "$ALPINE" echo "démarrage impossible ?"
echo
echo "avec fluentd-async=true, le conteneur démarre et le driver bufferise en mémoire :"
docker run -d --name tp07-b1-async "${DRIVER[@]}" --log-opt fluentd-async=true "$ALPINE" sh -c 'echo "écrit pendant la panne du collecteur"; sleep 600' > /dev/null
sleep 2
docker inspect tp07-b1-async --format '  état={{.State.Status}}'
docker compose "${OBS[@]}" start fluent-bit 2>&1 | tail -1
sleep 12
echo "  dans Loki après redémarrage du collecteur : $(logq '{job="fluent-bit", container_name="/tp07-b1-async"}' | jq -r '[.data.result[].values[][1]] | join(" | ")')"

echo
echo "== Comparaison avec Promtail : la même ligne est-elle aussi dans Loki via Promtail ?"
echo "  {container=\"tp07-b1-demo\"} (Promtail lit /containers/{id}/logs via la socket) : $(logq '{container="tp07-b1-demo"}' | jq -r '.data.result | length') flux"

cleanup
docker compose "${OBS[@]}" rm -sf fluent-bit > /dev/null 2>&1
echo
echo "== conteneurs tp07-b1-* et fluent-bit supprimés"
