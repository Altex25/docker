#!/usr/bin/env bash
# Étape 5 : cache distant type=registry, mode=min contre mode=max, sur un « runner neuf » (builder vidé).
# Prérequis : builder shop (network=host) et registre local : docker run -d --name tp02-registry -p 5050:5000 registry:2.8.3
set -euo pipefail
cd "$(dirname "$0")/.."

BUILDER=${BUILDER:-shop}
REGISTRY=${REGISTRY:-localhost:5050}
PLATFORM=${PLATFORM:-linux/arm64}
LOG=$(mktemp)
ORIG=$(mktemp)
cp worker/main.py "$ORIG"
trap 'cp "$ORIG" worker/main.py; rm -f "$LOG" "$ORIG"' EXIT

now() { perl -MTime::HiRes=time -e 'printf "%.1f", time'; }

# Affiche "durée étapes_servies_par_le_cache étapes_exécutées liste_des_étapes_exécutées".
build() {
  local s e
  s=$(now)
  docker buildx build --builder "$BUILDER" --progress=plain --platform "$PLATFORM" \
    --secret id=pipconf,src=pip.conf --output type=cacheonly "$@" . >"$LOG" 2>&1
  e=$(now)
  local cached ran list
  cached=$(awk '/^#[0-9]+ (CACHED$|sha256:|extracting)/ { split($1, a, "#"); hit[a[2]] = 1 } END { print length(hit) }' "$LOG")
  # Étape exécutée = ni CACHED ni importée du cache distant (lignes sha256:/extracting = téléchargement de ses couches).
  list=$(awk '/^#[0-9]+ \[(builder|test|runtime) / { split($1, a, "#"); step[a[2]] = $2 " " $3 }
              /^#[0-9]+ CACHED$/ { split($1, a, "#"); hit[a[2]] = 1 }
              /^#[0-9]+ (sha256:|extracting)/ { split($1, a, "#"); hit[a[2]] = 1 }
              /^#[0-9]+ DONE/ { split($1, a, "#"); done[a[2]] = 1 }
              END { for (i in step) if ((i in done) && !(i in hit) && step[i] !~ /1\/5/) print step[i] }' "$LOG" \
         | sed 's/[][]//g' | sort -u | paste -sd',' -)
  ran=$(awk -F',' '{ print ($0 == "" ? 0 : NF) }' <<<"$list")
  echo "$(echo "$e - $s" | bc) $cached $ran ${list:-aucune}"
}

# Taille des blobs référencés par le manifeste de cache.
cache_size() {
  local repo=${1%%:*} tag=${1##*:}
  curl -s -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json' \
    "http://$REGISTRY/v2/$repo/manifests/$tag" \
    | jq '[.manifests[]?, .layers[]? | select(.mediaType | test("layer|gzip|zstd")) | .size] | add // 0 | . / 1e6 | floor'
}

echo "Plateforme $PLATFORM, registre $REGISTRY"
printf '%-6s | %-34s | %7s | %6s | %8s | %s\n' "mode" "scénario" "durée" "cache" "exécutés" "étapes exécutées"
for mode in min max; do
  ref="$REGISTRY/cache:worker-$mode"
  docker buildx prune --builder "$BUILDER" -af >/dev/null
  read -r t c r l < <(build --cache-to "type=registry,ref=$ref,mode=$mode")
  printf '%-6s | %-34s | %6ss | %6s | %8s | %s\n' "$mode" "runner A : build + --cache-to" "$t" "$c" "$r" "$l"
  docker buildx prune --builder "$BUILDER" -af >/dev/null
  read -r t c r l < <(build --cache-from "type=registry,ref=$ref")
  printf '%-6s | %-34s | %6ss | %6s | %8s | %s\n' "" "runner B neuf : --cache-from" "$t" "$c" "$r" "$l"
  echo "# commentaire $mode" >> worker/main.py
  docker buildx prune --builder "$BUILDER" -af >/dev/null
  read -r t c r l < <(build --cache-from "type=registry,ref=$ref")
  printf '%-6s | %-34s | %6ss | %6s | %8s | %s\n' "" "runner C neuf : code modifié" "$t" "$c" "$r" "$l"
  cp "$ORIG" worker/main.py
  echo "       cache exporté : $(cache_size "cache:worker-$mode") Mo"
done
docker buildx prune --builder "$BUILDER" -af >/dev/null
read -r t c r l < <(build)
printf '%-6s | %-34s | %6ss | %6s | %8s | %s\n' "aucun" "runner neuf sans cache distant" "$t" "$c" "$r" "$l"
