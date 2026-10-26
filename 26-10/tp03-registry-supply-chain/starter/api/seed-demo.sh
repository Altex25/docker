#!/usr/bin/env bash
set -euo pipefail
REPO=${REPO:-registry.local:5000/demo}
BASE=alpine:3.20.10@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
day=86400
t0=$(date -d '2026-10-01' +%s 2>/dev/null || date -j -f %F 2026-10-01 +%s)

push() {
  local name=$1 days=$2; shift 2
  printf 'FROM %s\nLABEL build=%s\n' "$BASE" "$name" \
    | docker build -q --build-arg SOURCE_DATE_EPOCH=$((t0 + days * day)) -t "$REPO:$name" - >/dev/null
  docker push -q "$REPO:$name" >/dev/null
  for alias in "$@"; do docker tag "$REPO:$name" "$REPO:$alias"; docker push -q "$REPO:$alias" >/dev/null; done
  echo "$name ($(date -u -r $((t0 + days * day)) +%F 2>/dev/null || date -u -d @$((t0 + days * day)) +%F)) ${*:+-> aussi: $*}"
}

push 1.0.0 0
push 1.1.0 5
push 2.0.0 10 main-9a8b7c6
push main-0a1b2c3 11
push main-1b2c3d4 13 pr-42
push main-2c3d4e5 15
push main-3d4e5f6 17
push main-4e5f6a7 19
push main-5f6a7b8 21 latest
