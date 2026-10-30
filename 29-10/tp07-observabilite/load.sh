#!/usr/bin/env bash
set -euo pipefail

N=${1:-1000}
CONCURRENCY=${CONCURRENCY:-20}
URL=${URL:-http://localhost}
HOST=${HOST_HEADER:-api.localhost}

hit() {
  local i=$1 r=$((RANDOM % 100))
  if [ "$r" -lt 70 ]; then
    curl -s -o /dev/null -w '%{http_code} GET /products\n' -H "Host: $HOST" "$URL/products"
  elif [ "$r" -lt 85 ]; then
    curl -s -o /dev/null -w '%{http_code} POST /orders\n' -H "Host: $HOST" -H 'Content-Type: application/json' \
      -d "{\"productId\":$((RANDOM % 3 + 1)),\"quantity\":$((RANDOM % 5 + 1))}" "$URL/orders"
  elif [ "$r" -lt 92 ]; then
    curl -s -o /dev/null -w '%{http_code} POST /orders (quantité > 100)\n' -H "Host: $HOST" -H 'Content-Type: application/json' \
      -d "{\"productId\":$((RANDOM % 3 + 1)),\"quantity\":$((RANDOM % 400 + 101))}" "$URL/orders"
  elif [ "$r" -lt 96 ]; then
    curl -s -o /dev/null -w '%{http_code} POST /orders (produit inconnu)\n' -H "Host: $HOST" -H 'Content-Type: application/json' \
      -d '{"productId":999,"quantity":1}' "$URL/orders"
  else
    curl -s -o /dev/null -w '%{http_code} GET /inconnu\n' -H "Host: $HOST" "$URL/inconnu-$i"
  fi
}
export -f hit
export URL HOST

start=$(date +%s)
seq "$N" | xargs -P "$CONCURRENCY" -I{} bash -c 'hit {}' | sort | uniq -c | sort -rn
echo "$N requêtes en $(( $(date +%s) - start )) s (concurrence $CONCURRENCY) vers $URL (Host: $HOST)"
