#!/usr/bin/env bash
# Exécute une commande dans le réseau de la VM Docker, où registry.local:5000 est joignable.
set -euo pipefail
STARTER=$(cd "$(dirname "$0")/.." && pwd)
docker image inspect tp03-tools >/dev/null 2>&1 || docker build -q -t tp03-tools "$STARTER/tools" >/dev/null
exec docker run --rm --network host --add-host registry.local:127.0.0.1 \
  -v "$STARTER:/w" -w /w -e CACERT=/w/registry/certs/ca.crt \
  -e REGISTRY_USER -e REGISTRY_PASSWORD -e DRY_RUN tp03-tools "$@"
