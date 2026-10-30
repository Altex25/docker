#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

NOM=${1:-preprod}
PORT_SSH=${2:-2222}
PORT_HTTP=${3:-8090}
IMAGE=tp09/serveur:1
CA=$(cd ../../../26-10/tp03-registry-supply-chain/starter/registry/certs && pwd)/ca.crt
HERE=$PWD

mkdir -p cles
[ -f cles/deploy_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C "deploy@ci-shop" -f cles/deploy_ed25519

docker build -q -t "$IMAGE" . > /dev/null
docker rm -f "tp09-$NOM" > /dev/null 2>&1 || true
docker run -d --name "tp09-$NOM" --hostname "$NOM" --privileged \
  --label tp09=serveur --restart unless-stopped \
  -p "127.0.0.1:$PORT_SSH:22" -p "127.0.0.1:$PORT_HTTP:80" \
  --add-host "registry.local:$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')" \
  -e DOCKER_TLS_CERTDIR= -e DEPLOY_AUTHORIZED_KEY="$(cat cles/deploy_ed25519.pub)" \
  -v "tp09-$NOM-docker:/var/lib/docker" -v "tp09-$NOM-srv:/srv/shop" \
  --mount "type=bind,src=$CA,dst=/etc/docker/certs.d/registry.local:5000/ca.crt,readonly" \
  "$IMAGE" > /dev/null

for _ in $(seq 60); do docker exec "tp09-$NOM" docker info > /dev/null 2>&1 && break; sleep 1; done
docker exec "tp09-$NOM" chown deploy:deploy /srv/shop

touch known_hosts
ssh-keygen -R "[localhost]:$PORT_SSH" -f known_hosts > /dev/null 2>&1 || true
for _ in $(seq 30); do
  cle=$(ssh-keyscan -q -4 -t ed25519 -p "$PORT_SSH" localhost 2>/dev/null || true)
  [ -n "$cle" ] && break
  sleep 1
done
[ -n "$cle" ] || { echo "sshd injoignable sur localhost:$PORT_SSH" >&2; exit 1; }
echo "$cle" >> known_hosts
rm -f known_hosts.old
cat > ssh_config <<CFG
Host localhost
  User deploy
  IdentityFile $HERE/cles/deploy_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile $HERE/known_hosts
  StrictHostKeyChecking yes
  ControlMaster auto
  ControlPath /tmp/tp09-ssh-%C
  ControlPersist 60s
CFG

export PATH="$HERE/bin:$PATH"
ssh -p "$PORT_SSH" localhost sh -s <<'PROVISION'
set -eu
cd /srv/shop
umask 022
mkdir -p secrets
[ -s secrets/db_password.txt ] || head -c 48 /dev/urandom | base64 | tr -d '\n/+=' | head -c 32 > secrets/db_password.txt
chmod 0755 secrets
chmod 0644 secrets/db_password.txt
[ -f .env ] || printf 'REGISTRY=registry.local:5000\n' > .env
chmod 0600 .env
ls -la /srv/shop /srv/shop/secrets
PROVISION

docker context rm -f "$NOM" > /dev/null 2>&1 || true
docker context create "$NOM" --description "TP09 serveur $NOM (dind)" --docker "host=ssh://deploy@localhost:$PORT_SSH" > /dev/null
echo "contexte $NOM : $(docker context inspect "$NOM" --format '{{.Endpoints.docker.Host}}')"
echo "clé et known_hosts du TP pour ssh : export PATH=\"$HERE/bin:\$PATH\""
