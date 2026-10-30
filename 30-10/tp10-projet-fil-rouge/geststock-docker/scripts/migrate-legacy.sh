#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
DUMP=${1:?usage: migrate-legacy.sh DUMP.sql UPLOADS.tar.gz}
ARCHIVE=${2:?usage: migrate-legacy.sh DUMP.sql UPLOADS.tar.gz}
STRICT=${STRICT:-0}

echo "== Migration du legacy : $DUMP + $ARCHIVE ($COMPOSE)"
sums=$(dirname "$DUMP")/SHA256SUMS
if [ -f "$sums" ]; then
  ( cd "$(dirname "$DUMP")" && sha_list -c --quiet SHA256SUMS ) || { echo "  ÉCHEC  export corrompu (SHA256SUMS)" >&2; exit 1; }
  ok "export du legacy intègre (SHA256SUMS)"
fi
grep -q 'CREATE TABLE `items`' "$DUMP" || { echo "  ÉCHEC  $DUMP ne contient pas la table items" >&2; exit 1; }
source_version=$(sed -n 's/^-- Server version[[:space:]]*//p' "$DUMP")
dump_rows=$(grep '^INSERT INTO `items`' "$DUMP" | sed 's/),(/\n/g' | wc -l | tr -d ' ')
ok "dump de MariaDB $source_version : $dump_rows lignes dans items"

if [ "${SKIP_BACKUP:-0}" != 1 ]; then
  ./scripts/backup.sh | sed 's/^/   /'
fi

compose stop app rapport > /dev/null 2>&1 || true
ok "app et rapport arrêtés pendant la bascule"
db_root < "$DUMP"
ok "dump importé dans MariaDB $(db_query 'SELECT version()')"
uploads_sh "tar --no-overwrite-dir -xzf - -C $UPLOADS" < "$ARCHIVE"
ok "uploads copiés dans le volume ($(uploads_sh "find $UPLOADS -type f | wc -l" | tr -d ' ') fichiers)"
compose up -d --wait app rapport > /dev/null 2>&1
ok "app et rapport redémarrés"

echo "-- Vérifications"
items=$(db_query 'SELECT count(*) FROM items')
[ "$items" = "$dump_rows" ] && ok "articles : $items en base = $dump_rows dans le dump" || ko "articles : $items en base, $dump_rows dans le dump"
charset=$(db_query "SELECT CONCAT(table_collation) FROM information_schema.tables WHERE table_schema='geststock' AND table_name='items'")
ok "collation de la table conservée : $charset"
accents=$(db_query "SELECT name FROM items WHERE name LIKE 'Écrou%' LIMIT 1")
[ -z "$accents" ] || ok "texte non ASCII intact : $accents"

refs=$(db_query 'SELECT photo FROM items WHERE photo IS NOT NULL' | LC_ALL=C sort -u)
files=$(uploads_sh "cd $UPLOADS && find . -type f | sed 's|^\./||'" | LC_ALL=C sort -u)
missing=$(comm -23 <(echo "$refs") <(echo "$files") | sed '/^$/d')
orphans=$(comm -13 <(echo "$refs") <(echo "$files") | sed '/^$/d')
nref=$(sed '/^$/d' <<<"$refs" | wc -l | tr -d ' ')
if [ -z "$missing" ]; then ok "les $nref photos référencées sont présentes"
else
  warn "$(wc -l <<<"$missing" | tr -d ' ') photo(s) référencée(s) absente(s) de l'export (déjà perdues sur le legacy) :"
  sed 's/^/             /' <<<"$missing"
  [ "$STRICT" = 1 ] && ko "STRICT=1 : photos manquantes"
fi
if [ -n "$orphans" ]; then
  warn "$(wc -l <<<"$orphans" | tr -d ' ') fichier(s) sans article (conservés, à trier) :"
  sed 's/^/             /' <<<"$orphans"
fi

tmp=$(mktemp -d)
tar -xzf "$ARCHIVE" -C "$tmp"
want=$( (cd "$tmp" && find . -type f | LC_ALL=C sort | xargs "${SHA256[@]}") | cut -c1-64 | sha_list | cut -c1-16)
rm -rf "$tmp"
got=$(uploads_sh "cd $UPLOADS && find . -type f | LC_ALL=C sort | xargs sha256sum" | cut -c1-64 | sha_list | cut -c1-16)
[ "$want" = "$got" ] && ok "contenu des photos identique à l'export (empreinte $got)" || ko "photos différentes de l'export ($got / $want)"
ref=$(head -1 <<<"$(comm -12 <(echo "$refs") <(echo "$files"))")
code=$(compose exec -T app curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080/uploads/$ref")
[ "$code" = 200 ] && ok "photo migrée servie par Apache : /uploads/$ref (HTTP 200)" || ko "/uploads/$ref : HTTP $code"
[ "$FAILURES" -eq 0 ] || { echo "== ÉCHEC de la migration"; exit 1; }
echo "== Migration terminée : $items articles, $nref photos référencées"
