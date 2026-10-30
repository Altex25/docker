#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."

TP04=../tp04-compose-entreprise
OBS=(-f compose.observability.yml -f bonus/compose.b3-jaeger.yml)
SHOP=(--project-directory "$TP04" -f "$TP04/compose.yml" -f "$TP04/compose.override.yml")
OTEL=("${SHOP[@]}" -f "$PWD/bonus/compose.b3-otel.yml")
CHROME=zenika/alpine-chrome:124@sha256:eb3378c1ed0079f94db054a5fe1aaa790a254ec0d6bbc67eda052420d86a179d

run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; printf '[code retour %s]\n' "$?"; }

echo "== Jaeger (OTLP 4317/4318, UI 16686) dans le projet observability"
docker compose "${OBS[@]}" up -d jaeger 2>&1 | tail -1
for _ in $(seq 30); do curl -s -o /dev/null localhost:16686/ && break; sleep 1; done

echo
echo "== API instrumentée sans toucher au code ni à l'image"
docker compose "${OTEL[@]}" up -d --no-deps otel-sdk > /dev/null 2>&1
docker wait "$(docker compose "${OTEL[@]}" ps -aq otel-sdk)" > /dev/null
docker compose "${OTEL[@]}" logs --no-log-prefix otel-sdk 2>&1 | tail -2 | sed 's/^/  npm : /'
docker update --restart no shop-api-1 > /dev/null 2>&1
docker stop -t 5 shop-api-1 > /dev/null 2>&1
docker compose "${OTEL[@]}" up -d --no-deps --wait api 2>&1 | tail -1
run docker inspect shop-api-1 --format '{{.Config.Image}}'
docker exec shop-api-1 printenv | grep -E '^(NODE_OPTIONS|OTEL_)' | sort | sed 's/^/  /'

echo
echo "== Trafic"
./load.sh 200 | sed 's/^/  /'
sleep 8

echo
echo "== Traces reçues par Jaeger"
echo "  services : $(curl -s localhost:16686/api/services | jq -r '.data | join(", ")')"
echo "  opérations shopapi : $(curl -s 'localhost:16686/api/services/shopapi/operations' | jq -r '[.data[] | if type == "object" then .name else . end] | sort | join(" | ")' | cut -c1-400)"
traces=$(curl -s 'localhost:16686/api/traces?service=shopapi&operation=POST%20%2Forders&limit=100&lookback=1h')
pick() { jq -c --argjson code "$1" '[.data[] | select(any(.spans[]; .operationName == "POST /orders" and any(.tags[]; .key == "http.response.status_code" and .value == $code)))][0]' <<< "$traces"; }
trace=$(pick 201)
tid=$(jq -r .traceID <<< "$trace")
echo "  trace POST /orders (201) $tid :"
jq -r '.processes as $p | .spans | sort_by(.startTime, -.duration) | .[] | "    \(.operationName)  \(.duration / 1000 | floor) ms  [\($p[.processID].serviceName)]" + (if any(.tags[]; .key == "error" and .value == true) then "  ERREUR" else "" end)' <<< "$trace"
err=$(pick 500)
echo
echo "  trace POST /orders en erreur 500 $(jq -r .traceID <<< "$err") :"
jq -r '.spans | sort_by(.startTime, -.duration) | .[] | select(.operationName | test("middleware") | not) | select(any(.tags[]; .key == "error" and .value == true) or (.operationName | test("pg.query|POST"))) | "    \(.operationName)  \(.duration / 1000 | floor) ms" + ([.tags[] | select(.key | test("status_code|otel.status_description|db.statement|db.query.text")) | "  \(.key)=\(.value)"] | join(""))' <<< "$err"
echo
echo "  corrélation logs ↔ traces : le log pino de cette requête contient trace_id :"
docker logs --since 2m shop-api-1 2>&1 | grep -m1 "\"trace_id\":\"$tid\"" | jq -c '{level, msg, trace_id, span_id, url: .req.url, status: .res.statusCode}' | sed 's/^/    /'

echo
echo "== Capture de la trace dans l'UI Jaeger"
mkdir -p captures
docker run --rm --network observability_obs -v "$PWD/captures:/out" "$CHROME" \
  --no-sandbox --hide-scrollbars --window-size=1600,900 --virtual-time-budget=15000 \
  --screenshot=/out/b3-trace-jaeger.png "http://jaeger:16686/trace/$tid" > /dev/null 2>&1
echo "  captures/b3-trace-jaeger.png ($(wc -c < captures/b3-trace-jaeger.png | tr -d ' ') octets)"

if [ "${KEEP:-0}" != 1 ]; then
  echo
  echo "== Retour à l'API sans instrumentation"
  docker update --restart no shop-api-1 > /dev/null 2>&1
  docker stop -t 5 shop-api-1 > /dev/null 2>&1
  docker compose "${SHOP[@]}" up -d --no-deps --wait api 2>&1 | tail -1
  docker compose "${OTEL[@]}" rm -f otel-sdk > /dev/null 2>&1
  docker compose "${OBS[@]}" rm -sf jaeger > /dev/null 2>&1
  echo "  NODE_OPTIONS=$(docker exec shop-api-1 printenv NODE_OPTIONS)"
fi
