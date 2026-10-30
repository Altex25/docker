#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
BASE_URL=${BASE_URL:-http://localhost}
APP_HOST=${APP_HOST:-geststock.localhost}
MAIL_HOST=${MAIL_HOST:-mail.localhost}
CHECK_MAIL=${CHECK_MAIL:-1}
get() { curl -sS -m 5 -H "Host: $APP_HOST" "$@"; }

echo "== Smoke test : $BASE_URL (Host: $APP_HOST)"
health=$(get "$BASE_URL/?health" || true)
[ "$health" = OK ] && ok "?health : OK" || ko "?health : ${health:-pas de réponse}"

page=$(get "$BASE_URL/" || true)
before=$(sed -n 's/.*inventaire (\([0-9]*\) articles).*/\1/p' <<<"$page")
[ -n "$before" ] && ok "page d'accueil : $before articles, $(grep -o 'PHP [0-9.]*' <<<"$page")" || ko "page d'accueil illisible"
headers=$(get -D - -o /dev/null "$BASE_URL/")
grep -qi '^x-powered-by' <<<"$headers" && ko "X-Powered-By exposé" || ok "pas d'en-tête X-Powered-By, Server : $(tr -d '\r' <<<"$headers" | sed -n 's/^[Ss]erver: //p')"

tmp=$(mktemp -d)
printf '\x89PNG\r\n\x1a\nsmoke-%s' "$(date +%s%N)" > "$tmp/photo.png"
name="smoke-test-$(date +%s)"
code=$(get -o /dev/null -w '%{http_code}' -F "name=$name" -F qty=2 -F "photo=@$tmp/photo.png" "$BASE_URL/")
page=$(get "$BASE_URL/")
id=$(grep -o "<tr><td>[0-9]*</td><td>$name<" <<<"$page" | grep -o '[0-9]*' | head -1)
photo=$(grep -A1 "<td>$name</td>" <<<"$page" | grep -o 'uploads/p_[^"]*' | head -1)
[ "$code" = 200 ] && [ -n "$id" ] && ok "ajout d'un article avec photo : id $id" || ko "ajout d'article : HTTP $code"
if [ -n "$photo" ]; then
  get -o "$tmp/back.png" "$BASE_URL/$photo"
  cmp -s "$tmp/photo.png" "$tmp/back.png" && ok "photo relue à l'identique via /$photo" || ko "photo /$photo différente"
else
  ko "pas de photo affichée pour $name"
fi
code=$(get -o /dev/null -w '%{http_code}' "$BASE_URL/uploads/test.php")
[ "$code" = 403 ] || [ "$code" = 404 ] && ok "un .php dans /uploads n'est pas exécuté (HTTP $code)" || ko "/uploads/test.php : HTTP $code"
code=$(get -o /dev/null -w '%{http_code}' "$BASE_URL/../lib/config.php")
[ "$code" != 200 ] && ok "lib/config.php inaccessible (HTTP $code)" || ko "lib/config.php accessible"
rm -rf "$tmp"

if [ "$CHECK_MAIL" = 1 ]; then
  out=$(compose exec -T rapport rapport-maintenant 2>&1) && rc=0 || rc=$?
  [ "$rc" = 0 ] && ok "rapport à la demande : $(grep -m1 '^Articles' <<<"$out")" || ko "rapport : code $rc"
  sleep 1
  subject=$(curl -sS -m 5 -H "Host: $MAIL_HOST" "$BASE_URL/api/v1/messages?limit=1" | jq -r '.messages[0].Subject // empty')
  [ "$subject" = "Rapport stock $(date +%Y-%m-%d)" ] && ok "mail reçu par Mailpit : $subject" || ko "mail non reçu (dernier sujet : ${subject:-aucun})"
fi

if [ -n "$id" ]; then
  get -o /dev/null "$BASE_URL/?delete=$id"
  get "$BASE_URL/" | grep -q "<td>$name</td>" && ko "article $id non supprimé" || ok "article de test $id supprimé"
fi
[ "$FAILURES" -eq 0 ] || { echo "== ÉCHEC : $FAILURES vérification(s)"; exit 1; }
echo "== OK"
