#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."

NETSHOOT=nicolaka/netshoot:v0.14@sha256:7f08c4aff13ff61a35d30e30c5c1ea8396eac6ab4ce19fd02d5a4b3b5d0d09a2
api=$(docker compose ps -q api | head -1)
name=$(docker inspect "$api" --format '{{.Name}}' | tr -d /)

docker rm -f tp06-tcpdump > /dev/null 2>&1
echo "\$ docker run --network container:$name nicolaka/netshoot tcpdump -i any -nn -A -s0 'tcp port 5432'"
docker run -d --name tp06-tcpdump --label tp06=b1 --network "container:$name" "$NETSHOOT" \
  timeout 20 tcpdump -i any -nn -l -A -s0 'tcp port 5432' > /dev/null
sleep 2

echo "pool pg inactif depuis plus de 10 s : la prochaine requête ouvre une nouvelle connexion"
sleep 11
docker compose exec -T redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli del products' > /dev/null
echo "\$ docker exec $name wget -qO- http://127.0.0.1:3000/products"
docker exec "$name" wget -qO- http://127.0.0.1:3000/products
echo
sleep 2
docker stop -t 1 tp06-tcpdump > /dev/null
dump=$(docker logs tp06-tcpdump 2>&1)
docker rm tp06-tcpdump > /dev/null

echo
echo "== Paquets capturés : $(grep -c ' IP ' <<< "$dump")"
echo
echo "== Démarrage de session (en clair) : utilisateur et base"
grep -a -o -E 'user.shop.database.shop[^.]*' <<< "$dump" | head -1
grep -a -o -E 'SCRAM-SHA-256' <<< "$dump" | head -1 | sed 's/^/mécanisme d'\''authentification : /'
echo
echo "== Requête SQL en clair (extrait brut de tcpdump)"
grep -a -B2 -m1 'SELECT id' <<< "$dump" | cut -c1-160
echo
echo "== Réponse en clair (lignes de la table products)"
grep -a -o -E '(Clavier m|Souris sans fil|cran 27)[^.]{0,20}' <<< "$dump" | head -3
echo
echo "== Chiffrement côté serveur"
echo "ssl = $(docker compose exec -T db psql -U shop -d shop -tAc 'SHOW ssl')"
docker compose exec -T db psql -U shop -d shop -tAc "SELECT 'connexions SSL actives : ' || count(*) FILTER (WHERE ssl) || ' / ' || count(*) FROM pg_stat_ssl JOIN pg_stat_activity USING (pid) WHERE backend_type = 'client backend'"
