#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

PANNE=${1:?usage : correlation.sh redis | db-password | memoire-api | latence-db}
DUREE=${DUREE:-120}

promq() { curl -s -G localhost:9090/api/v1/query --data-urlencode "query=$1" | jq -r '.data.result[] | "    \(.metric | del(.__name__) | to_entries | map("\(.key)=\(.value)") | join(","))  \(.value[1])"'; }
logq() { docker exec observability-grafana-1 wget -qO- "http://loki:3100/loki/api/v1/query_range?limit=$2&since=3m&query=$(jq -rn --arg q "$1" '$q|@uri')" | jq -r '.data.result[] | .stream.service as $s | .values[] | "    [\($s)] \(.[1] | .[0:200])"' | sort -u | head -"$2"; }
trafic() { local end=$((SECONDS + $1)); while [ $SECONDS -lt $end ]; do CONCURRENCY=3 ./load.sh 40 > /dev/null 2>&1; done; }

sleep 30
start=$(date +%s000)
echo "== $(date +%H:%M:%S) injection : $(./pannes.sh "$PANNE")"
if [ "$PANNE" = memoire-api ]; then
  CONCURRENCY=100 ./load.sh 3000 > /dev/null 2>&1
fi
trafic "$DUREE"
stop=$(date +%s000)

echo
echo "== Ce que montre Grafana ($(date +%H:%M:%S), $DUREE s après l'injection)"
echo "  alertes :"
curl -s localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | "    \(.state)  \(.labels.alertname)  \(.annotations.summary)"' | sort -u
echo "  cibles Prometheus en échec :"
promq 'up == 0'
echo "  réponses API par statut (req/s) :"
promq 'sum by (status) (rate(http_request_duration_seconds_count{job="api"}[1m]))'
echo "  réponses Traefik 5xx sur 2 min (Loki) :"
docker exec observability-grafana-1 wget -qO- "http://loki:3100/loki/api/v1/query?query=$(jq -rn --arg q 'sum by (status_class) (count_over_time({service="traefik", status_class!=""}[2m]))' '$q|@uri')" | jq -r '.data.result[] | "    \(.metric.status_class)  \(.value[1])"'
echo "  conteneurs du projet shop vus par cAdvisor dans les 30 dernières secondes :"
echo "    $(curl -s -G localhost:9090/api/v1/query --data-urlencode 'query=time() - max by (service) (container_last_seen{project="shop"}) < 30' | jq -r '[.data.result[].metric.service] | sort | join(", ")')"
echo "  mémoire de l'API (working set / limite) :"
api_id=$(docker inspect shop-api-1 --format '{{.Id}}')
echo "    working set $(curl -s -G localhost:9090/api/v1/query --data-urlencode "query=container_memory_working_set_bytes{id=\"/docker/$api_id\"} / 1048576" | jq -r '.data.result[0].value[1] // "absent" | .[0:6]') Mio, limite $(curl -s -G localhost:9090/api/v1/query --data-urlencode "query=container_spec_memory_limit_bytes{id=\"/docker/$api_id\"} / 1048576" | jq -r '.data.result[0].value[1] // "absent" | .[0:6]') Mio (0 = aucune)"
echo "  OOM kills sur 5 min :"
promq 'sum by (name) (increase(container_oom_events_total{project="shop"}[5m])) > 0'
echo "  logs applicatifs en erreur (JSON, severity=error|fatal) :"
logq '{project="shop", severity=~"error|fatal"} | json | line_format "{{.msg}} {{.err_message}}"' 3
echo "  sorties non JSON des applications (severity=unknown : stderr brut, crash) :"
logq '{project="shop", service=~"api|worker", severity="unknown"}' 3
echo "  logs PostgreSQL / Redis en erreur :"
logq '{project="shop", service=~"db|redis"} |~ "ERROR|FATAL"' 3

FROM=$((start - 300000)) TO=$stop ./captures.sh "correlation-$PANNE" | sed 's/^/  /'

echo
echo "== Vérification avec docker"
case $PANNE in
  redis)
    docker ps -a --filter name=shop-redis-1 --format '  {{.Names}} {{.Status}}'
    docker inspect shop-redis-1 --format '  arrêté à {{.State.FinishedAt}}, code {{.State.ExitCode}}, politique {{.HostConfig.RestartPolicy.Name}} (un docker stop n est pas relancé)'
    ;;
  db-password)
    docker logs --since 3m shop-db-1 2>&1 | grep -m2 'password authentication failed' | sed 's/^/  /'
    ;;
  memoire-api)
    docker inspect shop-api-1 --format '  OOMKilled={{.State.OOMKilled}} état={{.State.Status}} RestartCount={{.RestartCount}} limite={{.HostConfig.Memory}}'
    docker top shop-api-1 -o pid,rss,args | sed 's/^/  /'
    docker logs --since 5m shop-api-1 2>&1 | grep -v '^{' | tail -2 | sed 's/^/  /'
    ;;
  latence-db)
    docker run --rm --network container:shop-db-1 nicolaka/netshoot:v0.14@sha256:7f08c4aff13ff61a35d30e30c5c1ea8396eac6ab4ce19fd02d5a4b3b5d0d09a2 tc qdisc show | grep netem | sed 's/^/  /'
    for i in 1 2 3; do
      docker exec shop-api-1 node -e "const t = Date.now(); require('net').connect(5432, 'db').on('connect', function () { console.log('  connexion TCP api -> db : ' + (Date.now() - t) + ' ms'); this.destroy(); })"
    done
    ;;
esac

echo
echo "== $(date +%H:%M:%S) $(./pannes.sh restore | head -1)"
