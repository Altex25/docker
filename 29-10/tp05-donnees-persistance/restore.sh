#!/usr/bin/env bash
set -euo pipefail

FILE=${1:?usage: restore.sh FICHIER.dump | FICHIER.tar.gz}
PROJECT=${PROJECT:-shop}
SERVICE=${SERVICE:-db}
DB_NAME=${DB_NAME:-shop}
DB_USER=${DB_USER:-shop}
VOLUME=${VOLUME:-${PROJECT}_pgdata}
VOLUME_KEY=${VOLUME_KEY:-pgdata}
CHECKSUM_SQL="SELECT count(*) || ' ' || coalesce(md5(string_agg(id::text || status, ',' ORDER BY id)), '-') FROM orders"

[ -f "$FILE" ] || { echo "fichier introuvable : $FILE" >&2; exit 2; }
if [ -f "$FILE.sha256" ]; then
  (cd "$(dirname "$FILE")" && shasum -a 256 -c "$(basename "$FILE").sha256" > /dev/null) || { echo "empreinte sha256 invalide : $FILE" >&2; exit 1; }
  echo "sha256 vérifié : $(basename "$FILE")"
fi

container() { docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$SERVICE" | head -1; }

case $FILE in
  *.dump)
    c=$(container)
    [ -n "$c" ] && [ "$(docker inspect "$c" --format '{{.State.Running}}')" = true ] || { echo "la base $PROJECT/$SERVICE doit tourner" >&2; exit 2; }
    start=$(date +%s)
    docker exec -i "$c" pg_restore -U "$DB_USER" -d "$DB_NAME" --clean --if-exists --no-owner --single-transaction --exit-on-error < "$FILE"
    docker exec "$c" psql -U "$DB_USER" -d "$DB_NAME" -qc "ANALYZE"
    echo "restauration logique en $(( $(date +%s) - start )) s"
    echo "empreinte (commandes md5) : $(docker exec "$c" psql -U "$DB_USER" -d "$DB_NAME" -tAc "$CHECKSUM_SQL")"
    ;;
  *.tar.gz)
    [ -z "$(container)" ] || { echo "supprimer d'abord le conteneur $PROJECT/$SERVICE (docker compose rm -sf $SERVICE)" >&2; exit 2; }
    if docker volume inspect "$VOLUME" > /dev/null 2>&1; then
      docker volume rm "$VOLUME" > /dev/null
    fi
    docker volume create --label "com.docker.compose.project=$PROJECT" --label "com.docker.compose.volume=$VOLUME_KEY" "$VOLUME" > /dev/null
    docker run --rm -v "$VOLUME:/data" -v "$(cd "$(dirname "$FILE")" && pwd):/backup:ro" alpine:3.20 \
      tar -xzpf "/backup/$(basename "$FILE")" -C /data
    echo "volume $VOLUME recréé depuis $(basename "$FILE") : relancer la base (docker compose up -d --wait $SERVICE)"
    ;;
  *)
    echo "format non reconnu : $FILE" >&2
    exit 2
    ;;
esac
