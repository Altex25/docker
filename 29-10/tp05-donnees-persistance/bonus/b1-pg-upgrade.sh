#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=${1:---link}
SOURCE=${SOURCE:-shopdata_pgdata}
WORK=tp05-upg-${MODE#--}
IMAGE=tp05-pg-upgrade
PG16=postgres:16.4-alpine@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c
CHECKSUM_SQL="SELECT count(*) || ' commandes, md5 ' || md5(string_agg(id::text || status, ',' ORDER BY id)) FROM orders"

ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }
cleanup() { docker rm -f "$WORK-check" > /dev/null 2>&1 || true; docker volume rm "$WORK" > /dev/null 2>&1 || true; }
trap cleanup EXIT

docker build -q -t "$IMAGE" bonus/pg-upgrade > /dev/null
cleanup
docker volume create --label tp05=upgrade "$WORK" > /dev/null

echo "== Copie de $SOURCE vers $WORK/14/data (la copie n'entre pas dans la mesure)"
docker run --rm -v "$SOURCE:/from:ro" -v "$WORK:/to" alpine:3.20 sh -c 'mkdir -p /to/14/data /to/16 && cp -a /from/. /to/14/data/ && chown -R 70:70 /to'
echo "taille : $(docker run --rm -v "$WORK:/to:ro" alpine:3.20 du -sh /to/14/data | cut -f1)"

echo "== initdb PostgreSQL 16 (même superutilisateur, encodage et locale)"
docker run --rm -v "$WORK:/var/lib/postgresql" --entrypoint /usr/libexec/postgresql16/initdb "$IMAGE" \
  -D /var/lib/postgresql/16/data -U shop -E UTF8 --locale=en_US.utf8 > /dev/null

echo "== pg_upgrade --check"
docker run --rm -v "$WORK:/var/lib/postgresql" "$IMAGE" --check | grep -E 'Clusters are compatible|fatal|mismatch' || true

echo "== pg_upgrade $MODE"
start=$(ms)
docker run --rm -v "$WORK:/var/lib/postgresql" "$IMAGE" "$MODE" | grep -E 'Upgrade Complete|Linking|Copying|fatal' | sed 's/  */ /g' | head -3
end=$(ms)
echo "durée pg_upgrade $MODE : $((end - start)) ms (démarrage du conteneur compris)"
echo "fichiers liés (nombre de liens > 1) : $(docker run --rm -v "$WORK:/v:ro" alpine:3.20 sh -c 'find /v/16/data/base -type f -links +1 | wc -l')"

docker run --rm -v "$WORK:/v" alpine:3.20 sh -c 'cp /v/14/data/pg_hba.conf /v/14/data/postgresql.conf /v/16/data/ && chown 70:70 /v/16/data/pg_hba.conf /v/16/data/postgresql.conf'

echo "== Démarrage de $PG16 sur le cluster mis à niveau"
docker run -d --name "$WORK-check" -v "$WORK:/var/lib/postgresql" -e PGDATA=/var/lib/postgresql/16/data "$PG16" > /dev/null
for i in $(seq 30); do docker exec "$WORK-check" pg_isready -U shop -q 2>/dev/null && break; sleep 1; done
echo "version   : $(docker exec "$WORK-check" psql -U shop -d shop -tAc 'SHOW server_version')"
echo "empreinte : $(docker exec "$WORK-check" psql -U shop -d shop -tAc "$CHECKSUM_SQL")"
