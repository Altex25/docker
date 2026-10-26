#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
CI_PASSWORD=${CI_PASSWORD:-ci-push-2024}
DEV_PASSWORD=${DEV_PASSWORD:-dev-pull-2024}
C() { docker run --rm --network host --add-host registry.local:127.0.0.1 -v "$PWD/certs/ca.crt:/ca.crt:ro" curlimages/curl:8.11.1 -sS "$@"; }
now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }

mirror_requests() {
  docker compose logs mirror --since "$1" --no-log-prefix 2>&1 | grep -E '^[0-9.]+ - - ' | grep -v referrers \
    | sed -E 's#.*"(GET|HEAD) /v2/library/[^/]+/([a-z]+)/([^? ]+)[^"]*" ([0-9]+) ([0-9]+).*#    \1 \2 \3 HTTP \4 \5#' \
    | awk '{ ref = $3; if (ref ~ /^sha256:/) ref = substr(ref, 1, 19) "…"; printf "    %-4s %-9s %-21s HTTP %s %8.2f Mo\n", $1, $2, ref, $5, $6 / 1e6 }'
}

mirror_size() { colima ssh -- sudo du -sh /var/lib/docker/volumes/shop-registry_mirror-data/_data 2>/dev/null | cut -f1; }

pull_via_mirror() {
  local t s e before
  docker image rm "$1" >/dev/null 2>&1
  before=$(mirror_size)
  sleep 2; t=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  s=$(now); docker pull -q "$1" >/dev/null; e=$(now)
  sleep 1
  echo "  durée du pull : $(echo "$e - $s" | bc) s ; stockage du mirror : $before -> $(mirror_size) ; requêtes reçues :"
  mirror_requests "$t"
}

echo "\$ docker compose ps"; docker compose ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}'; echo
echo '$ curl -k https://registry.local:5000/v2/'; C -k -o /dev/null -D - https://registry.local:5000/v2/ | grep -iE '^(HTTP|www-authenticate)'
echo '$ curl --cacert ca.crt https://registry.local:5000/v2/'; C --cacert /ca.crt -o /dev/null -w 'HTTP %{http_code}, vérification TLS=%{ssl_verify_result} (0 = OK)\n' https://registry.local:5000/v2/
echo "\$ curl -u dev:$DEV_PASSWORD https://registry.local:5000/v2/_catalog"; C --cacert /ca.crt -u "dev:$DEV_PASSWORD" https://registry.local:5000/v2/_catalog; echo
echo '$ curl -u dev:mauvais https://registry.local:5000/v2/_catalog'; C --cacert /ca.crt -u dev:mauvais -o /dev/null -w 'HTTP %{http_code}\n' https://registry.local:5000/v2/_catalog
echo; echo '$ docker login registry.local:5000 -u ci --password-stdin'; echo "$CI_PASSWORD" | docker login registry.local:5000 -u ci --password-stdin 2>&1 | grep -v WARNING
echo '$ docker tag shopapi:1.4.2 registry.local:5000/shopapi:1.4.2 && docker push registry.local:5000/shopapi:1.4.2'
docker tag shopapi:1.4.2 registry.local:5000/shopapi:1.4.2 && docker push registry.local:5000/shopapi:1.4.2 2>&1 | tail -1
echo "\$ curl -u dev:$DEV_PASSWORD https://registry.local:5000/v2/_catalog"; C --cacert /ca.crt -u "dev:$DEV_PASSWORD" https://registry.local:5000/v2/_catalog; echo

echo; echo '# Mirror pull-through'
echo '$ docker info | grep -A1 "Registry Mirrors"'; docker info 2>/dev/null | grep -A1 'Registry Mirrors'
IMG=${MIRROR_TEST_IMAGE:-busybox:1.36.1}
echo "\$ docker pull $IMG   (1er pull : absent du mirror, récupéré sur Docker Hub)"; pull_via_mirror "$IMG"
echo "\$ docker image rm $IMG && docker pull $IMG   (2e pull : servi par le cache du mirror)"; pull_via_mirror "$IMG"
echo '$ curl http://localhost:5001/v2/_catalog'; docker run --rm --network host curlimages/curl:8.11.1 -sS http://localhost:5001/v2/_catalog; echo

echo; echo '# UI (http://localhost:8080)'
echo "\$ curl http://localhost:8080/ -> HTTP $(C -o /dev/null -w '%{http_code}' http://localhost:8080/)"
echo "\$ curl http://localhost:8080/v2/_catalog (sans identifiants) -> HTTP $(C -o /dev/null -w '%{http_code}' http://localhost:8080/v2/_catalog)"

echo; echo '# htpasswd ne gère pas les droits : dev peut pousser'
echo "$DEV_PASSWORD" | docker login registry.local:5000 -u dev --password-stdin >/dev/null 2>&1
docker tag shopapi:1.4.2 registry.local:5000/shopapi:dev-push-test
echo '$ docker login -u dev && docker push registry.local:5000/shopapi:dev-push-test'; docker push registry.local:5000/shopapi:dev-push-test 2>&1 | tail -1
echo "$CI_PASSWORD" | docker login registry.local:5000 -u ci --password-stdin >/dev/null 2>&1
docker image rm registry.local:5000/shopapi:dev-push-test >/dev/null
