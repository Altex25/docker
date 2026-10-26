#!/usr/bin/env bash
# verified-run.sh [OPTIONS docker run...] IMAGE [COMMANDE...] : docker run seulement si l'image est signée par supply/cosign.pub.
# Le digest est résolu puis vérifié, et c'est ce digest (pas le tag) qui est lancé.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PUB=${COSIGN_PUB:-supply/cosign.pub}

args=("$@")
idx=-1
for i in "${!args[@]}"; do
  case ${args[$i]} in
    -*) ;;
    *) prev=""; [ "$i" -gt 0 ] && prev=${args[$((i - 1))]}
       if [[ $prev =~ ^-(e|p|v|w|u|l|-name|-network|-env|-publish|-volume|-workdir|-user|-entrypoint|-label|-platform|-mount|-add-host)$ ]]; then continue; fi
       idx=$i; break ;;
  esac
done
[ "$idx" -ge 0 ] || { echo "usage: verified-run.sh [OPTIONS] IMAGE [COMMANDE...]" >&2; exit 2; }
image=${args[$idx]}

cd "$HERE"
crane() { if type -P crane >/dev/null; then command crane "$@"; else tools/oci.sh gcr.io/go-containerregistry/crane:v0.20.3 "$@"; fi; }
cosign() { if type -P cosign >/dev/null; then command cosign "$@"; else tools/oci.sh ghcr.io/sigstore/cosign/cosign:v2.6.1 "$@"; fi; }

repo=${image%@*}
[[ ${repo##*/} == *:* ]] && repo=${repo%:*}
digest=$(crane digest "$image" 2>/dev/null) || { echo "REFUSÉ : $image introuvable dans le registre" >&2; exit 1; }
if ! cosign verify --key "$PUB" --insecure-ignore-tlog "$repo@$digest" >/dev/null 2>&1; then
  echo "REFUSÉ : $image ($digest) n'est pas signée par $PUB" >&2
  exit 1
fi
echo "vérifié : $repo@$digest" >&2
args[$idx]=$repo@$digest
exec docker run "${args[@]}"
