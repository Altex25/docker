#!/usr/bin/env bash
set -euo pipefail
R=${REGISTRY:-https://registry.local:5000}
CURL=(curl -sS ${CACERT:+--cacert "$CACERT"} -u "${REGISTRY_USER:?}:${REGISTRY_PASSWORD:?}")
ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"
run() { echo "\$ $1"; eval "$1"; echo; }
digest() { "${CURL[@]}" -I -H "Accept: $ACCEPT" "$R/v2/$1/manifests/$2" | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}'; }
status() { for t in "$@"; do printf '%-13s HTTP %s\n' "$t" "$("${CURL[@]}" -o /dev/null -w '%{http_code}' -I -H "Accept: $ACCEPT" "$R/v2/demo/manifests/$t")"; done; }
retag() {
  local type
  type=$("${CURL[@]}" -I -H "Accept: $ACCEPT" "$R/v2/demo/manifests/$1" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print $2}')
  "${CURL[@]}" -H "Accept: $ACCEPT" "$R/v2/demo/manifests/$1" \
    | "${CURL[@]}" -o /dev/null -w "PUT /v2/demo/manifests/$2 -> HTTP %{http_code}\n" -X PUT -H "Content-Type: $type" --data-binary @- "$R/v2/demo/manifests/$2"
}

run '"${CURL[@]}" "$R/v2/_catalog" | jq -c .'
run '"${CURL[@]}" "$R/v2/demo/tags/list" | jq -r ".tags | sort | join(\" \")"'
run '"${CURL[@]}" -I "$R/v2/demo/manifests/latest" | grep -iE "^(HTTP|content-type|docker-content-digest)"'
run '"${CURL[@]}" -I -H "Accept: $ACCEPT" "$R/v2/demo/manifests/latest" | grep -iE "^(HTTP|content-type|docker-content-digest)"'
run 'for t in latest main-5f6a7b8 main-4e5f6a7; do printf "%-13s %s\n" $t "$(digest demo $t)"; done'
D=$(digest demo latest)
run '"${CURL[@]}" -o /dev/null -w "HTTP %{http_code}\n" -X DELETE "$R/v2/demo/manifests/latest"'
run 'status latest main-5f6a7b8'
run 'retag main-5f6a7b8 latest'
run 'status latest main-5f6a7b8'
run '"${CURL[@]}" -o /dev/null -w "HTTP %{http_code}\n" -X DELETE "$R/v2/demo/manifests/'"$D"'"'
run 'status latest main-5f6a7b8'
run '"${CURL[@]}" "$R/v2/demo/tags/list" | jq -r ".tags | sort | join(\" \")"'
