#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
dir=${1:?usage: restore.sh backups/<horodatage>}
[ -f "$dir/SHA256SUMS" ] || { echo "pas de SHA256SUMS dans $dir" >&2; exit 2; }

echo "== Restauration GestStock depuis $dir ($COMPOSE)"
( cd "$dir" && sha_list -c --quiet SHA256SUMS ) || { echo "  ÉCHEC  sommes de contrôle invalides, restauration annulée" >&2; exit 1; }
ok "sommes de contrôle vérifiées"
expected_items=$(sed -n 's/.*"items":\([0-9]*\).*/\1/p' "$dir/manifest.json")
expected_files=$(sed -n 's/.*"fichiers_uploads":\([0-9]*\).*/\1/p' "$dir/manifest.json")

if [ "${FORCE:-}" != 1 ]; then
  read -r -p "  La base et les uploads actuels seront REMPLACÉS. Continuer ? [oui/non] " answer < /dev/tty
  [ "$answer" = oui ] || { echo "  Annulé"; exit 1; }
fi

start=$(date +%s)
compose stop app rapport > /dev/null 2>&1 || true
ok "app et rapport arrêtés (pas d'écriture pendant la restauration)"
gzip -dc "$dir/geststock.sql.gz" | db_root
ok "base restaurée : $(db_query 'SELECT count(*) FROM items') articles"
uploads_sh "find $UPLOADS -mindepth 1 -delete && tar --no-overwrite-dir -xzf - -C $UPLOADS" < "$dir/uploads.tar.gz"
ok "uploads restaurés : $(uploads_sh "find $UPLOADS -type f | wc -l" | tr -d ' ') fichier(s)"
compose up -d --wait app rapport > /dev/null 2>&1
ok "app et rapport redémarrés et healthy ($(( $(date +%s) - start ))s d'interruption)"

items=$(db_query 'SELECT count(*) FROM items')
files=$(uploads_sh "find $UPLOADS -type f | wc -l" | tr -d ' ')
[ "$items" = "$expected_items" ] && ok "articles : $items = manifeste" || ko "articles : $items au lieu de $expected_items"
[ "$files" = "$expected_files" ] && ok "fichiers uploads : $files = manifeste" || ko "fichiers : $files au lieu de $expected_files"
[ "$FAILURES" -eq 0 ] || exit 1
echo "== Restauration terminée"
