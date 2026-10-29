#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

DIR=backups/offsite
NETWORK=tp05-s3
GARAGE=tp05-garage
GARAGE_IMAGE=dxflrs/garage:v2.1.0@sha256:4c9b34c113e61358466e83fd6e7d66e6d18657ede14b776eb78a93ee8da7cf6a
RCLONE_IMAGE=rclone/rclone:1.75.1@sha256:45401ad7410db1d67ffdb58e19059ad20b0d8e0285a60e38bbec55cc1019c7a5
BUCKET=pg-backups
DUMP=${1:-$(ls -1t backups/*.dump | head -1)}
NAME=$(basename "$DUMP")

mkdir -p "$DIR"
docker build -q -t tp05-age bonus/age > /dev/null
age() { docker run --rm -v "$PWD/backups:/work/backups" tp05-age "$@"; }

if [ ! -f "$DIR/age.key" ]; then
  age age-keygen -o "$DIR/age.key" 2>/dev/null
  chmod 600 "$DIR/age.key"
fi
recipient=$(grep -m1 'public key' "$DIR/age.key" | awk '{print $NF}')
echo "== Chiffrement de $NAME pour $recipient"
age age -r "$recipient" -o "$DIR/$NAME.age" "$DUMP"
echo "clair : $(du -h "$DUMP" | cut -f1)  chiffré : $(du -h "$DIR/$NAME.age" | cut -f1)  en-tête : $(head -c 21 "$DIR/$NAME.age")"

if [ -z "$(docker ps -q --filter name=^$GARAGE$)" ]; then
  echo "== Démarrage de Garage (S3 compatible) sur le réseau $NETWORK"
  docker network inspect "$NETWORK" > /dev/null 2>&1 || docker network create --label tp05=s3 "$NETWORK" > /dev/null
  docker volume create --label tp05=s3 "$GARAGE" > /dev/null
  [ -f "$DIR/garage.toml" ] || cat > "$DIR/garage.toml" <<TOML
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "sqlite"
replication_factor = 1
rpc_bind_addr = "[::]:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "$(openssl rand -hex 32)"

[s3_api]
s3_region = "garage"
api_bind_addr = "[::]:3900"
root_domain = ".s3.garage.localhost"
TOML
  docker run -d --name "$GARAGE" --network "$NETWORK" --label tp05=s3 \
    -v "$PWD/$DIR/garage.toml:/etc/garage.toml:ro" -v "$GARAGE:/var/lib/garage" "$GARAGE_IMAGE" > /dev/null
  sleep 3
fi
garage() { docker exec "$GARAGE" /garage "$@" 2>/dev/null; }

if ! garage bucket info "$BUCKET" > /dev/null 2>&1; then
  node=$(garage status 2>/dev/null | awk '/HEALTHY NODES/{f=1; next} f && $1 ~ /^[0-9a-f]+$/ {print $1; exit}')
  garage layout assign -z local -c 1G "$node" > /dev/null
  garage layout apply --version 1 > /dev/null
  garage bucket create "$BUCKET" > /dev/null
  garage key create tp05-backup > /dev/null
  garage bucket allow --read --write "$BUCKET" --key tp05-backup > /dev/null
fi
key_id=$(garage key info tp05-backup --show-secret | awk -F': *' '/Key ID/ {print $2; exit}')
secret=$(garage key info tp05-backup --show-secret | awk -F': *' '/Secret key/ {print $2; exit}')

rclone() {
  docker run --rm --network "$NETWORK" -v "$PWD/backups:/backups" \
    -e RCLONE_CONFIG_S3_TYPE=s3 -e RCLONE_CONFIG_S3_PROVIDER=Other -e RCLONE_CONFIG_S3_REGION=garage \
    -e RCLONE_CONFIG_S3_ENDPOINT="http://$GARAGE:3900" -e RCLONE_CONFIG_S3_FORCE_PATH_STYLE=true \
    -e RCLONE_CONFIG_S3_ACCESS_KEY_ID="$key_id" -e RCLONE_CONFIG_S3_SECRET_ACCESS_KEY="$secret" \
    "$RCLONE_IMAGE" -q "$@"
}

echo "== Envoi vers s3://$BUCKET"
rclone copyto "/backups/offsite/$NAME.age" "s3:$BUCKET/$NAME.age"
rclone ls "s3:$BUCKET"

echo "== Vérification : téléchargement, déchiffrement, sha256"
rclone copyto "s3:$BUCKET/$NAME.age" "/backups/offsite/verif-$NAME.age"
age age -d -i "backups/offsite/age.key" -o "backups/offsite/verif-$NAME" "backups/offsite/verif-$NAME.age"
original=$(shasum -a 256 "$DUMP" | awk '{print $1}')
restored=$(shasum -a 256 "$DIR/verif-$NAME" | awk '{print $1}')
echo "sha256 original : $original"
echo "sha256 restauré : $restored"
rm -f "$DIR/verif-$NAME" "$DIR/verif-$NAME.age"
[ "$original" = "$restored" ] && echo "== OK" || { echo "== KO" >&2; exit 1; }
