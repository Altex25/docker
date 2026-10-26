#!/usr/bin/env bash
# Bonus B3 : deux builds --no-cache successifs donnent-ils le même digest ?
# --no-cache est indispensable : avec le cache, on mesurerait le cache et non la reproductibilité.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILDER=${BUILDER:-tp01-bonus}
SDE=$(git log -1 --format=%ct)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

COMMON=(--builder "$BUILDER" --no-cache --provenance=false --sbom=false
        --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=31ffc07)

digest() {
  local name=$1 output=$2; shift 2
  docker buildx build "${COMMON[@]}" "$@" --output "type=oci,dest=$OUT/$name.tar$output" . >/dev/null 2>&1
  tar -xOf "$OUT/$name.tar" index.json | jq -r '.manifests[0].digest'
}

details() {
  local tar=$OUT/$1.tar m cfg
  m=$(tar -xOf "$tar" index.json | jq -r '.manifests[0].digest' | cut -d: -f2)
  cfg=$(tar -xOf "$tar" "blobs/sha256/$m" | jq -r '.config.digest' | cut -d: -f2)
  local src="" npm="" l listing
  for l in $(tar -xOf "$tar" "blobs/sha256/$m" | jq -r '.layers[].digest' | cut -d: -f2); do
    listing=$(tar -xOf "$tar" "blobs/sha256/$l" | tar -tvzf - 2>/dev/null)
    [ -z "$src" ] && src=$(awk '$NF == "app/src/server.js" {print $6, $7, $8}' <<<"$listing")
    [ -z "$npm" ] && npm=$(awk '$NF == "app/node_modules/express/package.json" {print $6, $7, $8}' <<<"$listing")
  done
  printf '      created=%s | mtime src/server.js=%s | mtime node_modules/express/package.json=%s\n' \
    "$(tar -xOf "$tar" "blobs/sha256/$cfg" | jq -r .created)" "$src" "$npm"
}

scenario() {
  local label=$1 output=$2; shift 2
  local a b
  a=$(digest "${label// /_}-1" "$output" "$@")
  b=$(digest "${label// /_}-2" "$output" "$@")
  if [ "$a" = "$b" ]; then verdict="IDENTIQUES"; else verdict="DIFFÉRENTS"; fi
  echo "== $label : $verdict"
  echo "   build 1 : $a"; details "${label// /_}-1"
  echo "   build 2 : $b"; details "${label// /_}-2"
}

echo "BuildKit $(docker buildx inspect "$BUILDER" | awk -F': *' '/BuildKit version/ {print $2}'), SOURCE_DATE_EPOCH=$SDE ($(date -r "$SDE" -u '+%F %T UTC'))"
echo
scenario "1 aucun réglage" ""
scenario "2 SOURCE_DATE_EPOCH seul" "" --build-arg SOURCE_DATE_EPOCH="$SDE"
scenario "3 SOURCE_DATE_EPOCH + rewrite-timestamp" ",rewrite-timestamp=true" --build-arg SOURCE_DATE_EPOCH="$SDE"
scenario "4 idem sur la cible distroless" ",rewrite-timestamp=true" --build-arg SOURCE_DATE_EPOCH="$SDE" --target runtime-distroless
