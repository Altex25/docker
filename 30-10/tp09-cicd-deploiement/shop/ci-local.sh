#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
SHOP=$PWD
ROOT=$(dirname "$SHOP")

EVENT=${1:-pr}
REF_TAG=${2:-}
REGISTRY=${REGISTRY:-registry.local:5000}
BUILDER=${BUILDER:-tp09}
PLATFORMS=${PLATFORMS:-linux/amd64,linux/arm64}
APPS=${APPS:-shopapi shop-worker}
SOURCE_URL=${SOURCE_URL:-https://github.com/Altex25/shop}
COSIGN_MODE=${COSIGN_MODE:-key}
COSIGN_KEY=${COSIGN_KEY:-../cles-ci/cosign.key}
HADOLINT=hadolint/hadolint:v2.15.1@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d
TRIVY=aquasec/trivy:0.69.1
COSIGN=ghcr.io/sigstore/cosign/cosign:v2.6.1
CRANE=gcr.io/go-containerregistry/crane:v0.20.3
export COSIGN_PASSWORD=${COSIGN_PASSWORD-}
[ -d "$ROOT/serveur/bin" ] && export PATH="$ROOT/serveur/bin:$PATH"

case $EVENT in
  pr | main) ;;
  tag | deploy-prod) [[ $REF_TAG =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "usage : ci-local.sh $EVENT vX.Y.Z" >&2; exit 2; } ;;
  *) echo "usage : ci-local.sh pr | main | tag vX.Y.Z | deploy-prod vX.Y.Z" >&2; exit 2 ;;
esac

if [ -n "${CI_SHA:-}" ]; then
  SHA=$CI_SHA
elif [ -z "$(git status --porcelain -- . 2>/dev/null)" ]; then
  SHA=$(git rev-parse HEAD)
else
  SHA=$(find apps compose*.yml config db -type f ! -name pip.conf -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-40)
  echo "!! arbre non commité : identifiant dérivé du contenu ($SHA)"
fi
SHORT=${SHA:0:7}
mkdir -p .ci
START=$(date +%s)

step() { printf '\n\033[1m== [%s] %s\033[0m\n' "$(( $(date +%s) - START ))s" "$*"; }
oci() { ci/oci.sh "$@"; }

tags_for() {
  local repo=$REGISTRY/$1
  case $EVENT in
    pr) echo "$repo:pr-local" ;;
    main) echo "$repo:sha-$SHORT" ;;
    tag)
      local v=${REF_TAG#v}
      echo "$repo:$v"; echo "$repo:${v%.*}"
      [ "${v%%.*}" = 0 ] || echo "$repo:${v%%.*}"
      ;;
  esac
}
version_for() {
  case $EVENT in
    pr) echo pr-local ;;
    main) echo "sha-$SHORT" ;;
    tag) echo "${REF_TAG#v}" ;;
  esac
}

ensure_builder() {
  docker buildx inspect "$BUILDER" > /dev/null 2>&1 && return
  local ca
  ca=$(cd "$ROOT/../../26-10/tp03-registry-supply-chain/starter/registry/certs" && pwd)/ca.crt
  printf '[registry."%s"]\n  ca = ["%s"]\n' "$REGISTRY" "$ca" > .ci/buildkitd.toml
  docker buildx create --name "$BUILDER" --driver docker-container \
    --driver-opt network=host --driver-opt image=moby/buildkit:v0.30.0 \
    --buildkitd-config .ci/buildkitd.toml --bootstrap > /dev/null
}

secret_args() {
  [ "$1" = shop-worker ] || return 0
  [ -f apps/shop-worker/pip.conf ] || cp apps/shop-worker/pip.conf.example apps/shop-worker/pip.conf
  echo "--secret id=pipconf,src=apps/shop-worker/pip.conf"
}

if [ "$EVENT" != deploy-prod ]; then

if [ "$EVENT" = tag ]; then
  step "tags semver immuables : ${REF_TAG#v} encore libre ?"
  for app in $APPS; do
    if existing=$(oci "$CRANE" digest "$REGISTRY/$app:${REF_TAG#v}" 2> /dev/null); then
      echo "  ÉCHEC  $REGISTRY/$app:${REF_TAG#v} existe déjà ($existing) : un tag semver ne se republie pas"
      exit 1
    fi
    echo "  OK     $REGISTRY/$app:${REF_TAG#v} jamais publié"
  done
fi

step "hadolint"
for app in $APPS; do
  printf '  %-12s ' "$app"
  docker run --rm -i "$HADOLINT" hadolint - < "apps/$app/Dockerfile" && echo OK
done

step "docker compose config"
mkdir -p .ci/config/secrets
printf 'ci' > .ci/config/secrets/db_password.txt
for files in "compose.yml" "compose.yml compose.override.yml" "compose.yml compose.prod.yml"; do
  args=()
  for f in $files; do args+=(-f "$f"); done
  VERSION=sha-$SHORT docker compose --project-directory .ci/config --env-file .env.example "${args[@]}" \
    --profile tools --profile ops config -q
  echo "  OK     $files"
