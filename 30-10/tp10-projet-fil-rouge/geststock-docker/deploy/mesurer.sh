#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TITRE=${1:?usage: mesurer.sh TITRE COMMANDE...}
shift
export DOCKER_CONTEXT=${DOCKER_CONTEXT:-preprod}
WARMUP=${WARMUP:-5}
export DURATION=${DURATION:-60}
mkdir -p .ci
out=.ci/mesure-$$.txt

echo "== $TITRE"
echo "   $ $*"
./deploy/measure-downtime.sh > "$out" 2>&1 &
pid=$!
sleep "$WARMUP"
debut=$(date +%s)
set +e
"$@" 2>&1 | sed 's/^/   | /'
code=${PIPESTATUS[0]}
set -e
echo "   commande terminée en $(( $(date +%s) - debut ))s (code retour $code)"
wait "$pid"
grep -E '<<<' "$out" | sed 's/^/   /' || true
grep -E '^==|^     ' "$out" | sed 's/^/   /'
grep '^RESUME' "$out"
rm -f "$out"
