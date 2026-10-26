#!/usr/bin/env bash
# oci.sh IMAGE [ARGS...] : lance un outil OCI (crane, skopeo, syft, trivy, cosign) avec accès à registry.local:5000.
set -euo pipefail
STARTER=$(cd "$(dirname "$0")/.." && pwd)
T=$STARTER/tools
if [ ! -f "$T/ca-bundle.crt" ]; then
  docker run --rm curlimages/curl:8.11.1 cat /etc/ssl/certs/ca-certificates.crt > "$T/ca-bundle.crt"
  cat "$STARTER/registry/certs/ca.crt" >> "$T/ca-bundle.crt"
fi
if [ ! -f "$T/.docker/config.json" ]; then
  mkdir -p "$T/.docker"
  printf '{"auths":{"registry.local:5000":{"auth":"%s"}}}\n' \
    "$(printf '%s:%s' "${REGISTRY_USER:-ci}" "${REGISTRY_PASSWORD:-ci-push-2024}" | base64)" > "$T/.docker/config.json"
fi
IMAGE=$1; shift
exec docker run --rm --network host --add-host registry.local:127.0.0.1 \
  -v /var/run/docker.sock:/var/run/docker.sock -v "$STARTER:/w" -w /w \
  -v "$T/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro" -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
  -v "$T/.docker:/docker-config:ro" -e DOCKER_CONFIG=/docker-config -e REGISTRY_AUTH_FILE=/docker-config/config.json \
  -v trivy-cache:/root/.cache -e TRIVY_CACHE_DIR=/root/.cache/trivy \
  -e COSIGN_PASSWORD -e COSIGN_YES=true \
  ${OCI_ENTRYPOINT:+--entrypoint "$OCI_ENTRYPOINT"} "$IMAGE" "$@"
