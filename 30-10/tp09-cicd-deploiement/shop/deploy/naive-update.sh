#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DOCKER_CONTEXT=${DOCKER_CONTEXT:-preprod}
DEPLOY_DIR=${DEPLOY_DIR:-/srv/shop}
envfile=.ci/$DOCKER_CONTEXT.env
mkdir -p .ci
endpoint=$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}')
target=${endpoint#ssh://}
ssh -p "${target##*:}" "${target%:*}" cat "$DEPLOY_DIR/.env" > "$envfile"
docker compose --progress quiet --project-directory "$DEPLOY_DIR" --env-file "$envfile" -f compose.yml -f compose.prod.yml \
  up -d --force-recreate api 2> >(grep -v 'secret file .* does not exist' >&2)
