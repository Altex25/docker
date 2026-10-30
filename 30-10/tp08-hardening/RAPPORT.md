# TP08 — Durcir les conteneurs pour la production

Environnement : Docker Engine 29.5.2 dans la VM Colima (arm64, cgroup v2). La stack visée est celle du TP04 (projet `shop`). Les bonus B1 à B4 n'ont pas été faits, comme demandé.

## Livrables

| Livrable | Fichier |
|---|---|
| Outil d'audit rejouable | [`audit.sh`](audit.sh) |
| Surcharge durcie de la stack TP04, commentée | [`compose.hardened.yml`](compose.hardened.yml) (chaque directive y est commentée avec la menace qu'elle réduit, et le tableau de l'étape 3 la résume) |
| Tableau des expériences | Étape 2 ci-dessous, rejouable avec [`experiences.sh`](experiences.sh) (sortie : [`diag/experiences.txt`](diag/experiences.txt)) |
| `daemon.json` justifié | [`daemon.json`](daemon.json), validé et testé par [`daemon-test.sh`](daemon-test.sh) (sortie : [`diag/daemon-test.txt`](diag/daemon-test.txt)) |
| Sortie d'`audit.sh` avant / après | [`diag/audit-avant.txt`](diag/audit-avant.txt), [`diag/audit-apres.txt`](diag/audit-apres.txt) |
| Autres preuves | Recherche des capabilities : [`essais-caps.sh`](essais-caps.sh) → [`diag/essais-caps.txt`](diag/essais-caps.txt). Effet réel : [`verif-durcie.sh`](verif-durcie.sh) → [`diag/verif-durcie.txt`](diag/verif-durcie.txt). Bench CIS : [`diag/docker-bench-avant.txt`](diag/docker-bench-avant.txt) et [`diag/docker-bench-apres.txt`](diag/docker-bench-apres.txt) |

Lancement, depuis le dossier du TP04 :

```bash
docker compose -f compose.yml -f ../../30-10/tp08-hardening/compose.hardened.yml --profile tools up -d --wait
COMPOSE="docker compose -f compose.yml -f ../../30-10/tp08-hardening/compose.hardened.yml" ./smoke-test.sh
../../30-10/tp08-hardening/audit.sh -p shop -x backup
```

## 1. Mesurer

### `audit.sh`

Pour chaque conteneur en cours d'exécution, `audit.sh` lit `docker inspect` et affiche :
- l'utilisateur (`Config.User` ; vide, `0` ou `root` comptent comme root) ;
- `Privileged` ;
- les capabilities retirées (`ALL` attendu) et ajoutées (une capability dangereuse ajoutée est un écart) ;
- le rootfs en lecture seule ;
- la limite mémoire et `PidsLimit` ;
- `no-new-privileges` ;
- le montage de la socket Docker.

Le code retour est 1 s'il reste un écart non accepté, 0 sinon.

**Options.**
- `-p projet` limite l'audit à un projet Compose ;
- `-f` ajoute un filtre `docker ps` ;
- `-x service` exclut un service ;
- `--json` donne une sortie exploitable en CI.

**Risque accepté.** Un écart assumé se déclare par le label `tp08.audit.accept=<contrôle,…>` sur le conteneur : il s'affiche avec `~` et n'échoue plus l'audit. Il reste visible et versionné dans le compose.

**Avant** (stack TP04 en mode dev, [`diag/audit-avant.txt`](diag/audit-avant.txt)) : **7 conteneurs, 40 écarts, code retour 1.**

| Contrôle | Conteneurs en écart |
|---|---|
| `cap_drop` absent, read-only absent, mémoire illimitée, PID illimités, `no-new-privileges` absent | 7 / 7 pour chacun |
| Utilisateur root | 4 (traefik, db, redis, backup) |
| Socket Docker montée | 1 (traefik) |

### docker-bench-security

**L'image du sujet ne fonctionne plus.** `docker/docker-bench-security` sur le Docker Hub date de **2019** (amd64 seulement). Son client parle une API Docker trop ancienne pour Docker 29, d'où `Error connecting to docker daemon`.

**Ce que j'ai lancé à la place.** Avec ton accord, j'ai construit la dernière release officielle (`v1.6.1`, CIS Docker Benchmark 1.6) depuis `github.com/docker/docker-bench-security`. Je l'ai exécutée avec exactement les options du sujet (`--net/--pid/--userns host`, `/etc`, `/var/lib` et la socket en lecture seule), dans la VM Colima.

