#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

DIND=docker:28.5-dind@sha256:2a232a42256f70d78e3cc5d2b5d6b3276710a0de0596c145f627ecfae90282ac
ALPINE=alpine:3.20

cleanup() { docker rm -f -v tp08-dind > /dev/null 2>&1; docker volume rm tp08-dind-data > /dev/null 2>&1; }
start() {
  docker rm -f tp08-dind > /dev/null 2>&1
  docker run -d --name tp08-dind --label tp08=daemon --privileged -e DOCKER_TLS_CERTDIR= \
    -v tp08-dind-data:/var/lib/docker "$@" "$DIND" > /dev/null
  for _ in $(seq 40); do docker exec tp08-dind docker info > /dev/null 2>&1 && return 0; sleep 1; done
  echo "dockerd ne démarre pas" >&2; docker logs tp08-dind 2>&1 | tail -5; exit 1
}
d() { docker exec tp08-dind "$@"; }
run() { printf '\n$ %s\n' "$*"; d "$@" 2>&1; printf '[code retour %s]\n' "$?"; }

cleanup

echo "== Validation syntaxique par dockerd lui-même"
docker run --rm -v "$PWD/daemon.json:/etc/docker/daemon.json:ro" --entrypoint dockerd "$DIND" --validate --config-file /etc/docker/daemon.json

echo
echo "== Phase 1 : daemon par défaut, des données existent déjà"
start
d docker pull -q "$ALPINE" > /dev/null
d docker volume create donnees > /dev/null
d docker run --rm -v donnees:/d "$ALPINE" sh -c 'echo "écrit avant userns-remap" > /d/fichier'
echo "volumes : $(d docker volume ls -q | paste -sd' ' -), images : $(d docker images --format '{{.Repository}}:{{.Tag}}' | paste -sd' ' -)"
echo "propriétaire réel du fichier : $(d stat -c '%u:%g %n' /var/lib/docker/volumes/donnees/_data/fichier)"
echo "deux conteneurs sur le bridge par défaut (icc par défaut = true) :"
d docker run -d --name ct-a "$ALPINE" sleep 300 > /dev/null
ip=$(d docker inspect ct-a --format '{{.NetworkSettings.IPAddress}}')
echo "  ping $ip depuis un autre conteneur : $(d docker run --rm "$ALPINE" ping -c1 -W2 "$ip" > /dev/null 2>&1 && echo OK || echo ÉCHEC)"

echo
echo "== Phase 2 : même /var/lib/docker, daemon redémarré avec daemon.json"
start -v "$PWD/daemon.json:/etc/docker/daemon.json:ro"
d docker info --format 'SecurityOptions={{json .SecurityOptions}} LiveRestore={{.LiveRestoreEnabled}} LoggingDriver={{.LoggingDriver}} DockerRootDir={{.DockerRootDir}}'
echo "volumes : [$(d docker volume ls -q | paste -sd' ' -)], images : [$(d docker images -q | paste -sd' ' -)]"
run ls /var/lib/docker
run grep dockremap /etc/subuid /etc/subgid

d docker pull -q "$ALPINE" > /dev/null
echo
echo "root dans le conteneur = uid non privilégié sur l'hôte :"
d docker run -d --name ct-b "$ALPINE" sleep 300 > /dev/null
d docker exec ct-b id | sed 's/^/  dans le conteneur : /'
d sh -c 'ps -o user,pid,args | grep "sleep 300" | grep -v grep' | sed 's/^/  vu par l hôte : /'
d docker run --rm -v neuf:/d "$ALPINE" touch /d/x
echo "  nouveau volume, propriétaire réel : $(d sh -c 'stat -c "%u:%g %n" /var/lib/docker/*.*/volumes/neuf/_data/x')"
echo
echo "ancien volume (fichiers à 0:0) monté dans un conteneur remappé :"
run docker run --rm -v /var/lib/docker/volumes/donnees/_data:/d "$ALPINE" sh -c 'ls -ln /d; echo ajout >> /d/fichier'
echo
echo "no-new-privileges appliqué par défaut :"
run docker run --rm "$ALPINE" grep NoNewPrivs /proc/self/status
echo
echo "icc=false sur le bridge par défaut :"
d docker run -d --name ct-c "$ALPINE" sleep 300 > /dev/null
ip=$(d docker inspect ct-c --format '{{.NetworkSettings.IPAddress}}')
echo "  ping $ip depuis un autre conteneur (bridge par défaut) : $(d docker run --rm "$ALPINE" ping -c1 -W2 "$ip" > /dev/null 2>&1 && echo OK || echo ÉCHEC)"
d docker network create app > /dev/null
d docker run -d --name ct-e --network app "$ALPINE" sleep 300 > /dev/null
echo "  ping ct-e depuis un autre conteneur (réseau utilisateur app) : $(d docker run --rm --network app "$ALPINE" ping -c1 -W2 ct-e > /dev/null 2>&1 && echo OK || echo ÉCHEC)"
echo "  sous-réseau du réseau app : $(d docker network inspect app --format '{{(index .IPAM.Config 0).Subnet}}')"
echo
echo "conteneurs qui ont besoin de l'hôte (cAdvisor, docker-bench...) :"
run docker run --rm --privileged "$ALPINE" true
run docker run --rm --privileged --userns host "$ALPINE" true

cleanup
echo
echo "== conteneur tp08-dind et volume supprimés"
