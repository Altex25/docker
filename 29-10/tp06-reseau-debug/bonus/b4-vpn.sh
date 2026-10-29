#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

DIND=docker:28.5-dind@sha256:2a232a42256f70d78e3cc5d2b5d6b3276710a0de0596c145f627ecfae90282ac
INTRANET=172.18.5.10
VPN_ROUTE=172.16.0.0/12

cleanup() { docker rm -f -v tp06-dind > /dev/null 2>&1; }
if [ "${1:-}" = down ]; then cleanup; exit 0; fi

start() {
  cleanup
  docker run -d --name tp06-dind --label tp06=b4 --privileged -e DOCKER_TLS_CERTDIR= "$@" "$DIND" > /dev/null
  for _ in $(seq 30); do docker exec tp06-dind docker info > /dev/null 2>&1 && return 0; sleep 1; done
  echo "dockerd ne démarre pas" >&2; docker logs tp06-dind 2>&1 | tail -5; exit 1
}
d() { docker exec tp06-dind "$@"; }
vpn_up() {
  d ip link add vpn0 type dummy
  d ip addr add 10.8.0.2/24 dev vpn0
  d ip link set vpn0 up
  d ip route add "$VPN_ROUTE" dev vpn0
  echo "VPN connecté : route $VPN_ROUTE via vpn0 (serveur intranet $INTRANET)"
}
subnet() { d docker network inspect "$1" --format '{{(index .IPAM.Config 0).Subnet}}'; }
route() { echo "ip route get $INTRANET -> $(d ip route get "$INTRANET" | head -1 | sed -E 's/ +uid.*//')"; }

echo "== Contexte : bridges déjà présents dans la VM Colima"
docker network ls -q --filter driver=bridge | xargs docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' | sort -t. -k2,2n | paste -sd' ' -

echo
echo "== A. Pools par défaut : réseaux créés avant la connexion du VPN"
start
echo "docker0 : $(subnet bridge)"
for n in app1 app2; do d docker network create "$n" > /dev/null; echo "réseau $n : $(subnet "$n")"; done
route
vpn_up
route
echo "=> 172.18.0.0/16 (docker0) est plus spécifique que le /12 du VPN : le trafic vers l'intranet reste dans le bridge local"
d ip route | grep -E 'vpn0|br-|docker0'

echo
echo "== A'. Même daemon, VPN déjà connecté : création d'un nouveau réseau"
d docker network create app3 > /dev/null
echo "réseau app3 : $(subnet app3)"
route

echo
echo "== B. daemon.json : bip + default-address-pools hors des plages du VPN"
cat b4-vpn/daemon.json
start -v "$PWD/b4-vpn/daemon.json:/etc/docker/daemon.json:ro"
echo "docker0 : $(subnet bridge)"
for n in app1 app2 app3; do d docker network create "$n" > /dev/null; echo "réseau $n : $(subnet "$n")"; done
vpn_up
route
d ip route | grep -E 'vpn0|br-|docker0'

cleanup
echo
echo "== conteneur tp06-dind supprimé"
