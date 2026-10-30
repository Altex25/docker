#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
mkdir -p secrets
for s in db_password db_root_password; do
  if [ ! -s "secrets/$s.txt" ]; then
    openssl rand -base64 33 | tr -d '\n/+=' | head -c 32 > "secrets/$s.txt"
    echo "secrets/$s.txt créé"
  fi
done
chmod 0644 secrets/db_password.txt
chmod 0600 secrets/db_root_password.txt
[ -f .env ] || { cp .env.example .env; echo ".env créé depuis .env.example"; }
