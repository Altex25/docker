#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${REGISTRY:?REGISTRY obligatoire}"
: "${VERSION:?VERSION obligatoire}"
WORKER_VERSION=${WORKER_VERSION:-$VERSION}
COSIGN_PUB=${COSIGN_PUB:-deploy/cosign.pub}

tool() { local bin=$1 image=$2; shift 2; if type -P "$bin" >/dev/null; then command "$bin" "$@"; else ci/oci.sh "$image" "$@"; fi; }
cosign() { tool cosign ghcr.io/sigstore/cosign/cosign:v2.6.1 "$@"; }
crane() { tool crane gcr.io/go-containerregistry/crane:v0.20.3 "$@"; }

if [ -n "${COSIGN_IDENTITY_REGEXP:-}" ]; then
  mode=(--certificate-identity-regexp "$COSIGN_IDENTITY_REGEXP" --certificate-oidc-issuer "${COSIGN_OIDC_ISSUER:-https://token.actions.githubusercontent.com}")
  what="keyless, identité ~ $COSIGN_IDENTITY_REGEXP"
else
  mode=(--key "$COSIGN_PUB" --insecure-ignore-tlog)
  what="clé $COSIGN_PUB"
fi

verify() {
  local var=$1 repo=$2 tag=$3 digest ref
  digest=$(crane digest "$repo:$tag") || { echo "  ÉCHEC  $repo:$tag introuvable" >&2; exit 1; }
  ref=$repo@$digest
  if ! cosign verify "${mode[@]}" "$ref" > /dev/null 2> ".ci/verify-$var.err"; then
    echo "  ÉCHEC  signature invalide ou absente : $repo:$tag ($digest)" >&2
    sed 's/^/           /' ".ci/verify-$var.err" | tail -3 >&2
    exit 1
  fi
  echo "  OK     signature vérifiée ($what) : $repo:$tag@$digest" >&2
  echo "$var=$repo:$tag@$digest"
}

mkdir -p .ci
verify API_IMAGE "$REGISTRY/shopapi" "$VERSION"
verify WORKER_IMAGE "$REGISTRY/shop-worker" "$WORKER_VERSION"
