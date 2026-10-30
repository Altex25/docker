#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

TP04=../tp04-compose-entreprise
OBS=(-f compose.observability.yml)
PROM=prom/prometheus:v2.54.1@sha256:f6639335d34a77d9d9db382b92eeb7fc00934be8eae81dbc03b31cfe90411a94
GRAFANA_AUTH=admin:${GRAFANA_ADMIN_PASSWORD:-admin}

run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; printf '[code retour %s]\n' "$?"; }
targets() { curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | "  \(.labels.job)\t\(.labels.instance)\t\(.health)\t\(.lastError)"' | sort; }
promq() { curl -s -G localhost:9090/api/v1/query --data-urlencode "query=$1" | jq -r '.data.result[] | "  \(.metric | del(.__name__) | to_entries | map("\(.key)=\(.value)") | join(","))  \(.value[1])"'; }
logq() { docker exec observability-grafana-1 wget -qO- "http://loki:3100/loki/api/v1/query_range?limit=$2&since=10m&query=$(jq -rn --arg q "$1" '$q|@uri')"; }
compose04() { docker compose --project-directory "$TP04" "$@"; }

echo "== Stack d'observabilité"
docker compose "${OBS[@]}" ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'

echo
echo "== Cibles Prometheus"
targets

echo
echo "== Découverte DNS : passage de l'API à 2 réplicas (configuration de base, sans port publié)"
compose04 -f "$TP04/compose.yml" up -d --no-deps --wait --scale api=2 api > /dev/null 2>&1
sleep 5
printf '\n$ docker exec observability-prometheus-1 nslookup -type=a api\n'
docker exec observability-prometheus-1 nslookup -type=a api 2>&1 | grep -E '^(Name|Address: )' | paste -sd' ' -
for _ in $(seq 30); do
  [ "$(curl -s localhost:8080/api/http/services/api@docker | jq '[.serverStatus[] | select(. == "UP")] | length')" = 2 ] && break
  sleep 1
done
echo "Traefik : $(curl -s localhost:8080/api/http/services/api@docker | jq -c .serverStatus)"
sleep 20
targets | grep -E '^  api'
count='sum by (instance) (http_request_duration_seconds_count{job="api", route="/products"})'
echo "compteur /products par réplica (Prometheus) avant 200 appels :"
promq "$count"
./load.sh 200 > /dev/null
sleep 25
echo "après :"
promq "$count"
compose04 -f "$TP04/compose.yml" -f "$TP04/compose.override.yml" up -d --no-deps --wait api > /dev/null 2>&1
echo "retour à 1 réplica (configuration dev) : $(docker compose --project-directory "$TP04" -f "$TP04/compose.yml" -f "$TP04/compose.override.yml" ps -q api | wc -l | tr -d ' ')"

echo
echo "== Pourquoi pas docker_sd_configs dans Prometheus ?"
run docker exec observability-prometheus-1 id
printf '\n$ colima ssh -- ls -l /var/run/docker.sock\n'
colima ssh -- ls -l /var/run/docker.sock
cat > "$PWD/.docker-sd.yml" <<'EOF'
scrape_configs:
  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
EOF
docker rm -f tp07-prom-dockersd > /dev/null 2>&1
docker run -d --name tp07-prom-dockersd -v "$PWD/.docker-sd.yml":/etc/prometheus/prometheus.yml:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro "$PROM" > /dev/null
sleep 8
echo "Prometheus (nobody) avec la socket montée :"
docker logs tp07-prom-dockersd 2>&1 | grep -m1 -iE 'permission denied|docker' | sed -E 's/.*(msg=.*)/  \1/' | cut -c1-260
docker rm -f tp07-prom-dockersd > /dev/null
rm -f "$PWD/.docker-sd.yml"

echo
echo "== Labels de Loki (Promtail docker_sd_configs)"
for l in project service severity level status_class; do
  echo "  $l : $(docker exec observability-grafana-1 wget -qO- "http://loki:3100/loki/api/v1/label/$l/values" | jq -r '.data | join(", ")')"
done

echo
echo "== Requêtes du sujet"
./load.sh 300 > /dev/null
sleep 20
echo '{service="api"} | json | level="50"'
logq '{service="api"} | json | level="50"' 3 | jq -r '.data.result[].values[][1] | fromjson | "  level=\(.level) \(.msg) : \(.err.message // "")"' | head -3
echo '{service="worker"} |= "rejected"'
logq '{service="worker"} |= "rejected"' 3 | jq -r '.data.result[].values[][1]' | head -3 | sed 's/^/  /'
echo 'sum(rate(http_request_duration_seconds_count[1m])) by (status)'
promq 'sum(rate(http_request_duration_seconds_count[1m])) by (status)'

echo
echo "== Grafana provisionné par fichiers"
echo "datasources : $(curl -s -u "$GRAFANA_AUTH" localhost:3001/api/datasources | jq -r 'map("\(.name) (\(.type), uid=\(.uid), readOnly=\(.readOnly))") | join(" ; ")')"
for uid in prometheus loki; do
  echo "  santé $uid : $(curl -s -u "$GRAFANA_AUTH" "localhost:3001/api/datasources/uid/$uid/health" | jq -r '.status + " - " + .message')"
done
echo "dashboards : $(curl -s -u "$GRAFANA_AUTH" 'localhost:3001/api/search?type=dash-db' | jq -r 'map("\(.title) (uid=\(.uid), dossier=\(.folderTitle))") | join(" ; ")')"
echo "provisionné : $(curl -s -u "$GRAFANA_AUTH" localhost:3001/api/dashboards/uid/shop-overview | jq -r '"provisioned=\(.meta.provisioned) fichier=\(.meta.provisionedExternalId) panneaux=\(.dashboard.panels | length)"')"
echo "via Traefik : $(curl -s -o /dev/null -w '%{http_code}' -H 'Host: grafana.localhost' localhost/api/health)"

echo
echo "== Règles d'alerte chargées"
curl -s localhost:9090/api/v1/rules | jq -r '.data.groups[] | .name as $g | .rules[] | "  \($g)\t\(.type)\t\(.name)\t\(.health)\t\(.state // "-")"'
