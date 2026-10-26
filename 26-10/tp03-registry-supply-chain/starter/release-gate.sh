#!/usr/bin/env bash
# release-gate.sh IMAGE [--push REGISTRY_IMAGE:TAG]
# Refuse (exit 1) une image qui ne respecte pas la politique Shop SAS ; si elle passe et --push est donné :
# push, SBOM du digest publié, signature et attestation cosign. Exit 2 : erreur d'usage ou d'outillage.
set -euo pipefail

IMAGE=${1:?usage: release-gate.sh IMAGE [--push REGISTRY_IMAGE:TAG]}
PUSH=""
if [ "${2:-}" = --push ]; then PUSH=${3:?usage: release-gate.sh IMAGE --push REGISTRY_IMAGE:TAG}; fi

HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
KEY=${COSIGN_KEY:-supply/cosign.key}
PUB=${COSIGN_PUB:-${KEY%.key}.pub}
export COSIGN_PASSWORD=${COSIGN_PASSWORD-}
LABELS=(org.opencontainers.image.version org.opencontainers.image.revision org.opencontainers.image.source)
SEMVER='^v?[0-9]+\.[0-9]+\.[0-9]+$'
SEMVER_LABEL='^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'

tool() { local bin=$1 image=$2; shift 2; if type -P "$bin" >/dev/null; then command "$bin" "$@"; else tools/oci.sh "$image" "$@"; fi; }
trivy() { tool trivy aquasec/trivy:0.69.1 "$@"; }
syft() { tool syft anchore/syft:v1.54.1 "$@"; }
cosign() { tool cosign ghcr.io/sigstore/cosign/cosign:v2.6.1 "$@"; }
crane() { tool crane gcr.io/go-containerregistry/crane:v0.20.3 "$@"; }

failures=0
ok() { echo "  OK     $*"; }
ko() { echo "  ÉCHEC  $*"; failures=$((failures + 1)); }
die() { echo "  ERREUR $*"; exit 2; }

cfg=$(docker image inspect "$IMAGE" --format '{{json .Config}}' 2>/dev/null) || die "image introuvable : $IMAGE"
echo "== Porte de release : $IMAGE"

for l in "${LABELS[@]}"; do
  v=$(jq -r --arg l "$l" '.Labels[$l] // empty' <<<"$cfg")
  if [ -z "$v" ]; then ko "label $l absent"
  elif [ "$l" = org.opencontainers.image.version ] && ! [[ $v =~ $SEMVER_LABEL ]]; then ko "label $l=$v : pas une version semver (label hérité de l'image de base ?)"
  else ok "label $l=$v"; fi
done

user=$(jq -r '.User // ""' <<<"$cfg")
case ${user%%:*} in
  "" | root | 0) ko "utilisateur root (User=\"$user\")" ;;
  *) ok "utilisateur non-root ($user)" ;;
esac

hc=$(jq -r '.Healthcheck.Test[0] // "NONE"' <<<"$cfg")
if [ "$hc" = NONE ]; then ko "pas de HEALTHCHECK"; else ok "HEALTHCHECK ($(jq -r '.Healthcheck.Test[1:] | join(" ") | .[0:70]' <<<"$cfg"))"; fi

vulns=$(trivy image -q --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --format json "$IMAGE") || die "scan de vulnérabilités impossible"
n=$(jq '[.Results[]?.Vulnerabilities[]?] | length' <<<"$vulns")
if [ "$n" -eq 0 ]; then
  ok "aucune CVE HIGH/CRITICAL corrigeable"
else
  ko "$n CVE HIGH/CRITICAL corrigeables :"
  jq -r '[.Results[]?.Vulnerabilities[]?] | group_by(.PkgName) | .[] | "           \(.[0].PkgName) \(.[0].InstalledVersion) : \(map(.VulnerabilityID) | unique | length) CVE (\(map(.Severity) | unique | join("/"))), corrigé en \(.[0].FixedVersion)"' <<<"$vulns" | awk 'NR <= 8 { print } END { if (NR > 8) printf "           … et %d autre(s) paquet(s)\n", NR - 8 }'
fi

