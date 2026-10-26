#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

CI_PASSWORD=${CI_PASSWORD:-ci-push-2024}
DEV_PASSWORD=${DEV_PASSWORD:-dev-pull-2024}

mkdir -p certs auth
if [ ! -f certs/ca.key ]; then
  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout certs/ca.key -out certs/ca.crt -subj "/O=Shop SAS/CN=Shop SAS Internal CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
fi
openssl req -newkey rsa:2048 -nodes -keyout certs/registry.key -out certs/registry.csr -subj "/O=Shop SAS/CN=registry.local"
openssl x509 -req -in certs/registry.csr -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial \
  -out certs/registry.crt -days 825 -sha256 -extfile <(printf '%s\n' \
    "subjectAltName=DNS:registry.local,DNS:localhost,IP:127.0.0.1" \
    "basicConstraints=CA:FALSE" \
    "keyUsage=critical,digitalSignature,keyEncipherment" \
    "extendedKeyUsage=serverAuth")
rm -f certs/registry.csr
chmod 600 certs/*.key

{ htpasswd -nbB -C 10 ci "$CI_PASSWORD"; htpasswd -nbB -C 10 dev "$DEV_PASSWORD"; } | grep -v "^$" > auth/htpasswd

[ -f .env ] || printf 'REGISTRY_HTTP_SECRET=%s\n' "$(openssl rand -hex 32)" > .env
