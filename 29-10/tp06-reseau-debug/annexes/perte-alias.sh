#!/usr/bin/env bash
set -uo pipefail

dir=$(mktemp -d)
cd "$dir"
alpine=alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
write() {
  cat > compose.yml <<EOF
name: tp06-alias
services:
  db:
    image: $alpine
    command: sleep 1d
    networks: [back]
networks:
  back:
    internal: $1
EOF
}
names() { docker inspect tp06-alias-db-1 --format '{{range .NetworkSettings.Networks}}{{json .DNSNames}}{{end}}'; }

echo "$(docker compose version)"
write false
docker compose up -d > /dev/null 2>&1
echo "1. réseau back internal=false, DNSNames de db : $(names)"
write true
echo "2. compose.yml modifié : back passe en internal: true, puis docker compose up -d"
docker compose up -d 2>&1 | sed 's/^/   /'
echo "3. DNSNames de db : $(names)   <- l'alias de service \"db\" a disparu"
docker compose up -d --force-recreate > /dev/null 2>&1
echo "4. après --force-recreate : $(names)"
docker compose down > /dev/null 2>&1
rm -f "$dir/compose.yml" && rmdir "$dir"
