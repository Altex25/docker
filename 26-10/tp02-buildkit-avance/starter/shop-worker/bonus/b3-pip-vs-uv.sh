#!/usr/bin/env bash
# Bonus B3 : pip (Dockerfile) contre uv (bonus/Dockerfile.uv), plateforme native, builder shop.
# « deps invalidées » : un ARG BUST injecté dans l'étape builder invalide les installations, le cache mount reste chaud.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILDER=${BUILDER:-shop}
PLATFORM=${PLATFORM:-linux/arm64}
RUNS=${RUNS:-3}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export UV_DEFAULT_INDEX=https://pypi.org/simple

for v in pip uv; do
  src=Dockerfile; [ "$v" = uv ] && src=bonus/Dockerfile.uv
  sed 's#^FROM ${PYTHON_IMAGE} AS builder$#&\nARG BUST=0#' "$src" > "$TMP/$v"
done

now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }

# Affiche "total_s install_s" (install_s = somme des deux étapes d'installation, builder + test).
build() {
  local v=$1; shift
  local log=$TMP/build.log s e secret
  if [ "$v" = uv ]; then secret=(--secret id=uv_index,env=UV_DEFAULT_INDEX); else secret=(--secret id=pipconf,src=pip.conf); fi
  s=$(now)
  docker buildx build --builder "$BUILDER" --progress=plain --platform "$PLATFORM" -f "$TMP/$v" "${secret[@]}" \
    --build-arg BUST="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1e6')" --output type=cacheonly "$@" . >"$log" 2>&1
  e=$(now)
  local inst
  inst=$(awk '
    /^#[0-9]+ \[(builder|test) [0-9]\/[0-9]\] RUN .*pip install/ { split($1, a, "#"); ids[a[2]] = 1 }
    /^#[0-9]+ DONE [0-9.]+s$/ { split($1, a, "#"); if (a[2] in ids) { sub("s", "", $3); t += $3 } }
    END { printf "%.2f", t }' "$log")
  printf '%.1f %s\n' "$(echo "$e - $s" | bc)" "$inst"
}

median() { sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'; }

printf '%-4s | %-30s | %7s | %12s\n' "outil" "scénario" "total" "installation"
for v in pip uv; do
  docker buildx prune --builder "$BUILDER" -af >/dev/null
  read -r t i < <(build "$v")
  printf '%-5s | %-30s | %6ss | %11ss\n' "$v" "froid (cache mount vide)" "$t" "$i"
  totals=""; insts=""
  for _ in $(seq "$RUNS"); do
    read -r t i < <(build "$v")
    totals+="$t"$'\n'; insts+="$i"$'\n'
  done
  printf '%-5s | %-30s | %6ss | %11ss\n' "" "deps invalidées, cache chaud" "$(printf '%s' "$totals" | median)" "$(printf '%s' "$insts" | median)"
done
