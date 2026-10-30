#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

OUT=${OUT:-captures}
NAME=${1:-dashboard-sous-charge}
FROM=${FROM:-now-15m}
TO=${TO:-now}
CHROME=zenika/alpine-chrome:124@sha256:eb3378c1ed0079f94db054a5fe1aaa790a254ec0d6bbc67eda052420d86a179d
GRAFANA_AUTH=admin:${GRAFANA_ADMIN_PASSWORD:-admin}

mkdir -p "$OUT"
docker compose -f compose.observability.yml --profile captures up -d --wait renderer > /dev/null 2>&1

curl -s -u "$GRAFANA_AUTH" -o "$OUT/$NAME.png" -w "dashboard Grafana -> $OUT/$NAME.png (HTTP %{http_code}, %{size_download} octets)\n" \
  "http://localhost:3001/render/d/shop-overview/shop?orgId=1&from=$FROM&to=$TO&width=1800&height=2150&tz=Europe%2FParis&kiosk&timeout=${RENDER_TIMEOUT:-120}"

if [ "${ALERTS:-0}" = 1 ]; then
  docker run --rm --network observability_obs -v "$PWD/$OUT:/out" "$CHROME" \
    --no-sandbox --hide-scrollbars --window-size=1600,1250 --virtual-time-budget=10000 \
    --screenshot="/out/$NAME-prometheus-alerts.png" "http://prometheus:9090/alerts?search=" > /dev/null 2>&1
  echo "alertes Prometheus -> $OUT/$NAME-prometheus-alerts.png ($(wc -c < "$OUT/$NAME-prometheus-alerts.png" | tr -d ' ') octets)"
fi
