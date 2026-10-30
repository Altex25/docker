#!/usr/bin/env bash
set -uo pipefail

FILTERS=()
EXCLUDE=""
JSON=0
usage() {
  echo "usage : $0 [-p projet] [-f filtre docker ps]... [-x service]... [--json]" >&2
  echo "  sans option : tous les conteneurs en cours d'exécution" >&2
  exit 2
}
while [ $# -gt 0 ]; do
  case $1 in
    -p) FILTERS+=(--filter "label=com.docker.compose.project=$2"); shift 2 ;;
    -f) FILTERS+=(--filter "$2"); shift 2 ;;
    -x) EXCLUDE="$EXCLUDE,$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

ids=$(docker ps -q ${FILTERS[@]+"${FILTERS[@]}"})
[ -z "$ids" ] && { echo "aucun conteneur en cours d'exécution" >&2; exit 2; }

report=$(docker inspect $ids | jq -c --arg exclude "$EXCLUDE" '
  def dangerous: ["ALL", "SYS_ADMIN", "NET_ADMIN", "SYS_PTRACE", "SYS_MODULE", "DAC_READ_SEARCH", "SYS_RAWIO", "SYS_BOOT", "SYS_TIME", "MKNOD", "AUDIT_CONTROL", "MAC_ADMIN", "MAC_OVERRIDE", "BPF", "PERFMON"];
  .[] |
  select((.Config.Labels["com.docker.compose.service"] // "") as $s | $exclude | split(",") | map(select(. != "")) | index($s) | not) |
  (.Config.Labels["tp08.audit.accept"] // "" | split(",") | map(select(. != ""))) as $accept |
  (.Config.User // "") as $user |
  ((.HostConfig.CapAdd // []) | map(ascii_upcase | ltrimstr("CAP_"))) as $add |
  ((.HostConfig.CapDrop // []) | map(ascii_upcase | ltrimstr("CAP_"))) as $drop |
  ((.HostConfig.SecurityOpt // []) | any(test("^no-new-privileges(:true|=true)?$"))) as $nnp |
  ([.Mounts[] | select(.Source | test("docker\\.sock$"))] | length > 0) as $sock |
  {
    name: (.Name | ltrimstr("/")),
    service: (.Config.Labels["com.docker.compose.service"] // "-"),
    checks: {
      user: {value: (if $user == "" then "(root)" else $user end), ok: ($user | test("^(|0|root)(:.*)?$") | not)},
      privileged: {value: .HostConfig.Privileged, ok: (.HostConfig.Privileged | not)},
      cap_drop: {value: (if $drop == [] then "-" else ($drop | join(",")) end), ok: ($drop | index("ALL") != null)},
      cap_add: {value: (if $add == [] then "-" else ($add | join(",")) end), ok: ([$add[] | select(. as $c | dangerous | index($c))] | length == 0)},
      read_only: {value: .HostConfig.ReadonlyRootfs, ok: .HostConfig.ReadonlyRootfs},
      memory: {value: (if .HostConfig.Memory == 0 then "illimitée" else "\(.HostConfig.Memory / 1048576 | floor)M" end), ok: (.HostConfig.Memory > 0)},
      pids: {value: (.HostConfig.PidsLimit // 0 | if . <= 0 then "illimité" else tostring end), ok: ((.HostConfig.PidsLimit // 0) > 0)},
      no_new_privs: {value: $nnp, ok: $nnp},
      docker_sock: {value: (if $sock then "montée" else "-" end), ok: ($sock | not)}
    },
    accept: $accept
  } |
  .checks |= with_entries(.value.accepted = ((.value.ok | not) and (.key as $k | $accept | index($k) != null)))
')

if [ "$JSON" = 1 ]; then
  jq -s . <<< "$report"
else
  printf '%-22s %-11s %-11s %-6s %-9s %-26s %-6s %-9s %-9s %-6s %-7s %s\n' \
    CONTENEUR UTILISATEUR PRIVILEGED DROP CAP_ADD "" RO MÉMOIRE PIDS NNP SOCKET ÉCARTS
  jq -r '
    def cell($c): (if $c.ok then "" elif $c.accepted then "~" else "!" end) + ($c.value | tostring);
    [ .name[0:22], cell(.checks.user), cell(.checks.privileged), cell(.checks.cap_drop)[0:6],
      cell(.checks.cap_add)[0:35], cell(.checks.read_only), cell(.checks.memory), cell(.checks.pids),
      cell(.checks.no_new_privs), cell(.checks.docker_sock),
      ([.checks | to_entries[] | select((.value.ok | not) and (.value.accepted | not)) | .key] | length | tostring) ]
    | @tsv' <<< "$report" | awk -F'\t' '{ printf "%-22s %-11s %-11s %-6s %-36s %-6s %-9s %-9s %-6s %-7s %s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11 }'
  echo
  echo "! = écart, ~ = écart accepté (label tp08.audit.accept)"
  jq -rs '
    (map(.checks | to_entries[] | select((.value.ok | not) and (.value.accepted | not))) | length) as $n |
    (map(.checks | to_entries[] | select(.value.accepted)) | length) as $a |
    "\(length) conteneur(s), \($n) écart(s), \($a) écart(s) accepté(s)",
    (map(.checks | to_entries[] | select((.value.ok | not) and (.value.accepted | not)) | .key) | group_by(.) | map("  \(.[0]) : \(length)") | .[])
  ' <<< "$report"
fi

failures=$(jq -s 'map(.checks | to_entries[] | select((.value.ok | not) and (.value.accepted | not))) | length' <<< "$report")
[ "$failures" -eq 0 ]
