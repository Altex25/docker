#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."

OBS=(-f compose.observability.yml)

webhooks() { docker logs --since "$1" observability-webhook-echo-1 2>/dev/null | grep -v "^::" | jq -c 'select(.path == "/alertmanager") | .body | fromjson | {status, groupLabels, alertes: [.alerts[] | "\(.labels.alertname) \(.labels.name // .labels.instance // "") \(.status)"]}' 2>/dev/null; }

echo "== Alertmanager et webhook d'écho"
docker compose "${OBS[@]}" up -d --wait alertmanager webhook-echo prometheus 2>&1 | tail -1
curl -s -X POST localhost:9090/-/reload
for _ in $(seq 20); do [ "$(curl -s localhost:9090/api/v1/alertmanagers | jq '.data.activeAlertmanagers | length')" -gt 0 ] && break; sleep 2; done
echo "  Prometheus -> Alertmanager : $(curl -s localhost:9090/api/v1/alertmanagers | jq -r '[.data.activeAlertmanagers[].url] | join(", ")')"
echo "  route : $(curl -s localhost:9093/api/v2/status | jq -r '.config.original' | grep -A3 '^route:' | tr -s ' \n' ' ')"

since=$(date +%s)
echo
echo "== $(date +%H:%M:%S) panne : arrêt du worker (scrape en échec, pas de restart policy pour un stop)"
docker stop shop-worker-1 > /dev/null
for _ in $(seq 40); do
  [ -n "$(webhooks "$since" | grep WorkerDown | grep firing)" ] && break
  sleep 5
done
echo "  alerte : $(curl -s localhost:9093/api/v2/alerts | jq -r '[.[] | "\(.labels.alertname) \(.status.state)"] | join(", ")')"
echo "  notifications reçues par le webhook :"
webhooks "$since" | sed 's/^/    /'

echo
echo "== $(date +%H:%M:%S) résolution : redémarrage du worker"
docker start shop-worker-1 > /dev/null
for _ in $(seq 40); do
  [ -n "$(webhooks "$since" | grep WorkerDown | grep resolved)" ] && break
  sleep 5
done
echo "  notifications reçues par le webhook :"
webhooks "$since" | sed 's/^/    /'

echo
echo "== Exemple de charge utile complète (premier envoi firing)"
docker logs --since "$since" observability-webhook-echo-1 2>/dev/null | grep -v "^::" | jq -s '[.[] | select(.path == "/alertmanager") | .body | fromjson | select(.groupLabels.alertname == "WorkerDown")][0] | {receiver, status, groupLabels, externalURL, alerts: [.alerts[0] | {status, labels: (.labels | {alertname, severity, job, instance, service, project}), annotations, startsAt, generatorURL}]}'
