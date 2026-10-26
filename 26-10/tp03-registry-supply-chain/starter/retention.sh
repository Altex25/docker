#!/usr/bin/env bash
# retention.sh REPO [N] : garde les tags semver et les N images non-semver les plus récentes (avec tous leurs tags).
# DRY_RUN=1 (défaut) affiche sans supprimer. Dépendances : bash 4+, curl, jq.
set -euo pipefail

REPO=${1:?usage: retention.sh REPO [N]}
KEEP=${2:-3}
REGISTRY=${REGISTRY:-https://registry.local:5000}
DRY_RUN=${DRY_RUN:-1}
CURL=(curl -sS --fail-with-body ${CACERT:+--cacert "$CACERT"} -u "${REGISTRY_USER:?}:${REGISTRY_PASSWORD:?}")
ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"
SEMVER='^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
COSIGN='^sha256-[0-9a-f]{64}(\.(sig|att|sbom))?$'

digest_of() {
  "${CURL[@]}" -I -H "Accept: $ACCEPT" "$REGISTRY/v2/$REPO/manifests/$1" \
    | tr -d '\r' | awk -F': ' 'tolower($1) == "docker-content-digest" { print $2 }'
}

created_of() {
  local m d
  m=$("${CURL[@]}" -H "Accept: $ACCEPT" "$REGISTRY/v2/$REPO/manifests/$1")
  if jq -e '.manifests' >/dev/null <<<"$m"; then
    d=$(jq -r '[.manifests[] | select(.platform.os != "unknown")][0].digest' <<<"$m")
    m=$("${CURL[@]}" -H "Accept: $ACCEPT" "$REGISTRY/v2/$REPO/manifests/$d")
  fi
  "${CURL[@]}" -L "$REGISTRY/v2/$REPO/blobs/$(jq -r .config.digest <<<"$m")" | jq -r '.created // "1970-01-01T00:00:00Z"'
}

delete() {
  local code
  code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X DELETE "$REGISTRY/v2/$REPO/manifests/$1" || true)
  echo "$code"
  [ "$code" = 202 ]
}

declare -A protected tags created
while read -r tag; do
  d=$(digest_of "$tag")
  if [[ $tag =~ $SEMVER || $tag =~ $COSIGN ]]; then
    protected[$d]+="$tag "
  else
    tags[$d]+="$tag "
    [ -n "${created[$d]:-}" ] || created[$d]=$(created_of "$tag")
  fi
done < <("${CURL[@]}" "$REGISTRY/v2/$REPO/tags/list" | jq -r '.tags[]?')

rc=0 i=0
while read -r c d; do
  [ -z "$d" ] && continue
  list=${tags[$d]% }
  if [ $i -lt "$KEEP" ]; then
    echo "garde     $list ($c)"
  elif [ -n "${protected[$d]:-}" ]; then
    for tag in $list; do
      if [ "$DRY_RUN" = 1 ]; then echo "supprime  $tag : tag seul, l'image reste publiée sous ${protected[$d]% } [dry-run]"
      elif code=$(delete "$tag"); then echo "supprime  $tag : tag seul, l'image reste publiée sous ${protected[$d]% } -> HTTP $code"
      else echo "conserve  $tag : même manifeste que ${protected[$d]% }, suppression par tag refusée (HTTP $code)"; fi
    done
  elif [ "$DRY_RUN" = 1 ]; then
    echo "supprime  $list ($d) [dry-run]"
  elif code=$(delete "$d"); then
    echo "supprime  $list ($d) -> HTTP $code"
  else
    echo "échec     $list ($d) -> HTTP $code"; rc=1
  fi
  i=$((i + 1))
done < <(for d in "${!tags[@]}"; do echo "${created[$d]} $d"; done | sort -r)
exit $rc
