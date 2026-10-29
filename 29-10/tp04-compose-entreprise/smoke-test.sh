#!/usr/bin/env bash
set -euo pipefail

BASE_URL=${BASE_URL:-http://api.localhost}
COMPOSE=${COMPOSE:-docker compose}
TIMEOUT=${TIMEOUT:-15}
failures=0

ok() { printf '  OK     %s\n' "$*"; }
ko() { printf '  ÉCHEC  %s\n' "$*"; failures=$((failures + 1)); }
sql() { $COMPOSE exec -T db psql -U shop -d shop -tAc "$1"; }

wait_status() {
  local id=$1 expected=$2 status="" i
  for ((i = 0; i < TIMEOUT * 2; i++)); do
    status=$(sql "SELECT status FROM orders WHERE id = $id")
    [ "$status" = "$expected" ] && break
    sleep 0.5
  done
  echo "$status"
}

order() {
  local quantity=$1 expected=$2 before code id status
  before=$(sql "SELECT coalesce(max(id), 0) FROM orders")
  code=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d "{\"productId\":1,\"quantity\":$quantity}" "$BASE_URL/orders" || true)
  if [ "$code" != 201 ]; then ko "POST /orders (quantité $quantity) : HTTP $code"; return; fi
  id=$(sql "SELECT min(id) FROM orders WHERE id > $before")
  if [ -z "$id" ]; then ko "commande (quantité $quantity) absente de la base"; return; fi
  status=$(wait_status "$id" "$expected")
  if [ "$status" = "$expected" ]; then
    ok "commande $id (quantité $quantity) : pending -> $status par le worker"
  else
    ko "commande $id (quantité $quantity) : statut '$status' au lieu de '$expected' après ${TIMEOUT}s"
  fi
}

echo "== Smoke test : $BASE_URL"

ready=$(curl -sS -m 5 "$BASE_URL/ready" || true)
if [ "$(jq -r '"\(.status) \(.checks.db) \(.checks.redis)"' <<<"$ready" 2>/dev/null)" = "ready ok ok" ]; then
  ok "/ready : $ready"
else
  ko "/ready : ${ready:-pas de réponse}"
fi

curl -sS -m 5 -o /dev/null "$BASE_URL/products" || true
headers=$(curl -sS -m 5 -D - -o /dev/null "$BASE_URL/products" || true)
cache=$(tr -d '\r' <<<"$headers" | awk -F': ' 'tolower($1) == "x-cache" { print $2 }')
count=$(curl -sS -m 5 "$BASE_URL/products" | jq 'length' 2>/dev/null || echo 0)
if [ "$cache" = HIT ] && [ "$count" -gt 0 ]; then
  ok "/products : $count produits, X-Cache: HIT au second appel"
else
  ko "/products : X-Cache='${cache:-absent}', $count produits"
fi

order 2 confirmed
order 500 rejected

if [ "$failures" -gt 0 ]; then
  echo "== ÉCHEC : $failures vérification(s) en erreur"
  exit 1
fi
echo "== OK"
