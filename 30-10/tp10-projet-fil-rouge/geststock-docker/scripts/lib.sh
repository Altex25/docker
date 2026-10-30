COMPOSE=${COMPOSE:-docker compose}
UPLOADS=/var/www/html/uploads

compose() { $COMPOSE "$@"; }
db_root() {
  compose exec -T db sh -c 'MYSQL_PWD="$(cat /run/secrets/db_root_password)" exec mariadb -uroot --default-character-set=utf8mb4 "$@"' sh "$@"
}
db_dump() {
  compose exec -T db sh -c 'MYSQL_PWD="$(cat /run/secrets/db_root_password)" exec mariadb-dump -uroot --default-character-set=utf8mb4 --single-transaction --routines --events --triggers --databases geststock'
}
db_query() { db_root -N -B geststock -e "$1"; }
uploads_sh() { compose run --rm --no-deps -T --entrypoint sh app -c "$1"; }
if type -P sha256sum > /dev/null; then SHA256=(sha256sum); else SHA256=(shasum -a 256); fi
sha_list() { "${SHA256[@]}" "$@"; }
ok() { printf '  OK     %s\n' "$*"; }
warn() { printf '  ATTENTION %s\n' "$*"; }
ko() { printf '  ÉCHEC  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
FAILURES=0