**Résultat : 117 contrôles, score −6.** 35 contrôles en WARN, 35 en PASS, et le reste en INFO ou NOTE.

**Ce que le bench juge** : la VM Colima, et non le Mac. Les contrôles 1.1.x (auditd sur les fichiers Docker) et la partie hôte n'ont pas de sens pour une VM jetable. Le bench audite aussi **tous** les conteneurs de la VM : observabilité du TP07, registres du TP03, autres projets.

**Les 5 WARN jugés prioritaires :**

| # | Contrôle | Pourquoi c'est prioritaire | Où |
|---|---|---|---|
| 1 | 5.32 Socket Docker montée | Accès à la socket = root sur l'hôte (`docker run --privileged -v /:/host`) | `shop-traefik-1`, `observability-promtail-1` |
| 2 | 4.1 Conteneur lancé en root | Une évasion ou une faille noyau part de l'uid 0 ; root écrit partout dans le conteneur | `shop-traefik-1`, `shop-db-1`, `shop-redis-1`, `shop-backup-1` |
| 3 | 5.11 / 5.29 Pas de limite mémoire ni de PID | Une fuite ou une fork bomb dans un conteneur affame toute la machine (vu au TP07) | Tous les conteneurs `shop` |
| 4 | 5.26 / 2.14 `no-new-privileges` absent | Un binaire setuid de l'image permet de redevenir root (expérience de l'étape 2) | Tous |
| 5 | 5.5 Conteneurs privilégiés et 2.9 user namespaces absents | `--privileged` donne toutes les capabilities et les périphériques. Sans userns, root dans le conteneur = root sur l'hôte | `observability-cadvisor-1`, `buildx_buildkit_shop0` |

## 2. Comprendre chaque mesure

Toutes les expériences sont dans [`experiences.sh`](experiences.sh), et leurs sorties brutes dans [`diag/experiences.txt`](diag/experiences.txt).

