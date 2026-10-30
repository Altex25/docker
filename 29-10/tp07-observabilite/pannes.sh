#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

TP04=../tp04-compose-entreprise
DEV=(--project-directory "$TP04" -f "$TP04/compose.yml" -f "$TP04/compose.override.yml")
NETSHOOT=nicolaka/netshoot:v0.14@sha256:7f08c4aff13ff61a35d30e30c5c1ea8396eac6ab4ce19fd02d5a4b3b5d0d09a2
DELAY=${DELAY:-600ms}

netem() {
  local action=$1 ifaces
  ifaces=$(docker exec shop-db-1 sh -c "ls /sys/class/net | grep -v '^lo$'")
  for i in $ifaces; do
    if [ "$action" = add ]; then
      docker run --rm --cap-add NET_ADMIN --network container:shop-db-1 "$NETSHOOT" tc qdisc replace dev "$i" root netem delay "$DELAY"
    else
      docker run --rm --cap-add NET_ADMIN --network container:shop-db-1 "$NETSHOOT" tc qdisc del dev "$i" root 2> /dev/null || true
    fi
  done
}

case ${1:-} in
  mystere)
    choix=(redis db-password memoire-api latence-db)
    panne=${choix[RANDOM % ${#choix[@]}]}
    "$0" "$panne" > /dev/null
    echo "$panne" > .panne-mystere
    echo "une panne a été injectée à $(date +%H:%M:%S) : à vous de la trouver dans Grafana (réponse : cat .panne-mystere)"
    ;;
  redis)
    docker stop shop-redis-1 > /dev/null
    echo "panne : Redis arrêté"
    ;;
  db-password)
    docker exec shop-db-1 psql -U shop -d postgres -qc "ALTER ROLE shop PASSWORD 'rotation-$(date +%s)'"
    if [ "${TERMINATE:-0}" = 1 ]; then
      docker exec shop-db-1 psql -U shop -d postgres -qtAc \
        "SELECT count(pg_terminate_backend(pid)) || ' connexions fermées' FROM pg_stat_activity WHERE usename = 'shop' AND pid <> pg_backend_pid() AND backend_type = 'client backend'"
    fi
    echo "panne : mot de passe du rôle shop changé côté base (le secret des clients n'a pas suivi)"
    ;;
  memoire-api)
    docker update --memory "${LIMIT:-40m}" --memory-swap "${LIMIT:-40m}" shop-api-1 > /dev/null
    echo "panne : limite mémoire de shop-api-1 abaissée à ${LIMIT:-40m} à chaud"
    ;;
  memoire)
    target=${2:?usage : $0 memoire <conteneur> [limite]}
    ws=$(curl -s -G localhost:9090/api/v1/query --data-urlencode "query=max(container_memory_working_set_bytes{name=\"$target\"})" | jq -r '.data.result[0].value[1]')
    limit=${3:-$(awk -v w="$ws" 'BEGIN { printf "%dk", w / 1024 / 0.93 }')}
    docker update --memory "$limit" --memory-swap "$limit" "$target" > /dev/null
    echo "panne : limite mémoire de $target abaissée à chaud à $limit (working set actuel $((${ws%.*} / 1024)) Kio)"
    ;;
  fuite-memoire)
    docker update --memory 160m --memory-swap 160m shop-api-1 > /dev/null
    docker exec -d shop-api-1 node -e "globalThis.fuite = []; setInterval(() => fuite.push(Buffer.alloc(1 << 20, 1)), 500)"
    cg=/sys/fs/cgroup/docker/$(docker inspect shop-api-1 -f '{{.Id}}')
    for _ in $(seq 240); do
      ratio=$(colima ssh -- sh -c "awk -v c=\$(cat $cg/memory.current) -v m=\$(cat $cg/memory.max) '/^inactive_file /{printf \"%d\", (c - \$2) * 100 / m}' $cg/memory.stat")
      [ "$ratio" -ge 95 ] && break
      sleep 1
    done
    docker exec shop-api-1 pkill -STOP -f 'fuite.push'
    echo "panne : fuite mémoire simulée dans shop-api-1 (limite 160m), gelée à ${ratio} % du working set"
    ;;
  crash)
    target=${2:?usage : $0 crash <conteneur>}
    colima ssh -- sudo kill -9 "$(docker inspect "$target" --format '{{.State.Pid}}')"
    echo "panne : processus principal de $target tué (kill -9), la politique de redémarrage le relance"
    ;;
  latence-db)
    netem add
    echo "panne : $DELAY de latence réseau ajoutés sur shop-db-1 (tc netem)"
    ;;
  restore)
    netem del
    docker start shop-redis-1 > /dev/null 2>&1 || true
    docker exec shop-db-1 sh -c 'psql -U shop -d postgres -q -v pw="$(cat /run/secrets/db_password)" <<EOF
ALTER ROLE shop PASSWORD :'"'"'pw'"'"';
EOF'
    docker update --restart no shop-api-1 shop-worker-1 > /dev/null 2>&1 || true
    docker stop -t 5 shop-api-1 shop-worker-1 > /dev/null 2>&1 || true
    docker compose "${DEV[@]}" up -d --no-deps --force-recreate --wait api worker > /dev/null 2>&1
    if [ "$(docker inspect shop-adminer-1 --format '{{.HostConfig.Memory}}' 2> /dev/null)" != 0 ]; then
      docker compose "${DEV[@]}" --profile tools up -d --no-deps --force-recreate --wait adminer > /dev/null 2>&1
    fi
    docker compose "${DEV[@]}" up -d --no-deps --wait redis > /dev/null 2>&1
    echo "restauré : $(docker compose "${DEV[@]}" ps --format '{{.Service}}={{.Health}}' | sort | paste -sd' ' -)"
    for _ in $(seq 30); do
      [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: api.localhost' http://localhost/ready)" = 200 ] && break
      sleep 1
    done
    echo "API : $(curl -s -H 'Host: api.localhost' http://localhost/ready)"
    ;;
  *)
    echo "usage : $0 redis | db-password | memoire-api | memoire <conteneur> [limite] | fuite-memoire | crash <conteneur> | latence-db | restore" >&2
    exit 2
    ;;
esac
