#!/usr/bin/env bash
set -euo pipefail

PG16=postgres:16.4-alpine@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c
PRIMARY=tp05-pitr
RESTORED=tp05-pitr-restored
VOLUMES=(tp05-pitr-data tp05-pitr-wal tp05-pitr-base tp05-pitr-restore)
STATE_SQL="SELECT count(*) || ' commandes, total ' || coalesce(sum(montant), 0) FROM commandes"

down() {
  docker rm -f "$PRIMARY" "$RESTORED" > /dev/null 2>&1 || true
  docker volume rm "${VOLUMES[@]}" > /dev/null 2>&1 || true
}

if [ "${1:-run}" = down ]; then
  down
  echo "ressources tp05-pitr supprimées"
  exit 0
fi

sql() { docker exec "$1" psql -U postgres -d postgres -tAc "$2"; }
wait_ready() {
  for _ in $(seq 90); do docker exec "$1" pg_isready -h 127.0.0.1 -U postgres -q 2>/dev/null && return 0; sleep 1; done
  docker logs "$1" 2>&1 | tail -5
  return 1
}

down
for v in "${VOLUMES[@]}"; do docker volume create --label tp05=pitr "$v" > /dev/null; done
docker run --rm -v tp05-pitr-wal:/archive -v tp05-pitr-base:/base alpine:3.20 chown 70:70 /archive /base

echo "== 1. PostgreSQL 16 avec archivage des WAL dans le volume tp05-pitr-wal"
docker run -d --name "$PRIMARY" --label tp05=pitr -e POSTGRES_PASSWORD=x \
  -v tp05-pitr-data:/var/lib/postgresql/data -v tp05-pitr-wal:/archive -v tp05-pitr-base:/base "$PG16" \
  -c wal_level=replica -c archive_mode=on -c archive_timeout=60 \
  -c "archive_command=test ! -f /archive/%f && cp %p /archive/%f" > /dev/null
wait_ready "$PRIMARY"
echo "archive_mode=$(sql "$PRIMARY" 'SHOW archive_mode') archive_command=$(sql "$PRIMARY" 'SHOW archive_command')"

echo "== 2. Données initiales puis sauvegarde de base (pg_basebackup)"
sql "$PRIMARY" "CREATE TABLE commandes (id serial PRIMARY KEY, montant numeric(10, 2) NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp())" > /dev/null
sql "$PRIMARY" "INSERT INTO commandes (montant) SELECT round((random() * 100)::numeric, 2) FROM generate_series(1, 1000)" > /dev/null
docker exec "$PRIMARY" pg_basebackup -U postgres -D /base/base1 -Ft -z -X stream -c fast
echo "sauvegarde de base : $(docker exec "$PRIMARY" ls /base/base1 | paste -sd' ' -) ; état : $(sql "$PRIMARY" "$STATE_SQL")"

echo "== 3. Activité après la sauvegarde"
sql "$PRIMARY" "INSERT INTO commandes (montant) SELECT round((random() * 100)::numeric, 2) FROM generate_series(1, 500)" > /dev/null
sleep 1
target=$(sql "$PRIMARY" "SELECT clock_timestamp()")
expected=$(sql "$PRIMARY" "$STATE_SQL")
echo "T (cible de restauration) = $target ; état attendu : $expected"
sleep 2

echo "== 4. Incident : DELETE sans WHERE"
sql "$PRIMARY" "DELETE FROM commandes" > /dev/null
sql "$PRIMARY" "INSERT INTO commandes (montant) VALUES (1)" > /dev/null
echo "état après l'incident : $(sql "$PRIMARY" "$STATE_SQL")"
sql "$PRIMARY" "SELECT pg_switch_wal()" > /dev/null
for _ in $(seq 30); do
  [ "$(sql "$PRIMARY" "SELECT last_archived_wal = pg_walfile_name(pg_current_wal_lsn() - 1) OR failed_count > 0 FROM pg_stat_archiver")" = t ] && break
  sleep 1
done
echo "WAL archivés : $(docker exec "$PRIMARY" sh -c 'ls /archive | wc -l') ; dernier : $(sql "$PRIMARY" 'SELECT last_archived_wal FROM pg_stat_archiver')"
docker stop "$PRIMARY" > /dev/null

echo "== 5. Restauration à T : base1 + rejeu des WAL archivés jusqu'à T"
docker run --rm -v tp05-pitr-base:/base:ro -v tp05-pitr-restore:/restore alpine:3.20 sh -c "
  tar -xzf /base/base1/base.tar.gz -C /restore &&
  tar -xzf /base/base1/pg_wal.tar.gz -C /restore/pg_wal &&
  touch /restore/recovery.signal &&
  printf '%s\n' \"restore_command = 'cp /archive/%f %p'\" \"recovery_target_time = '$target'\" \"recovery_target_action = 'promote'\" >> /restore/postgresql.auto.conf &&
  chown -R 70:70 /restore && chmod 700 /restore"
docker run -d --name "$RESTORED" --label tp05=pitr -v tp05-pitr-restore:/var/lib/postgresql/data -v tp05-pitr-wal:/archive:ro "$PG16" > /dev/null
wait_ready "$RESTORED"
for _ in $(seq 30); do [ "$(sql "$RESTORED" 'SELECT pg_is_in_recovery()')" = f ] && break; sleep 1; done
docker logs "$RESTORED" 2>&1 | grep -E 'starting point-in-time recovery|recovery stopping|archive recovery complete|selected new timeline' | sed 's/^[0-9-]* [0-9:.]* UTC \[[0-9]*\] //'
restored=$(sql "$RESTORED" "$STATE_SQL")
echo "état restauré : $restored"

echo "== 6. Verdict"
if [ "$restored" = "$expected" ]; then echo "OK : état identique à T ($expected)"; else echo "KO : attendu $expected, obtenu $restored"; exit 1; fi
