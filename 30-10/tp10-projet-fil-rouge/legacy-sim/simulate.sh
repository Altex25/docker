#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
IMAGE=mariadb:10.3.39
NAME=tp10-legacy-db
PASS=GestStock2017!

docker rm -f "$NAME" > /dev/null 2>&1 || true
rm -rf export work && mkdir -p export work/uploads
docker run -d --name "$NAME" --label tp10=legacy -e MARIADB_ROOT_PASSWORD=legacy-root \
  -e MARIADB_DATABASE=geststock -e MARIADB_USER=geststock -e MARIADB_PASSWORD="$PASS" "$IMAGE" > /dev/null
for _ in $(seq 90); do
  docker logs "$NAME" 2>&1 | grep -q 'init process done' \
    && docker exec "$NAME" mysql -uroot -plegacy-root -e 'SELECT 1' > /dev/null 2>&1 && break
  sleep 1
done
sql() { docker exec -i "$NAME" mysql -uroot -plegacy-root --default-character-set=utf8mb4 geststock; }

sql < ../legacy-app/geststock/sql/schema.sql
{
  for i in $(seq 1 150); do
    qty=$(( (i * 37) % 120 ))
    if [ $((i % 4)) -eq 0 ]; then photo="'p_5f$(printf '%06d' "$i").$(( i * 7919 )).jpg'"; else photo=NULL; fi
    printf "INSERT INTO items(name, qty, photo, created_at) VALUES ('Article legacy n°%d', %d, %s, '2019-01-01' + INTERVAL %d DAY);\n" "$i" "$qty" "$photo" "$((i * 9))"
  done
  echo "INSERT INTO items(name, qty, photo) VALUES ('Écrou « spécial » ½ pouce — lot ☕', 4, 'p_5faccents.1.png');"
  echo "INSERT INTO items(name, qty, photo) VALUES ('Photo perdue depuis 2020', 1, 'p_5fperdue.1.jpg');"
} | sql

photos=$(docker exec "$NAME" mysql -uroot -plegacy-root -N -B -e "SELECT photo FROM geststock.items WHERE photo IS NOT NULL AND photo <> 'p_5fperdue.1.jpg'")
python3 photos.py work/uploads $photos p_orpheline.1.png
docker exec "$NAME" mysql -uroot -plegacy-root -N -e "SELECT version(), @@character_set_server, @@collation_server, (SELECT count(*) FROM geststock.items), (SELECT count(photo) FROM geststock.items)"

docker exec "$NAME" mysqldump -uroot -plegacy-root --single-transaction --databases geststock > export/geststock-legacy.sql
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf export/uploads.tar.gz -C work/uploads .
( cd export && shasum -a 256 geststock-legacy.sql uploads.tar.gz > SHA256SUMS )
ls -la export; echo "photos dans l'archive : $(tar -tzf export/uploads.tar.gz | grep -vc '/$')"
docker rm -f "$NAME" > /dev/null
rm -rf work
