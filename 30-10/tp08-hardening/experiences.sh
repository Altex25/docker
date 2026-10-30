#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

A=alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
D=debian:12-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
P=python:3.12-alpine@sha256:e6dae589c1c05976188fd3bd019afd091445fc533ed2ea29001beddc7368a9c8

run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; printf '[code retour %s]\n' "$?"; }
caps() { local c; for c in ${1//,/ }; do printf -- '--cap-add %s ' "$c"; done; }

echo "################ --read-only"
run docker run --rm --read-only "$A" touch /x
run docker run --rm --read-only --tmpfs /tmp "$A" sh -c 'touch /tmp/x && ls -l /tmp/x && grep " /tmp " /proc/mounts'

echo
echo "################ --cap-drop ALL"
run docker run --rm "$A" sh -c 'grep CapEff /proc/self/status'
run docker run --rm --cap-drop ALL "$A" sh -c 'grep CapEff /proc/self/status'
echo
echo "ping : Docker règle net.ipv4.ping_group_range pour autoriser l'ICMP « datagramme » sans NET_RAW"
run docker run --rm --cap-drop ALL "$A" sh -c 'cat /proc/sys/net/ipv4/ping_group_range; ping -c1 -W2 1.1.1.1 | tail -1'
run docker run --rm --cap-drop ALL --sysctl 'net.ipv4.ping_group_range=1 0' "$A" ping -c1 -W2 1.1.1.1
run docker run --rm --cap-drop ALL --cap-add NET_RAW --sysctl 'net.ipv4.ping_group_range=1 0' "$A" sh -c 'ping -c1 -W2 1.1.1.1 | tail -1'
echo
echo "chown"
run docker run --rm --cap-drop ALL "$A" sh -c 'touch /f && chown 1000 /f'
run docker run --rm --cap-drop ALL --cap-add CHOWN "$A" sh -c 'touch /f && chown 1000 /f && ls -ln /f'
echo
echo "apk add : curl (fichiers root) puis nginx (crée un utilisateur et fait des chown)"
for set in "" CHOWN CHOWN,FOWNER CHOWN,FOWNER,DAC_OVERRIDE; do
  for pkg in curl nginx; do
    [ "$pkg" = curl ] && [ -n "$set" ] && continue
    r=$(docker run --rm --cap-drop ALL $(caps "$set") "$A" sh -c "apk add --no-progress $pkg > /tmp/apk.log 2>&1; rc=\$?; grep -E 'ERROR|not permitted' /tmp/apk.log | head -2 | tr '\n' ' '; echo \"(code apk \$rc)\"")
    printf '  cap_add=[%-28s] apk add %-5s : %s\n' "$set" "$pkg" "$r"
  done
done

echo
echo "################ --security-opt no-new-privileges"
run docker run --rm "$A" ls -l /bin/busybox
run docker run --rm "$D" ls -l /usr/bin/passwd /bin/su
SUID='cp /usr/bin/id /usr/local/bin/suid-id && chmod u+s /usr/local/bin/suid-id && su nobody -s /bin/sh -c "grep NoNewPrivs /proc/self/status; /usr/local/bin/suid-id"'
run docker run --rm "$D" sh -c "$SUID"
run docker run --rm --security-opt no-new-privileges "$D" sh -c "$SUID"
run docker run --rm --user 65534 --security-opt no-new-privileges "$D" su root -c id

echo
echo "################ --pids-limit 50"
run docker run --rm --pids-limit 50 "$A" sh -c 'for i in $(seq 100); do sleep 60 & done; sleep 1; ps | wc -l'
FORK='import os, time
ok, err = 0, None
for i in range(100):
    try:
        if os.fork() == 0:
            time.sleep(30)
            os._exit(0)
        ok += 1
    except OSError as e:
        err = e
cur = open("/sys/fs/cgroup/pids.current").read().strip()
mx = open("/sys/fs/cgroup/pids.max").read().strip()
print(f"fork réussis : {ok}/100, dernière erreur : {err}, pids.current={cur}, pids.max={mx}")'
run docker run --rm --pids-limit 50 "$P" python -c "$FORK"
run docker run --rm "$P" python -c "$FORK"
c=$(docker run -d --pids-limit 50 "$A" sleep 300)
for i in $(seq 60); do docker exec -d "$c" sleep 300 > /dev/null 2>&1; done
printf '\n$ docker run -d --pids-limit 50 alpine sleep 300 ; 60 x docker exec -d sleep 300\n'
echo "processus vus par docker top : $(docker top "$c" | tail -n +2 | wc -l | tr -d ' ') ; cgroup : $(colima ssh -- sh -c "cd /sys/fs/cgroup/docker/$(docker inspect "$c" -f '{{.Id}}') && echo pids.max=\$(cat pids.max) pids.current=\$(cat pids.current)")"
docker rm -f "$c" > /dev/null

echo
echo "################ --memory 32m"
c=$(docker run -d --memory 32m --memory-swap 32m "$P" python -c "x = 'a' * 100_000_000")
docker wait "$c" > /dev/null
run docker inspect "$c" --format 'OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}} limite={{.HostConfig.Memory}}'
docker rm "$c" > /dev/null
run docker run --rm --memory 256m "$P" python -c "x = 'a' * 100_000_000; print(len(x))"

echo
echo "################ --user 1000"
run docker run --rm --user 1000 "$A" id
run docker run --rm --user 1000:1000 "$A" id
docker volume create tp08-vol > /dev/null
run docker run --rm -v tp08-vol:/data "$A" sh -c 'touch /data/ecrit-par-root && ls -ln /data'
run docker run --rm --user 1000:1000 -v tp08-vol:/data "$A" touch /data/ecrit-par-1000
run docker run --rm -v tp08-vol:/data "$A" chown -R 1000:1000 /data
run docker run --rm --user 1000:1000 -v tp08-vol:/data "$A" sh -c 'touch /data/ecrit-par-1000 && ls -ln /data'
docker volume rm tp08-vol > /dev/null
mkdir -p .bind && chmod 755 .bind
run docker run --rm --user 1000:1000 -v "$PWD/.bind:/data" "$A" sh -c 'touch /data/x && ls -ln /data'
ls -ln .bind | sed 's/^/  vu depuis le Mac : /'
rm -rf .bind

echo
echo "################ seccomp"
run docker run --rm "$A" unshare --user id
run docker run --rm --security-opt seccomp=unconfined "$A" unshare --user id
run docker run --rm "$A" grep Seccomp /proc/self/status
run docker run --rm --security-opt seccomp=unconfined "$A" grep Seccomp /proc/self/status
printf '\n$ python3 seccomp_count.py seccomp-default.json  (profil moby/profiles, table ausyscall aarch64)\n'
docker run --rm -v "$PWD/experiences:/w:ro" "$P" sh -c 'apk add -q --no-progress audit > /dev/null 2>&1; python3 -I /w/seccomp_count.py /w/seccomp-default.json'
