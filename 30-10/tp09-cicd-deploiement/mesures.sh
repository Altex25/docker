#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/shop"
export PATH="$(cd ../serveur && pwd)/bin:$PATH"
export DOCKER_CONTEXT=${DOCKER_CONTEXT:-preprod}
export REGISTRY=${REGISTRY:-registry.local:5000}
V_OLD=${V_OLD:?V_OLD=sha-... (version de départ)}
V_NEW=${V_NEW:?V_NEW=sha-... (nouvelle version)}
CASSEE="compose.yml compose.prod.yml ../experiences/release-cassee.yml"

mesure() { local d=$1; shift; DURATION=$d ./deploy/mesurer.sh "$@"; echo; }

echo "### $(date '+%F %T') contexte $DOCKER_CONTEXT, $V_OLD -> $V_NEW"
VERSION=$V_OLD ./deploy/rolling-update.sh > /dev/null
echo "état initial : $(docker compose -p shop ps api --format '{{.Name}}' | wc -l | tr -d ' ') réplicas en $V_OLD"
echo

mesure 30 "A. Témoin : aucun déploiement" sleep 1
VERSION=$V_OLD mesure 40 "B. Naïf : docker compose up -d --force-recreate api" ./deploy/naive-update.sh
VERSION=$V_OLD ./deploy/rolling-update.sh > /dev/null
VERSION=$V_NEW mesure 50 "C. Rolling update $V_OLD -> $V_NEW" ./deploy/rolling-update.sh
VERSION=$V_OLD mesure 50 "D. Rollback $V_NEW -> $V_OLD" ./deploy/rolling-update.sh
VERSION=$V_OLD STOP_TIMEOUT=0 mesure 50 "E. Rolling sans arrêt propre (docker stop -t 0 : SIGKILL, pas de drain)" ./deploy/rolling-update.sh
VERSION=$V_OLD COMPOSE_FILES=$CASSEE HEALTH_TIMEOUT=45 mesure 70 "F1. Release cassée (port 3999, jamais healthy) en rolling update" ./deploy/rolling-update.sh
VERSION=$V_OLD COMPOSE_FILES=$CASSEE mesure 40 "F2. Release cassée en déploiement naïf" \
  docker compose --progress quiet --project-directory /srv/shop --env-file ".ci/$DOCKER_CONTEXT.env" \
  -f compose.yml -f compose.prod.yml -f ../experiences/release-cassee.yml up -d --force-recreate api
VERSION=$V_OLD mesure 60 "F3. Réparation : rolling update vers $V_OLD" ./deploy/rolling-update.sh