done

ensure_builder

step "build de l'étape test"
for app in $APPS; do
  echo "  -- $app"
  docker buildx build --builder "$BUILDER" --progress quiet --target test --output type=cacheonly \
    --cache-from "type=registry,ref=$REGISTRY/cache/$app" \
    $(secret_args "$app") "apps/$app" > /dev/null
  echo "  OK     tests $app"
done

step "build multi-arch ($PLATFORMS)"
for app in $APPS; do
  tag_args=()
  for t in $(tags_for "$app"); do tag_args+=(-t "$t"); done
  out=(--output type=image,push=false)
  cache_to=()
  if [ "$EVENT" != pr ]; then
    out=(--push)
    cache_to=(--cache-to "type=registry,ref=$REGISTRY/cache/$app,mode=max")
  fi
  version=$(version_for)
  docker buildx build --builder "$BUILDER" --progress quiet --platform "$PLATFORMS" --target runtime \
    "${tag_args[@]}" "${out[@]}" \
    --provenance mode=max --sbom true \
    --cache-from "type=registry,ref=$REGISTRY/cache/$app" ${cache_to[@]+"${cache_to[@]}"} \
    --build-arg "APP_VERSION=$version" --build-arg "GIT_SHA=$SHA" --build-arg "SOURCE_URL=$SOURCE_URL" \
    --label "org.opencontainers.image.version=$version" \
    --label "org.opencontainers.image.revision=$SHA" \
    --label "org.opencontainers.image.source=$SOURCE_URL" \
    --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --metadata-file ".ci/metadata-$app.json" \
    $(secret_args "$app") "apps/$app" > /dev/null
  digest=$(jq -r '."containerimage.digest" // empty' ".ci/metadata-$app.json")
  echo "  OK     $app : $(tags_for "$app" | paste -sd' ' -) ${digest:+-> $digest}"
  echo "$digest" > ".ci/digest-$app"
done

if [ "$EVENT" = pr ]; then
  step "PR : pas de push, pipeline terminé ($(( $(date +%s) - START ))s)"
  exit 0
fi

for app in $APPS; do
  ref=$REGISTRY/$app@$(cat ".ci/digest-$app")
  step "scan trivy bloquant : $app"
  for p in ${PLATFORMS//,/ }; do
    oci "$TRIVY" image -q --platform "$p" --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
      --exit-code 1 --format table "$ref" > ".ci/trivy-$app-${p//\//-}.txt" \
      || { cat ".ci/trivy-$app-${p//\//-}.txt"; echo "  ÉCHEC  $app ($p) : CVE HIGH/CRITICAL corrigeables, pipeline arrêté"; exit 1; }
    echo "  OK     $p : aucune CVE HIGH/CRITICAL corrigeable"
  done
  step "porte de release : $app"
  docker pull -q "$ref" > /dev/null
  ./release-gate.sh "$ref"
done

for app in $APPS; do
  ref=$REGISTRY/$app@$(cat ".ci/digest-$app")
  step "signature cosign ($COSIGN_MODE) : $app"
  if [ "$COSIGN_MODE" = keyless ]; then
    oci "$COSIGN" sign --yes --fulcio-auth-flow device "$ref"
  else
    oci "$COSIGN" sign --yes --key "$COSIGN_KEY" --tlog-upload=false "$ref" > /dev/null 2>&1
  fi
  echo "  OK     signé : $ref"
done

fi

case $EVENT in
  main) TARGET=${PREPROD_CONTEXT:-preprod}; DEPLOY_VERSION=sha-$SHORT ;;
  tag | deploy-prod)
    TARGET=${PROD_CONTEXT:-prod}; DEPLOY_VERSION=${REF_TAG#v}
    step "environment production : approbation manuelle"
    if [ -n "${APPROVE:-}" ]; then
      answer=$APPROVE
      echo "  Déployer $DEPLOY_VERSION en production ($TARGET) ? [oui/non] $answer (APPROVE)"
    else
      read -r -p "  Déployer $DEPLOY_VERSION en production ($TARGET) ? [oui/non] " answer < /dev/tty
    fi
    [ "$answer" = oui ] || { echo "  Refusé : déploiement prod annulé"; exit 1; }
    echo "  approuvé par ${USER:-?} à $(date +%H:%M:%S)"
    ;;
esac

step "déploiement $TARGET : vérification des signatures puis rolling update ($DEPLOY_VERSION)"
DOCKER_CONTEXT=$TARGET REGISTRY=$REGISTRY VERSION=$DEPLOY_VERSION ./deploy/rolling-update.sh

step "pipeline $EVENT terminé ($(( $(date +%s) - START ))s)"
