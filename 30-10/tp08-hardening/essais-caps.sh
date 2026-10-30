#!/usr/bin/env bash
set -uo pipefail

PG=postgres:16.4-alpine@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c
TRAEFIK=traefik:v3.6.25@sha256:31267173a15b4944e797a76ffd9c419707c8d8b32fe5b610f80cd0cfa05f372d

caps() { local c; for c in ${1//,/ }; do printf -- '--cap-add %s ' "$c"; done; }
verdict() {
  local name=$1 pattern=$2 ok=$3
  printf '  %-9s exit=%-4s %s\n' "$(docker inspect "$name" --format '{{.State.Status}}')" "$(docker inspect "$name" --format '{{.State.ExitCode}}')" \
    "$(docker logs "$name" 2>&1 | grep -iE "$pattern" | grep -v -iE "$ok" | tail -2 | tr '\n' ' ' | cut -c1-230)"
  docker logs "$name" 2>&1 | grep -iE "$ok" | tail -1 | cut -c1-120 | sed 's/^/            -> /'
}

pg() {
  local set=$1 volume=$2 user=${3:-}
  docker rm -f tp08-pg > /dev/null 2>&1
  printf '\n[cap_add: %s]%s\n' "${set:-aucune}" "${user:+ [user: $user]}"
  docker run -d --name tp08-pg --cap-drop ALL $(caps "$set") ${user:+--user "$user"} --read-only \
    --tmpfs /var/run/postgresql:uid=70,gid=70 --tmpfs /tmp \
    -e POSTGRES_PASSWORD=x -v "$volume:/var/lib/postgresql/data" "$PG" > /dev/null
  sleep 7
  verdict tp08-pg 'not permitted|denied|error|fatal' 'ready to accept connections'
}

echo "== PostgreSQL, image par défaut (entrypoint root puis su-exec postgres), volume neuf"
for set in "" CHOWN CHOWN,SETUID,SETGID CHOWN,SETUID,SETGID,FOWNER CHOWN,SETUID,SETGID,FOWNER,DAC_OVERRIDE; do
  docker volume rm tp08-pgdata > /dev/null 2>&1
  pg "$set" tp08-pgdata
done

echo
echo "== PostgreSQL, volume existant (données déjà à 70:70) : redémarrage avec le jeu minimal trouvé"
pg CHOWN,SETUID,SETGID,FOWNER,DAC_OVERRIDE tp08-pgdata
pg CHOWN,SETUID,SETGID tp08-pgdata
pg CHOWN,SETUID,SETGID,DAC_OVERRIDE tp08-pgdata

echo
echo "== PostgreSQL lancé directement en 70:70 (pas d'étape root), volume existant"
pg "" tp08-pgdata 70:70
docker rm -f tp08-pg > /dev/null 2>&1
docker volume rm tp08-pgdata > /dev/null 2>&1

traefik() {
  local set=$1 user=${2:-} extra=${3:-}
  docker rm -f tp08-traefik > /dev/null 2>&1
  printf '\n[cap_add: %s]%s%s\n' "${set:-aucune}" "${user:+ [user: $user]}" "${extra:+ [$extra]}"
  docker run -d --name tp08-traefik --cap-drop ALL $(caps "$set") ${user:+--user "$user"} ${extra:+--sysctl "$extra"} --read-only \
    "$TRAEFIK" --entrypoints.web.address=:80 --ping=true --log.level=INFO --log.nocolor=true > /dev/null
  sleep 4
  verdict tp08-traefik 'permission denied|not permitted|error' 'Starting provider \\*traefik|Configuration loaded'
  echo "            healthcheck --ping : $(docker exec tp08-traefik traefik healthcheck --ping 2>&1 | tail -1)"
}

echo
echo "== Traefik, écoute sur :80 dans le conteneur"
printf '\n$ docker run --rm --cap-drop ALL alpine cat /proc/sys/net/ipv4/ip_unprivileged_port_start\n'
docker run --rm --cap-drop ALL alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc cat /proc/sys/net/ipv4/ip_unprivileged_port_start
traefik ""
echo
echo "== Même chose avec le seuil historique (sysctl net.ipv4.ip_unprivileged_port_start=1024)"
traefik "" "" net.ipv4.ip_unprivileged_port_start=1024
traefik NET_BIND_SERVICE "" net.ipv4.ip_unprivileged_port_start=1024
traefik NET_BIND_SERVICE 65534:65534 net.ipv4.ip_unprivileged_port_start=1024
traefik "" 65534:65534
docker rm -f tp08-traefik > /dev/null 2>&1