| Mesure | Expérience | Résultat observé | Ce qu'il faut retenir |
|---|---|---|---|
| `--read-only` | `touch /x`, puis `--tmpfs /tmp` et `touch /tmp/x` | `touch: /x: Read-only file system`. Avec le tmpfs, `/tmp/x` est créé, et `/proc/mounts` montre `tmpfs /tmp … nosuid,nodev,noexec` | On ne peut plus déposer de binaire ni modifier l'image. On liste explicitement les seuls dossiers inscriptibles (tmpfs ou volumes), et ils sont `noexec` |
| `--cap-drop ALL` | `CapEff`, `ping`, `chown`, `apk add` | `CapEff` passe de `a80425fb` (14 capabilities par défaut) à `0`. **`ping` marche quand même** : Docker règle `net.ipv4.ping_group_range=0 2147483647`, qui autorise les sockets ICMP non privilégiés. Si on ferme cette plage (`--sysctl …=1 0`), on obtient `permission denied`, et il faut alors `NET_RAW`. `chown` : `Operation not permitted`, il faut `CHOWN`. `apk add curl` marche **sans aucune capability** (root écrit ses propres fichiers). `apk add nginx` demande `CHOWN`, `FOWNER` puis `DAC_OVERRIDE`, car il crée un utilisateur et change des propriétaires | On ne réajoute que ce qu'un essai prouve nécessaire. Piège : sans ces capabilities, `apk add nginx` **renvoie 0** malgré `ERROR: 4 errors updating directory permissions`. L'installation à l'exécution échoue en silence, c'est une raison de plus pour tout installer au build |
| `no-new-privileges` | `ls -l` sur `/bin/busybox` et `/usr/bin/passwd`, puis une copie setuid de `id` lancée en `nobody` | Busybox d'alpine n'est pas setuid ; `passwd` et `su` de Debian le sont (`-rwsr-xr-x`). Sans l'option : `uid=65534(nobody) … euid=0(root)`. Avec : `NoNewPrivs: 1` et l'euid reste 65534. `su root` depuis un utilisateur : `Authentication failure` | Un binaire setuid de l'image ne permet plus de redevenir root. C'est le complément indispensable de `--user` |
| `--pids-limit 50` | Boucle de 100 `sleep &`, puis 100 `fork()` en Python | Busybox `sh` : `can't fork: Resource temporarily unavailable` (le shell s'arrête). Python : **49 forks réussis sur 100**, puis `[Errno 11]`, avec `pids.current=50` et `pids.max=50`. Sans limite : 100 sur 100, 101 PID | Une fork bomb reste confinée au conteneur. Limite à connaître : **`docker exec` contourne la limite**. 60 `docker exec -d` donnent `pids.current=61` pour `pids.max=50`, car le noyau ne bloque que `fork()`, pas la migration d'un processus dans le cgroup |
| `--memory 32m` | `python -c "x='a'*100_000_000"` | `OOMKilled=true`, `ExitCode=137`. Avec 256 Mo, le script affiche `100000000` | Le noyau tue le conteneur fautif plutôt que de laisser la machine swapper ou tuer un voisin. Au TP07 : le working set redescend tant que la mémoire est récupérable |
| `--user 1000` | `id`, puis écriture dans un volume nommé et dans un bind mount | `uid=1000 gid=0(root)` : **sans GID, le groupe reste root**, d'où `--user 1000:1000`. Le volume neuf appartient à `0:0`, donc `Permission denied`. Après un `chown -R 1000:1000` fait en root, l'écriture marche. Dans un bind mount, le fichier est `1000:1000` dans le conteneur et `501:20` vu du Mac (virtiofs) | Il faut préparer les droits des volumes (image, `chown` initial, ou un uid aligné sur le volume existant, comme `70` pour PostgreSQL et `999` pour Redis). Les bind mounts dépendent de l'hôte |
| seccomp | `unshare --user` avec et sans `seccomp=unconfined` | Profil par défaut : `unshare(0x10000000): Operation not permitted`, `Seccomp: 2`. Sans profil : `uid=65534(nobody)` dans un nouveau user namespace, `Seccomp: 0` | **Sur les 325 appels système arm64** (`ausyscall aarch64`), le profil par défaut de moby en **bloque 61** et n'en autorise 3 que selon leurs arguments (`clone`, `personality`, `socket`). `CAP_SYS_ADMIN` en débloque 25 de plus. Sont bloqués notamment `mount`, `umount2`, `pivot_root`, `unshare`, `setns`, `bpf`, `keyctl`, `add_key`, `init_module`, `finit_module`, `delete_module`, `kexec_load`, `reboot`, `perf_event_open`, `open_by_handle_at`, `userfaultfd`, `clock_settime`, `swapon`. Calcul : [`experiences/seccomp_count.py`](experiences/seccomp_count.py) |

## 3. Durcir la stack

### Recherche des capabilities nécessaires

Les essais se font sur des conteneurs jetables, avec `cap_drop: ALL` et un rootfs en lecture seule ([`diag/essais-caps.txt`](diag/essais-caps.txt)).

**PostgreSQL, image par défaut.** L'entrypoint démarre en root, prépare le dossier de données, puis passe en `postgres` avec `su-exec`.

| `cap_add` | Résultat (logs) |
|---|---|
| aucune | `chmod: /var/run/postgresql: Operation not permitted`, `failed switching to "postgres": operation not permitted`, exit 1 |
| `CHOWN` | même échec, `su-exec` ne peut pas changer d'uid |
| `CHOWN,SETUID,SETGID` | démarre, mais `chmod: /var/lib/postgresql/data: Operation not permitted` |
| `+FOWNER` | `find: /var/lib/postgresql/data: Permission denied` : le dossier passe en `0700` à l'uid 70, et root sans `DAC_OVERRIDE` ne peut plus le parcourir |
| **`CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID`** | démarrage propre, volume neuf et volume existant |
| **aucune, avec `user: "70:70"`** | **démarrage propre** : il n'y a plus d'étape root |

**Traefik.**

| Configuration | Résultat |
|---|---|
| root, aucune capability | **écoute sur :80 sans `NET_BIND_SERVICE`** : Docker ≥ 20.10 met `net.ipv4.ip_unprivileged_port_start=0` dans chaque conteneur |
| root, aucune capability, seuil remis à 1024 | `listen tcp :80: bind: permission denied` |
| root + `NET_BIND_SERVICE`, seuil 1024 | OK : c'est la capability dont Traefik a besoin sur un moteur qui garde le seuil historique |
| `65534` + `NET_BIND_SERVICE`, seuil 1024 | `permission denied` : pour un utilisateur non root, `cap_add` ne remplit pas les capabilities effectives (pas de capabilities ambiantes) |
| `65534`, aucune capability, seuil ≤ 80 | OK |

**Choix retenu** : faire tourner les deux services sous un uid non root plutôt que de leur rendre des capabilities.
- PostgreSQL tourne en `70:70` avec **zéro capability** (son volume appartient déjà à l'uid 70).
- Traefik tourne en `65534` avec **zéro capability**, et un `sysctls: net.ipv4.ip_unprivileged_port_start: 80` explicite, pour ne pas dépendre d'un défaut du moteur.

### [`compose.hardened.yml`](compose.hardened.yml) : menace réduite par directive

| Directive | Services | Menace réduite |
|---|---|---|
| `read_only: true` (+ `tmpfs` ciblés : `/tmp`, `/var/run/postgresql`, `/run` du proxy) | tous | Dépôt d'un binaire ou d'un webshell, modification des scripts de l'image, persistance d'un attaquant. Les seules zones inscriptibles sont des tmpfs `noexec` ou les volumes de données |
| `cap_drop: [ALL]`, **aucun** `cap_add` | tous | Les 14 capabilities par défaut disparaissent (`CHOWN`, `DAC_OVERRIDE`, `NET_RAW`, `MKNOD`, `SETUID`…) : plus de `chown`/`chmod` arbitraire, plus de socket raw (usurpation ARP ou ICMP), plus de `mknod` |
| `security_opt: no-new-privileges:true` | tous | Escalade par un binaire setuid ou setgid de l'image (expérience de l'étape 2) |
| `user:` non root (`70:70` db, `999:1000` redis, `1000:1000` api, `10001:10001` worker, `65534` traefik et proxy, `adminer`) | tous | Une évasion ou une faille noyau part d'un uid non privilégié. Redis passe en non-root comme demandé, ses données appartiennent déjà à `999:1000` |
| `deploy.resources.limits.memory` / `cpus` | tous | Déni de service par fuite mémoire ou boucle CPU : le noyau tue ou bride le conteneur fautif, pas la machine |
| `deploy.resources.limits.pids` (32 à 128) | tous | Fork bomb (voir l'étape 2). Les `pids_limit` de service et le bloc `deploy` sont incompatibles dans Compose, d'où `deploy.resources.limits.pids` |
| `volumes: !reset []` sur traefik | traefik | **La socket Docker n'est plus montée** : un Traefik compromis n'est plus root sur l'hôte |
| `TRAEFIK_PROVIDERS_DOCKER_ENDPOINT: tcp://socket-proxy:2375` | traefik | Traefik lit l'API Docker par le proxy filtrant |
| `sysctls: net.ipv4.ip_unprivileged_port_start: 80` | traefik | Écouter sur :80 en non-root et sans capability. Le seuil est limité à l'espace réseau du conteneur |
| service `socket-proxy` (`tecnativa/docker-socket-proxy` v0.4.1, épinglé par digest) | proxy | Seuls `CONTAINERS`, `EVENTS`, `PING` et `VERSION` sont ouverts. `POST=0` refuse toute écriture (création, arrêt, exec, suppression). Socket montée en `:ro`. Le proxy tourne en `65534:991` (le gid du groupe `docker` de la VM, surchargeable par `DOCKER_SOCKET_GID`), sans capability, en lecture seule |
| réseau `socket` avec `internal: true` | proxy, traefik | Le proxy n'est joignable que par Traefik : pas de sortie Internet, pas de port publié, et l'API ou le worker ne le voient pas |
| label `tp08.audit.accept: docker_sock` | proxy | Risque résiduel accepté et tracé : le proxy doit monter la socket, mais il est réduit à une API en lecture seule et filtrée |
| `PYTHONDONTWRITEBYTECODE=1` | worker | Évite les tentatives d'écriture de `.pyc` sur un rootfs en lecture seule |

Le fichier durcit aussi `adminer` (profil `tools`) et `migrate` (profil `ops`).

### Validation

- **Démarrage** : `docker compose -f compose.yml -f compose.hardened.yml --profile tools up -d --wait` ramène les **8 conteneurs en `healthy` du premier coup** (socket-proxy, traefik, db, redis, api, worker, adminer et le backup existant).
- **Smoke test du TP04 : vert.**
  - `/ready` répond `{"status":"ready","checks":{"db":"ok","redis":"ok"}}` ;
  - `/products` renvoie 3 produits avec `X-Cache: HIT` ;
  - une commande de 2 articles passe `pending -> confirmed` par le worker, une de 500 passe `pending -> rejected` ;
  - Adminer répond 200 via Traefik.
- **`audit.sh -p shop -x backup` : 7 conteneurs, 0 écart, 1 écart accepté, code retour 0** ([`diag/audit-apres.txt`](diag/audit-apres.txt)).

```text
CONTENEUR              UTILISATEUR PRIVILEGED  DROP   CAP_ADD   RO     MÉMOIRE  PIDS  NNP    SOCKET  ÉCARTS
shop-api-1             1000:1000   false       ALL    -         true   256M     128   true   -       0
shop-worker-1          10001:10001 false       ALL    -         true   256M     64    true   -       0
shop-adminer-1         adminer     false       ALL    -         true   128M     64    true   -       0
shop-db-1              70:70       false       ALL    -         true   512M     128   true   -       0
shop-redis-1           999:1000    false       ALL    -         true   256M     64    true   -       0
shop-traefik-1         65534:65534 false       ALL    -         true   128M     128   true   -       0
shop-socket-proxy-1    65534:991   false       ALL    -         true   64M      64    true   ~montée 0
```

**L'effet est vérifié dans chaque conteneur**, et pas seulement dans la configuration ([`diag/verif-durcie.txt`](diag/verif-durcie.txt)) :
- `id` est non root partout ;
- `CapEff` vaut `0000000000000000` partout et `NoNewPrivs` vaut `1` ;
- `touch /` est refusé ;
- `memory.max` et `pids.max` du cgroup correspondent aux limites.

**Côté socket et proxy :**
- `/var/run/docker.sock` n'existe plus dans Traefik.
- Le proxy répond 200 à `GET /version`, `/containers/json` et `/events`.
- Il répond **403** à `/images/json`, `/info`, `/secrets`, `POST /containers/create`, `DELETE /containers/…` et `POST /containers/…/exec`.
- Le réseau `shop_socket` est `internal=true` et ne contient que le proxy et Traefik. L'API ne résout même pas `socket-proxy` (`ENOTFOUND`).

**Bench CIS après durcissement** ([`diag/docker-bench-apres.txt`](diag/docker-bench-apres.txt)) :
- **Le score global reste à −6.** En section 5, un contrôle échoue dès qu'**un** conteneur de la VM est en défaut, et la VM fait tourner bien d'autres projets.
- **Mesure utile** : les lignes WARN qui visent le projet `shop` passent de **60 à 19**. Il reste :
  - 8 lignes du sidecar `shop-backup-1` (TP05, hors périmètre) ;
  - le 5.15 (politique `on-failure:5`), une ligne par conteneur : `unless-stopped` est gardé pour la disponibilité, au prix d'une boucle de redémarrage possible, que l'alerte `ContainerRestarting` du TP07 détecte ;
  - 5.8, 5.9 et 5.14 pour Traefik : c'est le point d'entrée HTTP, son port 80 est publié volontairement ;
  - 5.32 pour le proxy, accepté.

**Hors périmètre et risques résiduels :**
- **Le sidecar `backup`** (ajouté au TP05 par `compose.backup.yml`) tourne toujours en root et écrit dans un dossier du Mac. Le durcir demande un utilisateur aligné sur ce bind mount ; il reste en écart, exclu par `-x backup`.
- **`GET /containers/{id}/json` reste autorisé** par le proxy, car Traefik en a besoin. Il expose les variables d'environnement des conteneurs : les secrets doivent rester des fichiers (`*_FILE`, secrets Compose), comme c'est le cas ici.
- **La surcharge dev du TP04** (`compose.override.yml`) n'est pas durcie : bind mount des sources, `node --watch`, ports de debug.

## 4. Côté daemon

[`daemon.json`](daemon.json) :

| Clé | Justification |
|---|---|
| `"icc": false` | Coupe le trafic entre conteneurs sur le **bridge par défaut** (CIS 2.2). Il faut des réseaux utilisateurs explicites |
| `"no-new-privileges": true` | Applique `no-new-privileges` à **tous** les conteneurs, même ceux qui l'oublient (CIS 2.14) |
| `"live-restore": true` | Les conteneurs continuent de tourner pendant un redémarrage ou une mise à jour du daemon (CIS 2.15). Incompatible avec le mode Swarm |
| `"userland-proxy": false` | Les ports publiés passent par iptables/nftables plutôt que par un processus `docker-proxy` par port (CIS 2.16) |
| `"userns-remap": "default"` | Root dans un conteneur devient un uid non privilégié de l'hôte (`dockremap`, plage `165536:65536`) (CIS 2.9) |
| `"log-driver": "local"` + `max-size 10m` / `max-file 5` | Logs rotatifs et compressés par défaut : plus de disque plein (TP07 : 272 Mo en quelques secondes sans `max-size`) |
| `"log-level": "info"` | CIS 2.3 : ni `debug` (trop verbeux, fuite d'informations) ni silence |
| `"default-ulimits"` (`nofile` 65536) | Borne explicite au lieu de l'héritage de l'hôte |
| `"default-address-pools"` 10.201.0.0/16 en /24 | Évite les conflits avec un VPN d'entreprise (TP06, bonus B4) |

**Validation sans toucher au daemon de Colima** ([`daemon-test.sh`](daemon-test.sh)) :
- `dockerd --validate` répond `configuration OK` ;
- un `docker:28.5-dind` jetable, redémarré avec ce fichier, affiche `SecurityOptions=[…,"name=userns","name=cgroupns","name=no-new-privileges"]`, `LiveRestore=true` et `LoggingDriver=local`.

**Effets de bord d'`icc: false`.**
- Sur le bridge par défaut, un `ping` d'un conteneur vers un autre réussit (`OK`) avant, et **échoue** après.
- Sur un réseau utilisateur (`app`), le `ping` **réussit toujours**.
- La stack du TP04 n'utilise que des réseaux utilisateurs (`front`, `back`, `socket`) : **aucun effet sur elle**.
- Ça casse ce qui s'appuie sur le bridge par défaut : `docker run` sans `--network` qui doit parler à un autre conteneur, et les anciens `--link`. Ces derniers fonctionnent encore, car Docker ajoute alors une règle d'autorisation explicite.
- Pour isoler aussi un réseau utilisateur, il faut l'option par réseau `com.docker.network.bridge.enable_icc=false` (TP06, bonus B3).

**Effets de bord de `userns-remap` sur les volumes existants.**
- **Tout semble avoir disparu.** Le daemon travaille dans une nouvelle racine, `DockerRootDir=/var/lib/docker/165536.165536`. Les images et volumes existants deviennent invisibles (`volumes : []`, `images : []`) : tout est à re-télécharger ou à migrer.
- **Les uid changent.** `root` dans un conteneur apparaît en `165536` côté hôte, et un nouveau volume est créé en `165536:165536`.
- **Les anciennes données deviennent inaccessibles en écriture.** Un ancien volume (fichier à `0:0`) monté dans un conteneur remappé apparaît en `65534:65534` (uid hors plage), et l'écriture donne `Permission denied`. Pour migrer, il faut un `chown -R` décalé de 165536 sur les données.
- **`--privileged` est refusé** (`privileged mode is incompatible with user namespaces`), sauf avec `--userns host`. cAdvisor, docker-bench, BuildKit et tout conteneur qui a besoin de l'hôte doivent le préciser.

**Rootless, l'alternative.** Le daemon lui-même tourne sous un utilisateur non privilégié, donc une évasion ne donne même pas root sur l'hôte.

Les contreparties :
- les ports inférieurs à 1024 ne sont pas publiables sans régler `net.ipv4.ip_unprivileged_port_start` ;
- le réseau passe par `slirp4netns`/`pasta`, ce qui est plus lent ;
- pas d'`AppArmor` ni de `--privileged` réel ;
- les volumes sont dans `~/.local/share/docker`.

Pour une machine de production mono-locataire, `userns-remap` est le meilleur compromis. Pour des postes ou des runners CI partagés, rootless est préférable.

**Le fichier n'est pas appliqué au daemon Colima.**
- Il faudrait le reporter dans la clé `docker:` de `~/.colima/default/colima.yaml`, puis redémarrer Colima.
- `userns-remap` masquerait les images et volumes de tous les TP précédents, comme démontré ci-dessus.
- Il est prêt pour un hôte de production neuf.

## Écarts et état laissé

- **docker-bench** : l'image `docker/docker-bench-security` du sujet (2019) ne parle plus à Docker 29. La release v1.6.1 a été construite depuis le dépôt officiel, avec ton accord.
- **Commentaires** : seul `compose.hardened.yml` est commenté, parce que le sujet le demande. Les autres fichiers n'en ont pas.
- **Bonus** : non faits, comme demandé.
- **État laissé** :
  - la stack TP04 est revenue à sa configuration dev ; son smoke test repasse au vert (`== OK`) ;
  - le proxy et le réseau `shop_socket` sont supprimés ;
  - les conteneurs et volumes de test (`tp08-*`, `tp08-dind`) sont supprimés ;
  - l'image `tp08/docker-bench-security:1.6.1` reste en local pour rejouer le bench ;
  - pour rejouer la version durcie, voir « Lancement ».
