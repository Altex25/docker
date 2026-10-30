#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(dirname "$PWD")

EVENT=${1:-pr}
REF_TAG=${2:-}
REGISTRY=${REGISTRY:-registry.local:5000}
BUILDER=${BUILDER:-tp09}
PLATFORMS=${PLATFORMS:-linux/amd64,linux/arm64}
SOURCE_URL=${SOURCE_URL:-https://github.com/Altex25/geststock-docker}
COSIGN_KEY=${COSIGN_KEY:-../../tp09-cicd-deploiement/cles-ci/cosign.key}
CI_PORT=${CI_PORT:-8089}
HADOLINT=hadolint/hadolint:v2.15.1@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d
TRIVY=aquasec/trivy:0.69.1
COSIGN=ghcr.io/sigstore/cosign/cosign:v2.6.1
CRANE=gcr.io/go-containerregistry/crane:v0.20.3
REPO=$REGISTRY/geststock
export COSIGN_PASSWORD=${COSIGN_PASSWORD-}
[ -d "$ROOT/serveur/bin" ] && export PATH="$ROOT/serveur/bin:$PATH"

case $EVENT in
  pr | main) ;;
  tag | deploy-prod) [[ $REF_TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage : ci-local.sh $EVENT vX.Y.Z" >&2; exit 2; } ;;
  *) echo "usage : ci-local.sh pr | main | tag vX.Y.Z | deploy-prod vX.Y.Z" >&2; exit 2 ;;
esac

if [ -n "${CI_SHA:-}" ]; then
  SHA=$CI_SHA
elif [ -z "$(git status --porcelain -- . 2>/dev/null)" ]; then
  SHA=$(git rev-parse HEAD)
else
  SHA=$(find app tests docker Dockerfile compose*.yml -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-40)
  echo "!! arbre non commité : identifiant dérivé du contenu ($SHA)"
fi
SHORT=${SHA:0:7}
case $EVENT in
  pr) VERSION=pr-local; TAGS=() ;;
  main) VERSION=sha-$SHORT; TAGS=("$REPO:sha-$SHORT") ;;
  tag | deploy-prod)
    VERSION=${REF_TAG#v}
    TAGS=("$REPO:$VERSION" "$REPO:${VERSION%.*}")
    [ "${VERSION%%.*}" = 0 ] || TAGS+=("$REPO:${VERSION%%.*}")
    ;;
esac
mkdir -p .ci
START=$(date +%s)
step() { printf '\n\033[1m== [%s] %s\033[0m\n' "$(( $(date +%s) - START ))s" "$*"; }
oci() { ci/oci.sh "$@" < /dev/null; }

ensure_builder() {
  docker buildx inspect "$BUILDER" > /dev/null 2>&1 && return
  local ca
  ca=$(cd "$ROOT/../../26-10/tp03-registry-supply-chain/starter/registry/certs" && pwd)/ca.crt
  printf '[registry."%s"]\n  ca = ["%s"]\n' "$REGISTRY" "$ca" > .ci/buildkitd.toml
  docker buildx create --name "$BUILDER" --driver docker-container \
    --driver-opt network=host --driver-opt image=moby/buildkit:v0.30.0 \
    --buildkitd-config .ci/buildkitd.toml --bootstrap > /dev/null
}

if [ "$EVENT" != deploy-prod ]; then

if [ "$EVENT" = tag ]; then
  step "tag semver immuable : $VERSION encore libre ?"
  if existing=$(oci "$CRANE" digest "$REPO:$VERSION" 2> /dev/null); then
    echo "  ÉCHEC  $REPO:$VERSION existe déjà ($existing) : un tag semver ne se republie pas"
    exit 1
  fi
  echo "  OK     $REPO:$VERSION jamais publié"
fi

step "lint : hadolint, php -l, compose config"
docker run --rm -i "$HADOLINT" hadolint - < Dockerfile && echo "  OK     hadolint Dockerfile"
./scripts/init-secrets.sh > /dev/null
for files in "compose.yml compose.override.yml" "compose.yml compose.prod.yml" "compose.yml compose.prod.yml compose.hardened.yml" "compose.yml compose.hardened.yml compose.mailpit.yml"; do
  args=()
  for f in $files; do args+=(-f "$f"); done
  VERSION=$VERSION SMTP_HOST=smtp.ci docker compose --env-file .env.example "${args[@]}" config -q
  echo "  OK     compose config : $files"
done

ensure_builder

step "build de l'étape test (php -l sur tous les fichiers, tests/config_test.php)"
docker buildx build --builder "$BUILDER" --progress plain --target test --output type=cacheonly \
  --cache-from "type=registry,ref=$REGISTRY/cache/geststock" . > .ci/test-stage.log 2>&1 \
  || { grep -E 'ÉCHEC|ERROR|error' .ci/test-stage.log | grep -v 'cache importer'; echo "  ÉCHEC  étape test"; exit 1; }
if grep -q 'No syntax errors' .ci/test-stage.log; then
  grep -E 'No syntax errors|OK  ' .ci/test-stage.log | sed 's/^#[0-9]* [0-9.]* /  /'
else
  echo "  OK     étape test en cache : sources inchangées depuis le dernier passage réussi"
fi

step "image de test (plateforme native) et stack d'intégration sur le port $CI_PORT"
docker buildx build --builder "$BUILDER" --progress quiet --target runtime --load \
  --cache-from "type=registry,ref=$REGISTRY/cache/geststock" \
  --build-arg "APP_VERSION=$VERSION" --build-arg "GIT_SHA=$SHA" -t "ci/geststock:$VERSION" . > /dev/null
CI_COMPOSE="docker compose -p geststock-ci -f compose.yml -f compose.hardened.yml -f compose.mailpit.yml"
cleanup_ci() { REGISTRY=ci VERSION=$VERSION HTTP_PORT=$CI_PORT $CI_COMPOSE down -v --remove-orphans > /dev/null 2>&1 || true; }
trap cleanup_ci EXIT
REGISTRY=ci VERSION=$VERSION HTTP_PORT=$CI_PORT SMTP_HOST=mailpit $CI_COMPOSE up -d --wait --no-build > /dev/null 2>&1 \
  || { REGISTRY=ci VERSION=$VERSION $CI_COMPOSE ps; REGISTRY=ci VERSION=$VERSION $CI_COMPOSE logs --tail 20; exit 1; }
echo "  OK     stack geststock-ci démarrée (image ci/geststock:$VERSION, compose.hardened.yml)"
REGISTRY=ci VERSION=$VERSION COMPOSE="$CI_COMPOSE" BASE_URL="http://localhost:$CI_PORT" ./scripts/smoke-test.sh | sed 's/^/  /'
./scripts/audit.sh -p geststock-ci | tail -2 | sed 's/^/  /'
cleanup_ci
trap - EXIT
echo "  OK     stack d'intégration supprimée"

step "build multi-arch ($PLATFORMS), provenance + SBOM"
tag_args=()
for t in ${TAGS[@]+"${TAGS[@]}"}; do tag_args+=(-t "$t"); done
if [ "$EVENT" = pr ]; then
  out=(--output type=image,push=false)
  cache_to=()
else
  out=(--push)
  cache_to=(--cache-to "type=registry,ref=$REGISTRY/cache/geststock,mode=max")
fi
docker buildx build --builder "$BUILDER" --progress quiet --platform "$PLATFORMS" --target runtime \
  ${tag_args[@]+"${tag_args[@]}"} "${out[@]}" --provenance mode=max --sbom true \
  --cache-from "type=registry,ref=$REGISTRY/cache/geststock" ${cache_to[@]+"${cache_to[@]}"} \
  --build-arg "APP_VERSION=$VERSION" --build-arg "GIT_SHA=$SHA" --build-arg "SOURCE_URL=$SOURCE_URL" \
  --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --metadata-file .ci/metadata.json . > /dev/null
digest=$(jq -r '."containerimage.digest" // empty' .ci/metadata.json)
echo "  OK     ${TAGS[*]:-pas de push (PR)} ${digest:+-> $digest}"

if [ "$EVENT" = pr ]; then
  step "PR : pas de push, pipeline terminé ($(( $(date +%s) - START ))s)"
  exit 0
fi
ref=$REPO@$digest

step "scan trivy bloquant"
for p in ${PLATFORMS//,/ }; do
  oci "$TRIVY" image -q --platform "$p" --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
    --exit-code 1 --format table "$ref" > ".ci/trivy-${p//\//-}.txt" \
    || { cat ".ci/trivy-${p//\//-}.txt"; echo "  ÉCHEC  $p : CVE HIGH/CRITICAL corrigeables, pipeline arrêté"; exit 1; }
  echo "  OK     $p : aucune CVE HIGH/CRITICAL corrigeable"
done

step "porte de release"
docker pull -q "$ref" > /dev/null
./release-gate.sh "$ref"

step "SBOM et signature cosign"
oci "$CRANE" manifest "$ref" | jq -r '.manifests[] | select(.annotations["vnd.docker.reference.type"] == "attestation-manifest") | "  OK     attestations SBOM SPDX + provenance SLSA pour \(.annotations["vnd.docker.reference.digest"][0:19])…"'
oci "$COSIGN" sign --yes --key "$COSIGN_KEY" --tlog-upload=false "$ref" > /dev/null 2>&1
echo "  OK     signé : $ref"

fi

case $EVENT in
  main) TARGET=${PREPROD_CONTEXT:-geststock-preprod} ;;
  tag | deploy-prod)
    TARGET=${PROD_CONTEXT:-geststock-prod}
    step "environment production : approbation manuelle"
    if [ -n "${APPROVE:-}" ]; then
      answer=$APPROVE
      echo "  Déployer $VERSION en production ($TARGET) ? [oui/non] $answer (APPROVE)"
    else
      read -r -p "  Déployer $VERSION en production ($TARGET) ? [oui/non] " answer < /dev/tty
    fi
    [ "$answer" = oui ] || { echo "  Refusé : déploiement prod annulé"; exit 1; }
    echo "  approuvé par ${USER:-?} à $(date +%H:%M:%S)"
    ;;
esac

if [ "${DEPLOY:-1}" = 0 ]; then
  step "DEPLOY=0 : pas de déploiement ($(( $(date +%s) - START ))s)"
  exit 0
fi
step "déploiement $TARGET : vérification de signature puis rolling update ($VERSION)"
DOCKER_CONTEXT=$TARGET REGISTRY=$REGISTRY VERSION=$VERSION ./deploy/rolling-update.sh

step "pipeline $EVENT terminé ($(( $(date +%s) - START ))s)"
