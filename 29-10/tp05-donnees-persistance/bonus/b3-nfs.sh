#!/usr/bin/env bash
set -euo pipefail

NETWORK=tp05-nfs
SERVER=tp05-nfs-server
SERVER_IMAGE=itsthenetwork/nfs-server-alpine:12@sha256:7fa99ae65c23c5af87dd4300e543a86b119ed15ba61422444207efc7abd0ba20
PG16=postgres:16.4-alpine@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c
ACTION=${1:-run}

ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }

down() {
  docker rm -f tp05-pg-local tp05-pg-nfs "$SERVER" > /dev/null 2>&1 || true
  docker volume rm tp05-nfs-vol tp05-local-vol tp05-nfs-export > /dev/null 2>&1 || true
  docker network rm "$NETWORK" > /dev/null 2>&1 || true
}

if [ "$ACTION" = down ]; then
  down
  echo "ressources tp05-nfs supprimées"
  exit 0
fi

docker network inspect "$NETWORK" > /dev/null 2>&1 || docker network create --label tp05=nfs "$NETWORK" > /dev/null
docker volume create --label tp05=nfs tp05-nfs-export > /dev/null
if [ -z "$(docker ps -q --filter "name=^$SERVER$")" ]; then
  docker rm -f "$SERVER" > /dev/null 2>&1 || true
  docker run -d --name "$SERVER" --label tp05=nfs --network "$NETWORK" --privileged \
    -e SHARED_DIRECTORY=/nfsshare -v tp05-nfs-export:/nfsshare "$SERVER_IMAGE" > /dev/null
  sleep 5
fi
ip=$(docker inspect "$SERVER" --format "{{(index .NetworkSettings.Networks \"$NETWORK\").IPAddress}}")

docker volume inspect tp05-nfs-vol > /dev/null 2>&1 || docker volume create --label tp05=nfs --driver local \
  --opt type=nfs --opt "o=addr=$ip,rw,nfsvers=4" --opt device=:/ tp05-nfs-vol > /dev/null
docker volume create --label tp05=nfs tp05-local-vol > /dev/null

echo "\$ docker volume create --driver local --opt type=nfs --opt o=addr=$ip,rw,nfsvers=4 --opt device=:/ tp05-nfs-vol"
echo "options : $(docker volume inspect tp05-nfs-vol --format '{{json .Options}}')"
docker run --rm -v tp05-nfs-vol:/data alpine:3.20 sh -c 'echo "écrit par le conteneur A" > /data/partage.txt'
echo "lu par le conteneur B : $(docker run --rm -v tp05-nfs-vol:/data:ro alpine:3.20 cat /data/partage.txt)"
echo

bench() {
  local name=$1 volume=$2 start end
  docker rm -f "$name" > /dev/null 2>&1 || true
  docker run -d --name "$name" --label tp05=nfs -e POSTGRES_PASSWORD=x -e PGDATA=/data/pg -v "$volume:/data" "$PG16" > /dev/null
  for _ in $(seq 60); do docker exec "$name" pg_isready -h 127.0.0.1 -U postgres -q 2>/dev/null && break; sleep 1; done
  start=$(ms)
  docker exec "$name" psql -U postgres -qc "CREATE TABLE IF NOT EXISTS t (id serial PRIMARY KEY, v text); INSERT INTO t (v) SELECT md5(g::text) FROM generate_series(1, 100000) g; CHECKPOINT;"
  end=$(ms)
  printf '%-16s %-16s 100000 lignes + CHECKPOINT : %5d ms   système de fichiers : %s\n' "$name" "$volume" $((end - start)) \
    "$(docker exec "$name" awk '$2 == "/data" {print $3}' /proc/mounts)"
  docker stop "$name" > /dev/null
}

bench tp05-pg-local tp05-local-vol
bench tp05-pg-nfs tp05-nfs-vol
echo
echo "fichiers PostgreSQL côté serveur NFS : $(docker run --rm -v tp05-nfs-export:/export:ro alpine:3.20 sh -c 'ls /export/pg | head -4 | paste -sd" " -')"
