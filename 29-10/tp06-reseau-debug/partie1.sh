#!/usr/bin/env bash
set -uo pipefail

ALPINE=alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
NETSHOOT=nicolaka/netshoot:v0.14@sha256:7f08c4aff13ff61a35d30e30c5c1ea8396eac6ab4ce19fd02d5a4b3b5d0d09a2
NGINX=nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
LABEL=tp06=partie1

run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; printf '[code retour %s]\n' "$?"; }
cleanup() {
  docker rm -f tp06-a tp06-b tp06-web tp06-internal tp06-none tp06-host > /dev/null 2>&1
  docker network rm demo tp06-internal > /dev/null 2>&1
}

if [ "${1:-}" = down ]; then cleanup; exit 0; fi
cleanup

echo "== Réseaux présents et bridge par défaut"
run docker network ls --filter driver=bridge --filter name=^bridge$ --format '{{.Name}} {{.Driver}} {{.Scope}}'
run docker network inspect bridge --format 'sous-réseau={{(index .IPAM.Config 0).Subnet}} passerelle={{(index .IPAM.Config 0).Gateway}} icc={{index .Options "com.docker.network.bridge.enable_icc"}}'

echo
echo "== Bridge par défaut : pas de DNS entre conteneurs"
run docker run -d --name a --label "$LABEL" "$ALPINE" sleep 1d
docker run -d --name tp06-a --label "$LABEL" "$ALPINE" sleep 1d > /dev/null
docker run -d --name tp06-b --label "$LABEL" "$ALPINE" sleep 1d > /dev/null
run docker exec tp06-a ping -c1 -W2 tp06-b
ip_b=$(docker inspect tp06-b --format '{{.NetworkSettings.Networks.bridge.IPAddress}}')
run docker exec tp06-a ping -c1 -W2 "$ip_b"
run docker exec tp06-a cat /etc/resolv.conf

echo
echo "== Réseau utilisateur : DNS embarqué 127.0.0.11"
docker network create --label "$LABEL" demo > /dev/null
docker network connect demo tp06-a
docker network connect --alias bravo demo tp06-b
run docker exec tp06-a ping -c1 -W2 tp06-b
run docker exec tp06-a ping -c1 -W2 bravo
run docker exec tp06-a cat /etc/resolv.conf
run docker exec tp06-a nslookup tp06-b 127.0.0.11
run docker exec tp06-a getent hosts bravo

echo
echo "== container: partage de la pile réseau de tp06-a"
run docker run --rm --network container:tp06-a "$NETSHOOT" ip -br addr
docker exec -d tp06-a nc -lk -p 9999 -e cat
sleep 1
run docker run --rm --network container:tp06-a "$NETSHOOT" ss -tlnp

echo
echo "== internal: pas de sortie vers l'extérieur et pas de publication"
docker network create --internal --label "$LABEL" tp06-internal > /dev/null
docker run -d --name tp06-internal --label "$LABEL" --network tp06-internal "$ALPINE" sleep 1d > /dev/null
run docker exec tp06-internal wget -q -T3 -O /dev/null http://example.com
run docker exec tp06-a wget -q -T3 -O /dev/null http://example.com
run docker run -d --name tp06-web --label "$LABEL" --network tp06-internal -p 18081:80 "$NGINX"
sleep 2
run docker port tp06-web
run curl -s -m3 -o /dev/null -w '%{http_code}\n' http://localhost:18081/
docker rm -f tp06-web > /dev/null

echo
echo "== none et host"
run docker run --rm --name tp06-none --network none "$ALPINE" ip -o addr
run docker run --rm --name tp06-host --network host "$ALPINE" sh -c 'ip -o -4 addr; hostname'

echo
echo "== -p = DNAT côté hôte, expose n'ouvre rien"
docker run -d --name tp06-web --label "$LABEL" --expose 80 "$NGINX" > /dev/null
sleep 1
run docker port tp06-web
run docker inspect tp06-web --format 'ExposedPorts={{json .Config.ExposedPorts}} PortBindings={{json .HostConfig.PortBindings}}'
docker rm -f tp06-web > /dev/null
docker run -d --name tp06-web --label "$LABEL" -p 18081:80 "$NGINX" > /dev/null
sleep 2
run docker port tp06-web
run curl -s -m3 -o /dev/null -w '%{http_code}\n' http://localhost:18081/
web_ip=$(docker inspect tp06-web --format '{{.NetworkSettings.Networks.bridge.IPAddress}}')
printf '\n$ colima ssh -- sudo iptables -t nat -S DOCKER | grep 18081\n'
colima ssh -- sudo iptables -t nat -S DOCKER 2>/dev/null | grep 18081 || colima ssh -- sudo iptables-legacy -t nat -S DOCKER 2>/dev/null | grep 18081
printf '\n$ colima ssh -- sudo nft list ruleset | grep 18081\n'
colima ssh -- sudo nft list ruleset 2>/dev/null | grep -E "18081|$web_ip" | head -5
echo "ip du conteneur tp06-web : $web_ip"

cleanup
echo
echo "== nettoyage : conteneurs tp06-* et réseaux demo, tp06-internal supprimés"
