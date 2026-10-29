#!/usr/bin/env bash
set -euo pipefail

PROJECT=${PROJECT:-shop}
SERVICE=${SERVICE:-db}
DB_NAME=${DB_NAME:-shop}
DB_USER=${DB_USER:-shop}
VOLUME=${VOLUME:-${PROJECT}_pgdata}
BACKUP_DIR=${BACKUP_DIR:-$(cd "$(dirname "$0")" && pwd)/backups}
KEEP=${KEEP:-7}
RAW=${RAW:-0}
TS=$(date -u +%Y%m%dT%H%M%SZ)
CHECKSUM_SQL="SELECT count(*) || ' ' || coalesce(md5(string_agg(id::text || status, ',' ORDER BY id)), '-') FROM orders"

container=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$SERVICE" | head -1)
if [ -z "$container" ]; then
  echo "conteneur $PROJECT/$SERVICE introuvable ou arrêté" >&2
  exit 2
fi

wait_healthy() {
  local i status
  for i in $(seq 60); do
    status=$(docker inspect "$1" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')
    [ "$status" = healthy ] || [ "$status" = running ] && return 0
    sleep 1
  done
  echo "$1 n'est pas redevenu sain" >&2
  return 1
}

prune() {
  local pattern=$1 f
  ls -1t "$BACKUP_DIR"/$pattern 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r f; do
    rm -f -- "$f" "$f.sha256"
    echo "rétention : $(basename "$f") supprimé"
  done
}

mkdir -p "$BACKUP_DIR"
echo "== Sauvegarde $PROJECT/$SERVICE ($DB_NAME) : $TS"
echo "empreinte (commandes md5) : $(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc "$CHECKSUM_SQL" 2>/dev/null || echo 'table orders absente')"

dump=$BACKUP_DIR/$PROJECT-$DB_NAME-$TS.dump
docker exec "$container" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc -Z 6 > "$dump.part"
mv "$dump.part" "$dump"
docker exec -i "$container" pg_restore --list < "$dump" > /dev/null
(cd "$BACKUP_DIR" && shasum -a 256 "$(basename "$dump")" > "$(basename "$dump").sha256")
echo "dump logique  : $dump ($(du -h "$dump" | cut -f1), $(docker exec -i "$container" pg_restore --list < "$dump" | grep -c 'TABLE DATA') tables)"

globals=$BACKUP_DIR/$PROJECT-globals-$TS.sql
docker exec "$container" pg_dumpall -U "$DB_USER" --globals-only > "$globals"
echo "rôles         : $globals"

if [ "$RAW" = 1 ]; then
  raw=$BACKUP_DIR/$PROJECT-pgdata-$TS.tar.gz
  start=$(date +%s)
  docker stop "$container" > /dev/null
  trap 'docker start "$container" > /dev/null' EXIT
  docker run --rm -v "$VOLUME:/data:ro" -v "$BACKUP_DIR:/backup" alpine:3.20 \
    tar -czf "/backup/$(basename "$raw")" -C /data .
  docker start "$container" > /dev/null
  trap - EXIT
  wait_healthy "$container"
  (cd "$BACKUP_DIR" && shasum -a 256 "$(basename "$raw")" > "$(basename "$raw").sha256")
  echo "copie brute   : $raw ($(du -h "$raw" | cut -f1), base arrêtée $(( $(date +%s) - start )) s)"
fi

prune "$PROJECT-$DB_NAME-*.dump"
prune "$PROJECT-globals-*.sql"
prune "$PROJECT-pgdata-*.tar.gz"
echo "== OK ($(ls -1 "$BACKUP_DIR"/$PROJECT-$DB_NAME-*.dump | wc -l | tr -d ' ') dump(s) conservé(s), maximum $KEEP)"
