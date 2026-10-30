#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
BACKUP_DIR=${BACKUP_DIR:-backups}
KEEP=${KEEP:-7}
ts=$(date +%Y%m%d-%H%M%S)
dir=$BACKUP_DIR/$ts
mkdir -p "$dir"
umask 077

echo "== Sauvegarde GestStock -> $dir"
db_dump | gzip -9 > "$dir/geststock.sql.gz"
gzip -t "$dir/geststock.sql.gz"
ok "base : $(du -h "$dir/geststock.sql.gz" | cut -f1) ($(gzip -dc "$dir/geststock.sql.gz" | grep -c '^INSERT INTO') instruction(s) INSERT)"

uploads_sh "tar -czf - -C $UPLOADS ." > "$dir/uploads.tar.gz"
files=$(tar -tzf "$dir/uploads.tar.gz" | grep -vc '/$' || true)
ok "uploads : $(du -h "$dir/uploads.tar.gz" | cut -f1), $files fichier(s)"

items=$(db_query 'SELECT count(*) FROM items')
photos=$(db_query 'SELECT count(photo) FROM items')
image=$(compose ps app --format '{{.Image}}' | head -1)
printf '{"date":"%s","items":%s,"photos_referencees":%s,"fichiers_uploads":%s,"image":"%s"}\n' \
  "$(date -Iseconds)" "$items" "$photos" "$files" "$image" > "$dir/manifest.json"
( cd "$dir" && sha_list geststock.sql.gz uploads.tar.gz manifest.json > SHA256SUMS )
ok "manifeste : $items articles, $photos photos référencées ; SHA256SUMS écrit"

total=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' | wc -l | tr -d ' ')
excess=$(( total - KEEP ))
if [ "$excess" -gt 0 ]; then
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | head -n "$excess" | while read -r old; do rm -rf "$old"; done
  ok "rétention : $excess ancienne(s) sauvegarde(s) supprimée(s), $KEEP conservées"
fi
echo "== $dir"