env_leaks=$(jq -r '.Env // [] | .[] | select(test("^[^=]*(PASS|SECRET|TOKEN|API_?KEY|PRIVATE)[^=]*=.+"; "i") or test("=[a-z+.-]+://[^/:@]+:[^@/]+@"; "i")) | sub("=.*"; "=***")' <<<"$cfg")
if [ -z "$env_leaks" ]; then ok "aucun identifiant dans les variables ENV de l'image"; else ko "identifiants dans ENV : $(paste -sd' ' - <<<"$env_leaks")"; fi

secrets=$(trivy image -q --scanners secret --image-config-scanners secret --format json "$IMAGE") || die "scan de secrets impossible"
n=$(jq '[.Results[]?.Secrets[]?] | length' <<<"$secrets")
if [ "$n" -eq 0 ]; then
  ok "aucun secret détecté"
else
  ko "$n secret(s) détecté(s) :"
  jq -r '.Results[]? | .Target as $t | .Secrets[]? | "           \($t) : \(.RuleID) (\(.Severity))"' <<<"$secrets"
fi

if [ "$failures" -gt 0 ]; then
  echo "== REFUSÉ : $failures contrôle(s) en échec"
  exit 1
fi
echo "== ACCEPTÉ"
[ -n "$PUSH" ] || exit 0

[[ $PUSH == *:* && ${PUSH##*/} == *:* ]] || die "--push attend REGISTRY/REPO:TAG"
tag=${PUSH##*:}
repo=${PUSH%:*}
local_digest=$(docker image inspect "$IMAGE" --format '{{.Id}}')
if remote=$(crane digest "$PUSH" 2>/dev/null) && [[ $tag =~ $SEMVER ]] && [ "$remote" != "$local_digest" ]; then
  echo "  ÉCHEC  $PUSH existe déjà avec un autre digest ($remote) : les tags semver sont immuables"
  exit 1
fi

published() {
  cosign verify --key "$PUB" --insecure-ignore-tlog "$1" >/dev/null 2>&1 || return 1
  for t in spdxjson cyclonedx; do cosign verify-attestation --key "$PUB" --insecure-ignore-tlog --type "$t" "$1" >/dev/null 2>&1 || return 1; done
}
if [ "${remote:-}" = "$local_digest" ] && published "$repo@$local_digest"; then
  ok "déjà publié, signé et attesté : $repo@$local_digest"
  exit 0
fi

docker tag "$IMAGE" "$PUSH"
docker push -q "$PUSH" >/dev/null || die "push impossible"
digest=$(crane digest "$PUSH") || die "digest introuvable après push"
ref=$repo@$digest
ok "poussé : $ref"

mkdir -p supply
base=supply/sbom-$(tr '/:@' '___' <<<"${repo##*/}-$tag")
sbom=$base.spdx.json
cdx=$base.trivy.cdx.json
syft "registry:$ref" -q -o "spdx-json=$sbom" || die "génération du SBOM impossible"
ok "SBOM SPDX (syft) : $sbom ($(jq '.packages | length' "$sbom") paquets)"
trivy image -q --format cyclonedx -o "$cdx" "$ref" || die "génération du SBOM CycloneDX impossible"
ok "SBOM CycloneDX (trivy, pour les rescans) : $cdx ($(jq '.components | length' "$cdx") composants)"

cosign sign --key "$KEY" --tlog-upload=false "$ref" >/dev/null 2>&1 || die "signature impossible"
cosign attest --key "$KEY" --tlog-upload=false --type spdxjson --predicate "$sbom" "$ref" >/dev/null 2>&1 || die "attestation SPDX impossible"
cosign attest --key "$KEY" --tlog-upload=false --type cyclonedx --predicate "$cdx" "$ref" >/dev/null 2>&1 || die "attestation CycloneDX impossible"
cosign verify --key "$PUB" --insecure-ignore-tlog "$ref" >/dev/null 2>&1 || die "signature invalide après publication"
for t in spdxjson cyclonedx; do
  cosign verify-attestation --key "$PUB" --insecure-ignore-tlog --type "$t" "$ref" >/dev/null 2>&1 || die "attestation $t invalide après publication"
done
ok "signé et attesté (SBOM SPDX + CycloneDX), vérifié avec $PUB"
echo "== PUBLIÉ : $ref"
