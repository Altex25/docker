#!/usr/bin/env bash
set -euo pipefail
SHOP=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(dirname "$SHOP")
STATE=$SHOP/.ci
CA=${REGISTRY_CA:-$ROOT/../../26-10/tp03-registry-supply-chain/starter/registry/certs/ca.crt}
mkdir -p "$STATE/docker"
if [ ! -s "$STATE/ca-bundle.crt" ]; then
  env -u DOCKER_CONTEXT docker run --rm curlimages/curl:8.11.1 cat /etc/ssl/certs/ca-certificates.crt > "$STATE/ca-bundle.crt"
  if [ -f "$CA" ]; then cat "$CA" >> "$STATE/ca-bundle.crt"; fi
fi
DOCKER_CFG=${OCI_DOCKER_CONFIG:-$STATE/docker}
if [ -z "${OCI_DOCKER_CONFIG:-}" ] && [ ! -s "$STATE/docker/config.json" ]; then
  printf '{"auths":{"%s":{"auth":"%s"}}}\n' "${REGISTRY_HOST:-registry.local:5000}" \
    "$(printf '%s:%s' "${REGISTRY_USER:-ci}" "${REGISTRY_PASSWORD:-ci-push-2024}" | base64)" > "$STATE/docker/config.json"
fi
IMAGE=$1; shift
exec env -u DOCKER_CONTEXT docker run --rm -i --network host \
  -v "$ROOT:/w" -w "/w/$(basename "$SHOP")" \
  -v "$STATE/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro" -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
  -v "$DOCKER_CFG:/docker-config:ro" -e DOCKER_CONFIG=/docker-config \
  -v tp09-trivy-cache:/root/.cache -e TRIVY_CACHE_DIR=/root/.cache/trivy \
  -e COSIGN_PASSWORD -e COSIGN_YES=true -e COSIGN_EXPERIMENTAL \
  ${OCI_ENTRYPOINT:+--entrypoint "$OCI_ENTRYPOINT"} "$IMAGE" "$@"
