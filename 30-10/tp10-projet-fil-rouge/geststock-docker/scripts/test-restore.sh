#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
dir=${1:-$(find "${BACKUP_DIR:-backups}" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | tail -1)}
[ -n "$dir" ] || { echo "aucune sauvegarde dans ${BACKUP_DIR:-backups}" >&2; exit 2; }
project=geststock-restoretest
export COMPOSE="docker compose -p $project -f compose.yml"
export REGISTRY=${TEST_REGISTRY:-local} VERSION=${TEST_VERSION:-dev}

echo "== Test de restauration de $dir dans le projet jetable $project"
trap 'compose down -v --remove-orphans > /dev/null 2>&1' EXIT
compose up -d --wait db app > /dev/null 2>&1
ok "stack vierge démarrée : $(db_query 'SELECT count(*) FROM items') articles (jeu initial de schema.sql)"
FORCE=1 ./scripts/restore.sh "$dir" | sed 's/^/   /'

got=$(uploads_sh "cd $UPLOADS && find . -type f | LC_ALL=C sort | xargs cat" | sha_list | cut -c1-16)
tmp=$(mktemp -d)
tar -xzf "$dir/uploads.tar.gz" -C "$tmp"
want=$( (cd "$tmp" && find . -type f | LC_ALL=C sort | xargs cat) | sha_list | cut -c1-16)
rm -rf "$tmp"
[ "$got" = "$want" ] && ok "contenu des uploads identique octet pour octet (empreinte $got)" || ko "contenu des uploads différent ($got / $want)"

page=$(compose exec -T app curl -fsS http://127.0.0.1:8080/)
health=$(compose exec -T app curl -fsS 'http://127.0.0.1:8080/?health')
[ "$health" = OK ] && ok "?health : OK" || ko "?health : $health"
h1=$(grep -o '<h1>[^<]*' <<<"$page" | sed 's/<h1>//')
ok "page servie par la stack restaurée : $h1"
photo=$(db_query "SELECT photo FROM items WHERE photo IS NOT NULL ORDER BY id LIMIT 1")
code=$(compose exec -T app curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080/uploads/$photo")
[ "$code" = 200 ] && ok "photo $photo servie (HTTP 200)" || ko "photo $photo : HTTP $code"
[ "$FAILURES" -eq 0 ] || { echo "== ÉCHEC du test de restauration"; exit 1; }
echo "== Restauration validée, projet $project supprimé"
