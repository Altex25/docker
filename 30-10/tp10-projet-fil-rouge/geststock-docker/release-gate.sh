#!/usr/bin/env bash
set -euo pipefail

IMAGE=${1:?usage: release-gate.sh IMAGE}
cd "$(dirname "$0")"

LABELS=(org.opencontainers.image.version org.opencontainers.image.revision org.opencontainers.image.source)
VERSION_LABEL='^(v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?|sha-[0-9a-f]{7,40}|pr-[0-9a-z]+)$'

tool() { local bin=$1 image=$2; shift 2; if type -P "$bin" >/dev/null; then command "$bin" "$@"; else ci/oci.sh "$image" "$@"; fi; }
trivy() { tool trivy aquasec/trivy:0.69.1 "$@"; }

failures=0
ok() { echo "  OK     $*"; }
ko() { echo "  ÉCHEC  $*"; failures=$((failures + 1)); }
die() { echo "  ERREUR $*"; exit 2; }

cfg=$(docker image inspect "$IMAGE" --format '{{json .Config}}' 2>/dev/null) || die "image introuvable : $IMAGE"
echo "== Porte de release : $IMAGE"

for l in "${LABELS[@]}"; do
  v=$(jq -r --arg l "$l" '.Labels[$l] // empty' <<<"$cfg")
  if [ -z "$v" ]; then ko "label $l absent"
  elif [ "$l" = org.opencontainers.image.version ] && ! [[ $v =~ $VERSION_LABEL ]]; then ko "label $l=$v : ni semver ni sha-<commit>"
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
