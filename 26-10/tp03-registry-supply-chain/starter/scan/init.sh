#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || printf 'TRIVY_TOKEN=%s\n' "$(openssl rand -hex 24)" > .env
docker compose --profile update run --rm db-update
docker compose up -d trivy
