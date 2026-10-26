#!/usr/bin/env bash
# Étape 3 : séquence du README (build, prune, ajout de requests, rebuild), avec et sans cache mount pip.
# Prérequis : docker buildx create --name shop --driver docker-container --driver-opt network=host
set -euo pipefail
cd "$(dirname "$0")/.."

BUILDER=${BUILDER:-shop}
TMP=$(mktemp -d)
cp requirements.txt "$TMP/requirements.txt.orig"
trap 'cp "$TMP/requirements.txt.orig" requirements.txt; rm -rf "$TMP"' EXIT

sed 's#    --mount=type=cache,target=/root/.cache/pip,id=pip-${TARGETARCH} \\#    \\#' Dockerfile > "$TMP/sans"
cp Dockerfile "$TMP/avec"

now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }

# Affiche "total_s pip_s téléchargés depuis_le_cache" (pip_s = somme des étapes pip install ; compteurs lus dans les logs pip).
build() {
  local f=$TMP/$1; shift
  local log=$TMP/build.log s e
  s=$(now)
  docker buildx build --builder "$BUILDER" --progress=plain -f "$f" --secret id=pipconf,src=pip.conf \
    --output type=cacheonly "$@" . >"$log" 2>&1
  e=$(now)
  local pip
  pip=$(awk '
    /^#[0-9]+ \[.*pip install/ { split($1, a, "#"); ids[a[2]] = 1 }
    /^#[0-9]+ DONE [0-9.]+s$/ { split($1, a, "#"); if (a[2] in ids) { sub("s", "", $3); t += $3 } }
    END { printf "%.1f", t }' "$log")
  printf '%.1f %s %s %s\n' "$(echo "$e - $s" | bc)" "$pip" "$(grep -c ' Downloading ' "$log" || true)" "$(grep -c ' Using cached ' "$log" || true)"
}

cachemount_size() {
  docker buildx du --builder "$BUILDER" --verbose 2>/dev/null | awk '
    function flush() { if (type == "exec.cachemount" && desc ~ /pip/) { print size; found = 1 } type = ""; desc = ""; size = "" }
    /^ID:/ { flush() } /^Size:/ { size = $2 } /^Description:/ { desc = $0 } /^Type:/ { type = $2 }
    END { flush(); if (!found) print "absent" }' | paste -sd' ' -
}

printf '%-18s | %-38s | %7s | %6s | %5s | %5s | %s\n' "variante" "étape" "total" "pip" "télé." "cache" "cache mount pip"
row() { printf '%-18s | %-38s | %6ss | %5ss | %5s | %5s | %s\n' "$@"; }
for v in sans avec; do
  cp "$TMP/requirements.txt.orig" requirements.txt
  docker buildx prune --builder "$BUILDER" -af >/dev/null
  read -r t p d c < <(build "$v")
  row "$v cache mount" "1. build initial (builder vide)" "$t" "$p" "$d" "$c" "$(cachemount_size)"
  docker buildx prune --builder "$BUILDER" -f >/dev/null
  printf '%-18s | %-38s | %7s | %6s | %5s | %5s | %s\n' "" "2. docker builder prune -f" "" "" "" "" "$(cachemount_size)"
  echo "requests==2.32.3" >> requirements.txt
  read -r t p d c < <(build "$v")
  row "" "3. + requests==2.32.3, rebuild" "$t" "$p" "$d" "$c" ""
  read -r t p d c < <(build "$v" --no-cache)
  row "" "4. --no-cache" "$t" "$p" "$d" "$c" ""
  docker buildx prune --builder "$BUILDER" -f --filter type=regular >/dev/null
  printf '%-18s | %-38s | %7s | %6s | %5s | %5s | %s\n' "" "5. prune -f --filter type=regular" "" "" "" "" "$(cachemount_size)"
  read -r t p d c < <(build "$v")
  row "" "6. rebuild après prune des couches" "$t" "$p" "$d" "$c" ""
done
