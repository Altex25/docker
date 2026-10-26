#!/usr/bin/env bash
# Bonus B2 : --no-cache contre cache mount npm.
# Prérequis (builder dédié, vidé par le script) : docker buildx create --name tp01-bonus --driver docker-container
# « deps invalidées » simule un changement de package-lock.json via un ARG BUST injecté dans les étapes deps.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILDER=${BUILDER:-tp01-bonus}
RUNS=${RUNS:-3}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

sed -e 's#^FROM base AS deps-dev$#&\nARG BUST=0#' -e 's#^FROM base AS deps-prod$#&\nARG BUST=0#' Dockerfile > "$TMP/avec"
sed 's#RUN --mount=type=cache,target=/root/.npm \\#RUN \\#' "$TMP/avec" > "$TMP/sans"

now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }

# Affiche "total_s npm_ci_s exit" (npm_ci_s = somme des deux étapes npm ci).
build() {
  local f=$TMP/$1; shift
  local log=$TMP/build.log s e rc=0
  # Horodatage plutôt que compteur : build() tourne dans un sous-shell.
  local bust; bust=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1e6')
  s=$(now)
  docker buildx build --builder "$BUILDER" --progress=plain -f "$f" --output type=cacheonly \
    --build-arg BUST="$bust" "$@" . >"$log" 2>&1 || rc=$?
  e=$(now)
  local npm
  npm=$(awk '
    /^#[0-9]+ \[.*npm ci/ { split($1, a, "#"); ids[a[2]] = 1 }
    /^#[0-9]+ (DONE|ERROR)/ { split($1, a, "#"); if (a[2] in ids) { for (i = 3; i <= NF; i++) if ($i ~ /^[0-9.]+s$/) { sub("s", "", $i); t += $i } } }
    END { printf "%.1f", t }' "$log")
  printf '%.1f %s %s\n' "$(echo "$e - $s" | bc)" "$npm" "$rc"
}

median() { sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'; }

serie() {
  local totals="" npms="" t n rc
  for _ in $(seq "$RUNS"); do
    read -r t n rc < <(build "$@")
    totals+="$t"$'\n'; npms+="$n"$'\n'
  done
  echo "$(printf '%s' "$totals" | median) $(printf '%s' "$npms" | median)"
}

line() { printf '%-18s | %-16s | %8s | %8s | %s\n' "$@"; }

echo "BuildKit $(docker buildx inspect "$BUILDER" | awk -F': *' '/BuildKit version/ {print $2}'), $(date '+%F %H:%M'), médiane de $RUNS builds"
echo "Durées : build complet / somme des deux étapes npm ci (deps-dev + deps-prod, exécutées en parallèle)"
echo
line "variante" "scénario" "total" "npm ci" "résultat"
line "------------------" "----------------" "--------" "--------" "--------"
for v in sans avec; do
  docker buildx prune --builder "$BUILDER" -af >/dev/null
  read -r t n rc < <(build "$v")
  line "$v cache mount" "froid" "${t}s" "${n}s" "exit $rc"
  read -r t n < <(serie "$v" --no-cache)
  line "$v cache mount" "--no-cache" "${t}s" "${n}s" ""
  read -r t n < <(serie "$v")
  line "$v cache mount" "deps invalidées" "${t}s" "${n}s" ""
  read -r t n rc < <(build "$v" --network=none)
  line "$v cache mount" "deps, hors ligne" "${t}s" "${n}s" "exit $rc"
done

echo
echo "# Volume téléchargé par npm à chaque invalidation sans cache mount (contenu de /root/.npm après npm ci)"
for target in deps-dev deps-prod; do
  docker buildx build --builder "$BUILDER" -f "$TMP/sans" --target "$target" --load -t b2-tmp:"$target" . >/dev/null 2>&1
  echo "  $target : $(docker run --rm --entrypoint du b2-tmp:"$target" -sh /root/.npm | cut -f1)"
  docker image rm -f b2-tmp:"$target" >/dev/null
done
