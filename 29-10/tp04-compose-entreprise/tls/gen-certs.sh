#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ca certs
if [ ! -f ca/rootCA-key.pem ]; then
  openssl req -x509 -newkey rsa:3072 -sha256 -days 825 -nodes \
    -keyout ca/rootCA-key.pem -out ca/rootCA.pem -subj "/O=Shop SAS dev/CN=Shop SAS dev CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
fi
openssl req -newkey rsa:2048 -nodes -keyout certs/localhost-key.pem -out certs/localhost.csr \
  -subj "/O=Shop SAS dev/CN=api.localhost"
openssl x509 -req -in certs/localhost.csr -CA ca/rootCA.pem -CAkey ca/rootCA-key.pem -CAcreateserial \
  -out certs/localhost.pem -days 397 -sha256 -extfile <(printf '%s\n' \
    "subjectAltName=DNS:api.localhost,DNS:adminer.localhost,DNS:localhost,IP:127.0.0.1" \
    "basicConstraints=CA:FALSE" \
    "keyUsage=critical,digitalSignature,keyEncipherment" \
    "extendedKeyUsage=serverAuth")
rm -f certs/localhost.csr
chmod 600 ca/rootCA-key.pem certs/localhost-key.pem
