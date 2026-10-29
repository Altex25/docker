#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

OLD=(-f starter/compose.yml -f compose.noports.yml)
NEW=(-f starter/compose.yml -f compose.noports.yml -f compose.pg16.yml)
DB_USER=${DB_USER:-shop}
DB_NAME=${DB_NAME:-shop}
OUT=${OUT:-backups/upgrade}
OLD_VOLUME=shopdata_pgdata
NEW_VOLUME=shopdata_pgdata16
TS=$(date -u +%Y%m%dT%H%M%SZ)
CHECKSUM_SQL="SELECT (SELECT count(*) FROM products) || ' produits, ' || count(*) || ' commandes, md5 ' || md5(string_agg(id::text || status, ',' ORDER BY id)) FROM orders"

old() { docker compose "${OLD[@]}" "$@"; }
new() { docker compose "${NEW[@]}" "$@"; }
step() { printf '\n== %s\n' "$*"; }
rollback() {
  echo "retour arrière :"
  echo "  docker compose ${NEW[*]} stop db"
  echo "  docker compose ${OLD[*]} up -d --wait db"
  echo "  (le volume $OLD_VOLUME n'a pas été modifié)"
}

if docker volume inspect "$NEW_VOLUME" > /dev/null 2>&1 && [ "${FORCE:-0}" != 1 ]; then
  echo "le volume $NEW_VOLUME existe déjà : montée de version déjà faite ? (FORCE=1 pour la refaire)" >&2
  exit 2
fi

step "1. État initial"
old up -d --wait db > /dev/null 2>&1
echo "version         : $(old exec -T db psql -U "$DB_USER" -d "$DB_NAME" -tAc 'SHOW server_version')"
before=$(old exec -T db psql -U "$DB_USER" -d "$DB_NAME" -tAc "$CHECKSUM_SQL")
echo "empreinte avant : $before"

step "2. Sauvegardes (début de l'indisponibilité : plus aucune écriture ne doit arriver)"
start=$(date +%s)
mkdir -p "$OUT"
old exec -T db pg_dumpall -U "$DB_USER" > "$OUT/pg14-dumpall-$TS.sql"
old exec -T db pg_dumpall -U "$DB_USER" --globals-only > "$OUT/pg14-globals-$TS.sql"
old exec -T db pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$OUT/pg14-$DB_NAME-$TS.dump"
for f in "$OUT"/pg14-*-"$TS".*; do
  (cd "$OUT" && shasum -a 256 "$(basename "$f")" > "$(basename "$f").sha256")
  echo "$(basename "$f") : $(du -h "$f" | cut -f1)"
done

step "3. Arrêt de PostgreSQL 14 ($OLD_VOLUME conservé)"
old stop db 2>&1 | tail -1

step "4. PostgreSQL 16 sur le nouveau volume $NEW_VOLUME"
new up -d --wait db 2>&1 | tail -1
echo "version : $(new exec -T db psql -U "$DB_USER" -d "$DB_NAME" -tAc 'SHOW server_version')"

step "5. Restauration"
new exec -T db psql -U "$DB_USER" -d postgres -q < "$OUT/pg14-globals-$TS.sql" 2>&1 | grep -v 'already exists' || true
if ! new exec -T db pg_restore -U "$DB_USER" -d "$DB_NAME" --exit-on-error --single-transaction < "$OUT/pg14-$DB_NAME-$TS.dump"; then
  echo "ÉCHEC de la restauration" >&2
  rollback
  exit 1
fi
new exec -T db vacuumdb -U "$DB_USER" -d "$DB_NAME" --analyze-only -q
after=$(new exec -T db psql -U "$DB_USER" -d "$DB_NAME" -tAc "$CHECKSUM_SQL")
end=$(date +%s)
echo "empreinte après : $after"

step "6. Verdict"
echo "indisponibilité : $((end - start)) s"
if [ "$before" = "$after" ]; then
  echo "OK : données identiques, PostgreSQL $(new exec -T db psql -U "$DB_USER" -d "$DB_NAME" -tAc 'SHOW server_version') en service sur $NEW_VOLUME"
  echo "$OLD_VOLUME est conservé pour un retour arrière ; le supprimer seulement après validation."
  rollback
else
  echo "KO : empreintes différentes" >&2
  echo "  avant : $before" >&2
  echo "  après : $after" >&2
  rollback
  exit 1
fi
