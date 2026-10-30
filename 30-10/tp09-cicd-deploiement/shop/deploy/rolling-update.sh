#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?VERSION=<tag> obligatoire (sha-xxxxxxx ou X.Y.Z)}"
export DOCKER_CONTEXT=${DOCKER_CONTEXT:-preprod}
DEPLOY_DIR=${DEPLOY_DIR:-/srv/shop}
REPLICAS=${REPLICAS:-2}
STOP_TIMEOUT=${STOP_TIMEOUT:-15}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-120}
SETTLE=${SETTLE:-3}
VERIFY=${VERIFY:-1}
COMPOSE_FILES=${COMPOSE_FILES:-compose.yml compose.prod.yml}
SMOKE_URL=${SMOKE_URL:-http://127.0.0.1/ready}
SMOKE_HOST=${SMOKE_HOST:-api.localhost}
START=$(date +%s)

log() { printf '[%3ss] %s\n' "$(( $(date +%s) - START ))" "$*"; }
die() { log "ÉCHEC : $*"; exit 1; }

endpoint=$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}')
[[ $endpoint == ssh://* ]] || die "le contexte $DOCKER_CONTEXT n'est pas un hôte SSH ($endpoint)"
target=${endpoint#ssh://}
ssh_port=""
if [[ $target == *:* ]]; then ssh_port=${target##*:}; target=${target%:*}; fi
remote() { ssh ${ssh_port:+-p "$ssh_port"} "$target" "$@"; }

mkdir -p .ci
envfile=.ci/$DOCKER_CONTEXT.env
compose() {
  local args=() f
  for f in $COMPOSE_FILES; do args+=(-f "$f"); done
  docker compose --progress quiet --project-directory "$DEPLOY_DIR" --env-file "$envfile" "${args[@]}" "$@" \
    2> >(grep -v 'secret file .* does not exist' >&2)
}
health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1"; }
name() { docker inspect -f '{{.Name}}' "$1" | tr -d /; }
wait_healthy() {
  local c=$1 s deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    s=$(health "$c")
    case $s in
      healthy) return 0 ;;
      unhealthy | exited | dead) return 1 ;;
    esac
    sleep 1
  done
  return 1
}

smoke() {
  local body i
  for i in $(seq 30); do
    if body=$(remote "wget -q -T 2 -O - --header 'Host: $SMOKE_HOST' '$SMOKE_URL'" 2> /dev/null); then
      log "smoke test via Traefik ($SMOKE_HOST$( [ "$i" -gt 1 ] && echo ", après ${i}s" )) : $body"
      return 0
    fi
    sleep 1
  done
  die "smoke test $SMOKE_URL (Host: $SMOKE_HOST) en échec"
}

log "cible : $DOCKER_CONTEXT ($endpoint), version $VERSION, $REPLICAS réplicas"
remote test -s "$DEPLOY_DIR/secrets/db_password.txt" || die "secrets/db_password.txt absent de $DEPLOY_DIR sur le serveur"
remote cat "$DEPLOY_DIR/.env" > "$envfile" || die ".env absent de $DEPLOY_DIR sur le serveur"
COPYFILE_DISABLE=1 tar -cf - config db | remote "tar -C '$DEPLOY_DIR' -xf -"
log "fichiers de configuration synchronisés dans $DEPLOY_DIR, .env et secrets/ lus sur le serveur"

if [ "$VERIFY" = 1 ]; then
  REGISTRY=${REGISTRY:-$(sed -n 's/^REGISTRY=//p' "$envfile")} ./deploy/verify-signature.sh > .ci/images.env
  set -a
  . .ci/images.env
  set +a
else
  log "ATTENTION : vérification des signatures désactivée (VERIFY=0)"
fi

compose pull -q api worker
log "images tirées sur le serveur"
compose up -d --wait db redis traefik
compose up -d --no-deps --wait worker
log "db, redis, traefik et worker à jour et healthy"

old=$(compose ps -q api)
if [ -z "$old" ]; then
  compose up -d --no-deps --wait --scale "api=$REPLICAS" api
  log "premier déploiement : $REPLICAS réplicas healthy"
  smoke
  exit 0
fi

for c in $old; do
  before=$(compose ps -q api | sort)
  count=$(wc -l <<<"$before" | tr -d ' ')
  compose up -d --no-deps --no-recreate --scale "api=$((count + 1))" api 2> /dev/null
  new=$(comm -13 <(echo "$before") <(compose ps -q api | sort) | head -1)
  [ -n "$new" ] || die "aucun nouveau conteneur créé"
  log "$(name "$new") démarré ($(docker inspect -f '{{.Config.Image}}' "$new" | sed 's/@sha256:\(.\{12\}\).*/@\1…/')), attente de healthy"
  if ! wait_healthy "$new"; then
    n=$(name "$new")
    docker logs --tail 5 "$new" 2>&1 | sed 's/^/    /'
    docker rm -f "$new" > /dev/null
    die "$n pas healthy en ${HEALTH_TIMEOUT}s : retiré, $(name "$c") ($(health "$c")) continue de servir l'ancienne version"
  fi
  log "$(name "$new") healthy, Traefik l'ajoute au load balancer"
  sleep "$SETTLE"
  log "arrêt de $(name "$c") (SIGTERM, ${STOP_TIMEOUT}s avant SIGKILL)"
  docker stop -t "$STOP_TIMEOUT" "$c" > /dev/null
  docker rm "$c" > /dev/null
done

while [ "$(compose ps -q api | wc -l | tr -d ' ')" -lt "$REPLICAS" ]; do
  compose up -d --no-deps --no-recreate --wait --scale "api=$(( $(compose ps -q api | wc -l) + 1 ))" api
done

compose ps api --format '{{.Name}} {{.Status}}' | sed 's/^/    /'
smoke
log "rolling update terminé : $VERSION"
