# Rapport d'incident — préprod Shop SAS

**Heure de début** : 15:28 (prise d'astreinte, premier `docker compose config`) · **Heure de résolution** : 15:33:36 (stack complète `healthy`, `X-Cache: HIT`), vérification de bout en bout à 15:36 · **Impact** : préprod indisponible (port 8081 sans réponse, puis 502 et 500)

Environnement : Docker Engine 29.5.2, Docker Compose v5.1.4, VM Colima (arm64). Le code de l'API et son Dockerfile n'ont pas été modifiés. Seuls `compose.yml` et `nginx/default.conf` ont été corrigés. Le dossier `starter/` est laissé tel quel pour garder la référence de départ.

| Livrable | Fichier |
|---|---|
| Compose corrigé | [`compose.yml`](compose.yml), mots de passe dans `.env` (gitignoré, modèle [`.env.example`](.env.example)) |
| Conf nginx corrigée | [`nginx/default.conf`](nginx/default.conf) |
| Vérification de bout en bout | [`verify.sh`](verify.sh), sortie dans [`diag/partie2-verification.txt`](diag/partie2-verification.txt) |
| Partie 1 | [`partie1.sh`](partie1.sh), sortie dans [`diag/partie1-rappels.txt`](diag/partie1-rappels.txt) |
| Piège de l'alias perdu | [`annexes/perte-alias.sh`](annexes/perte-alias.sh), sortie dans [`diag/partie2-perte-alias.txt`](diag/partie2-perte-alias.txt) |
| Bonus | [`bonus/`](bonus), sorties dans `diag/bonus-*.txt` |

Lancement :

```bash
cp .env.example .env
docker compose up -d --wait
./verify.sh
```

## Partie 1 — Rappels réseau

Transcript complet : [`diag/partie1-rappels.txt`](diag/partie1-rappels.txt).

| Notion | Constat sur cette machine |
|---|---|
| Bridge par défaut | `172.17.0.0/16`, `icc=true`. `ping tp06-b` donne `bad address` (pas de DNS), alors que `ping 172.17.0.4` passe. `/etc/resolv.conf` est une copie de l'hôte (`nameserver 192.168.5.1`) |
| Réseau utilisateur | Après `network connect demo`, `ping tp06-b` passe et `ping bravo` (alias) aussi. `resolv.conf` devient `nameserver 127.0.0.11` (DNS embarqué du daemon, qui transmet le reste à `192.168.5.1`) |
| `container:` | netshoot lancé en `--network container:tp06-a` voit les mêmes interfaces (`eth0` bridge, `eth1` demo) et le `nc -l 9999` lancé dans `tp06-a`. On débogue sans rien installer dans l'image |
| `internal: true` | Pas de sortie : `wget example.com` donne `bad address`. Un `-p 18081:80` est accepté mais **ignoré** : `docker port` est vide et `curl` renvoie `000` |
| `none` | Seulement `lo` |
| `host` | Le conteneur voit les interfaces de **la VM Colima** (`eth0 192.168.5.1`, `docker0`, onze `br-*`) et `hostname=colima`, pas celles du Mac |
| `-p` et `expose` | `--expose 80` remplit `ExposedPorts` mais laisse `PortBindings={}` et `docker port` vide. `-p 18081:80` pose une règle DNAT dans la VM : `-A DOCKER ! -i docker0 -p tcp --dport 18081 -j DNAT --to-destination 172.17.0.5:80` |

Docker 29 refuse les noms de conteneur d'un seul caractère : `docker run --name a` renvoie `Invalid container name (a), only [a-zA-Z0-9][a-zA-Z0-9_.-] are allowed`. Les commandes du sujet ont donc été jouées avec `tp06-a` et `tp06-b`.

## Chronologie du diagnostic

On part du symptôme utilisateur (port 8081) et on remonte la chaîne front → api → db/redis, une couche à la fois.

| Heure | Symptôme observé | Commande / preuve | Hypothèse | Résultat |
|-------|------------------|-------------------|-----------|----------|
| 15:28:19 | `docker compose up` ne démarre rien | `docker compose config -q` : `can't set container_name and api as container name must be unique` | `container_name` fixe et `replicas: 2` sont incompatibles | Confirmé, `container_name` supprimé (#1) |
| 15:28:29 | Le build échoue sur le contexte | `build: ../../tp04-compose-entreprise/solution/apps/shopapi` : ce chemin n'existe pas dans ce dépôt | Chemin écrit pour le dépôt du formateur | Adapté vers `../tp04-compose-entreprise/apps/shopapi` (voir l'écart d'environnement) |
| 15:28:29 | db et api démarrent, front refuse | `error mounting ".../nginx" to rootfs at "/etc/nginx/conf.d/default.conf" ... Are you trying to mount a directory onto a file` | Un dossier est monté sur un fichier | Confirmé (#2) |
| 15:29:01 | Les deux `api` sont `Exited (1)` | `docker compose logs api` : `Error: Cannot find module '/app/server.js'`. Dans l'image, `ls` montre `src/server.js` | `command:` écrase le `CMD` de l'image avec un mauvais chemin | Confirmé (#6). `RestartPolicy=no` : rien ne relance l'API (#15) |
| 15:29:01 | db `healthy`, mais un `FATAL` toutes les 5 s | `docker compose logs db` : `FATAL: role "postgres" does not exist` | Le healthcheck interroge un rôle qui n'existe pas | Confirmé (#12) |
| 15:29:19 | front `Up`, mais `curl :8081` renvoie `000` | `docker port incident-front-1` est vide. `docker network inspect incident_public` : `internal=true` | Un réseau `internal` ne publie pas de port | Confirmé, `public` n'est plus internal et `backend` le devient (#3, #16) |
| 15:29:31 | `/health` répond 200, mais `/products` renvoie 502 | Logs nginx : `connect() failed (111: Connection refused) ... upstream: "http://127.0.0.1:3000/products"` | `localhost` désigne le conteneur nginx lui-même | Confirmé (#4) |
| 15:29:50 | `nginx -s reload` échoue après la correction de la conf | `open() "/etc/nginx/conf.d/default.conf" failed (2: No such file or directory)` | Un bind mount de **fichier** suit l'inode : l'éditeur a remplacé le fichier, le conteneur voit l'ancien | Confirmé, on monte le dossier `./nginx:/etc/nginx/conf.d:ro` (#2) |
| 15:30:00 | 502 : `api could not be resolved (3: Host not found)` | `docker compose ps` : api `Exited` | Le DNS embarqué ne publie que les conteneurs en marche | Confirmé, il faut d'abord faire démarrer l'API |
| 15:30:06 | L'API tourne mais reste `health: starting` | `wget 127.0.0.1:3000/health` : refusé. `wget 127.0.0.1:8080/health` : `{"status":"ok"}` | `PORT: 8080` ne correspond ni à nginx (3000) ni au healthcheck de l'image (3000) | Confirmé (#7) |
| 15:30:33 | API `healthy`, `/products` renvoie 500 | `/ready` : `getaddrinfo ENOTFOUND databse` | Faute de frappe dans `DATABASE_URL` | Confirmé (#8) |
| 15:30:48 | `ENOTFOUND db` | `docker inspect` : api seulement sur `incident_public`. `docker network inspect incident_backend` : seul `incident-db-1` | L'API n'est pas sur le réseau de la base | Confirmé (#9) |
| 15:31:06 | API branchée sur `backend`, toujours `ENOTFOUND db` | Même `NetworkID` pour db et api, mais `nslookup db 127.0.0.11` renvoie `NXDOMAIN`. `DNSNames` de db : `["incident-db-1","e615a2fa2415"]`, sans l'alias `db` | Quand le réseau est passé en `internal`, Compose l'a recréé et a rebranché db **sans l'alias de service** | Confirmé et reproduit à part ([`diag/partie2-perte-alias.txt`](diag/partie2-perte-alias.txt)). `--force-recreate db` répare |
| 15:32:20 | `db: ok`, Redis : `Reached the max retries per request limit` | Logs api : `ENOTFOUND redis`. `NetworkMode=host`. Dans la VM, `ss -tln` montre `0.0.0.0:6379` | En `network_mode: host`, Redis n'a pas de nom DNS et écoute sur toutes les interfaces de la VM | Confirmé (#10) |
| 15:32:51 | Redis sur `backend` : `NOAUTH Authentication required.` | `/ready` | `REDIS_URL` ne contient pas le mot de passe exigé par `--requirepass` | Confirmé (#11) |
| 15:33:36 | Compose final | `docker compose up -d --wait` : 5/5 `healthy`. `curl` deux fois : `X-Cache: MISS` puis `X-Cache: HIT`. `/ready` : `{"db":"ok","redis":"ok"}` | — | **Résolu** |
| 15:36 | Vérification depuis zéro | `./verify.sh` : `down -v`, puis `up --wait` en 5 s, MISS/HIT, changement d'IP de l'API, crash, isolation, secrets | — | OK ([`diag/partie2-verification.txt`](diag/partie2-verification.txt)) |

## Anomalies trouvées

| # | Fichier / service | Anomalie | Correction | Catégorie (réseau / config / cycle de vie / stockage / sécurité) |
|---|-------------------|----------|------------|----------|
| 1 | `compose.yml` / api | `container_name: api` avec `deploy.replicas: 2` : projet invalide, rien ne démarre | `container_name` supprimé. Les réplicas s'appellent `incident-api-1` et `incident-api-2`, et le nom `api` reste résolu par le DNS (alias de service) | cycle de vie |
| 2 | `compose.yml` / front | `./nginx` (un dossier) monté sur `/etc/nginx/conf.d/default.conf` (un fichier) | `./nginx:/etc/nginx/conf.d:ro`. On monte le dossier : un bind mount de fichier garde l'ancien inode quand un éditeur réécrit le fichier (constaté à 15:29:50) | stockage |
| 3 | `compose.yml` / réseaux | `public: internal: true` : le port 8081 de front n'est jamais publié | `public: {}` | réseau |
| 4 | `default.conf` | `proxy_pass http://localhost:3000` vise nginx lui-même | `proxy_pass` vers `http://api:3000` | réseau |
| 5 | `default.conf` | Aucun `resolver` : avec un nom fixe, nginx résout `api` une seule fois au démarrage. Il refuse de démarrer si l'API n'est pas encore là, et garde des IP périmées quand les réplicas sont recréés. Aucun timeout explicite | `resolver 127.0.0.11 valid=10s` et `set $api` (résolution à chaque requête, tourniquet sur les 2 réplicas), en-têtes `X-Forwarded-*`, `proxy_connect_timeout 3s`, `proxy_read_timeout 15s`, `default_type text/plain` sur `/health` | réseau |
| 6 | `compose.yml` / api | `command: node server.js`, alors que l'image contient `src/server.js` : `MODULE_NOT_FOUND` | `command` supprimée, le `CMD` de l'image s'applique | config |
| 7 | `compose.yml` / api | `PORT: 8080`, alors que nginx et le healthcheck de l'image attendent 3000 | `PORT: 3000` | config |
| 8 | `compose.yml` / api | `DATABASE_URL` pointe sur `databse` (faute de frappe) | `@db:5432` | config |
| 9 | `compose.yml` / api | api seulement sur `public`, alors que db et redis sont sur `backend` | api sur `public` et `backend` (c'est le seul service à cheval sur les deux) | réseau |
| 10 | `compose.yml` / redis | `network_mode: host` : pas de nom DNS `redis`, et Redis écoute sur `0.0.0.0:6379` de la VM, hors de tout réseau Compose | Redis sur `backend` (internal). Plus aucun port 6379 ouvert sur la VM | réseau / sécurité |
| 11 | `compose.yml` / api | `REDIS_URL` sans mot de passe : `NOAUTH`, donc pas de cache | `redis://:${REDIS_PASSWORD}@redis:6379` | config |
| 12 | `compose.yml` / db | Healthcheck `pg_isready -U postgres` : le rôle n'existe pas (un `FATAL` toutes les 5 s), et sans `-h` on teste la socket Unix, déjà ouverte pendant l'init (serveur temporaire), donc la base peut être `healthy` trop tôt | `pg_isready -h 127.0.0.1 -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"`, avec `start_period` et `start_interval` | cycle de vie |
| 13 | `compose.yml` / front, api | `front` dépend de `api` sans condition (nginx démarre avant l'API), et `api` ne dépend pas de `redis` | `api: condition: service_healthy` pour front. `db` (avec `restart: true`) et `redis` en `service_healthy` pour api | cycle de vie |
| 14 | `compose.yml` / front, redis | Pas de healthcheck : l'objectif « tout `healthy` » est impossible et `--wait` n'attend rien | `wget /health` pour front, `redis-cli ping` authentifié via `REDISCLI_AUTH` pour redis | cycle de vie |
| 15 | `compose.yml` / tous | Aucune politique de redémarrage : l'API plantée est restée `Exited (1)` | `restart: unless-stopped` (ancre YAML). Testé : après un `kill -9` du processus node depuis la VM, `RestartCount=1`, l'API redevient `healthy`, et le service continue grâce au second réplica | cycle de vie |
| 16 | `compose.yml` / réseaux | Les réseaux sont inversés : c'est `backend` (db, redis) qui doit être `internal`. Avant, la base pouvait sortir sur Internet | `backend: internal: true`. Après correction, `wget example.com` depuis db donne `bad address`, et `getent hosts db` depuis front ne renvoie rien | sécurité / réseau |
| 17 | `compose.yml` / db, redis, api | Mots de passe en clair dans le compose versionné. `--requirepass r3dis` est visible dans `docker inspect` et `docker top`, et `redis-cli -a` l'exposerait aussi | Interpolation `${POSTGRES_PASSWORD:?…}` et `${REDIS_PASSWORD:?…}` depuis `.env` (gitignoré, prouvé par `git check-ignore`). Redis lit sa conf sur l'entrée standard (`redis-server -`), donc `docker top` n'affiche plus que `redis-server *:6379` | sécurité |
| 18 | `compose.yml` / redis | Pas de volume : la file `orders:queue` (des commandes alimentées par `POST /orders`) disparaît à chaque recréation | Volume `redisdata:/data` et `appendonly yes` | stockage |
| 19 | `compose.yml` / images | Tags flottants (`nginx:1.27-alpine`, `postgres:16.4-alpine`, `redis:7.4-alpine`) : la préprod peut changer sans commit | Épinglage par digest `@sha256:…`, et un nom d'image explicite `incident/shopapi:local` pour le build | sécurité |

**Écart d'environnement (hors anomalies).** Les chemins `../../tp04-compose-entreprise/solution/...` visent un dossier `solution/` qui n'existe pas dans ce dépôt. Le compose corrigé est à la racine du TP06, et non dans `starter/`. Il pointe donc vers `../tp04-compose-entreprise/apps/shopapi` et `../tp04-compose-entreprise/db/init.sql`, c'est-à-dire l'API et le schéma de mon TP04, réalisés à partir des TP01 et TP02.

**Piège d'exploitation rencontré (hors fichier).** Quand on change une option d'un réseau existant (`internal`, `driver_opts`…), `docker compose up` supprime puis recrée le réseau, et **redémarre** les conteneurs sans les recréer. Avec Compose v5.1.4, ils sont rebranchés sans leur alias de service : `db` disparaît des `DNSNames` et l'API reçoit `NXDOMAIN`. La reproduction minimale est dans [`annexes/perte-alias.sh`](annexes/perte-alias.sh). Règle à appliquer : après toute modification de réseau, lancer `docker compose up -d --force-recreate`, ou faire `down` puis `up`. Le bonus B3 applique cette règle.

### Classement

| Catégorie | Anomalies |
|---|---|
| Réseau | #3, #4, #5, #9, #10, #16 |
| Configuration | #6, #7, #8, #11 |
| Cycle de vie | #1, #12, #13, #14, #15 |
| Stockage | #2, #18 |
| Sécurité | #10, #16, #17, #19 |

## Pourquoi ça n'a pas été détecté avant ?

- **Le compose n'a jamais été validé.** Un simple `docker compose config -q` renvoyait déjà l'erreur `container_name` / `replicas` (#1).
- **Aucun test ne lance la stack.** Les autres anomalies ne se voient qu'à l'exécution : faute de frappe dans un nom d'hôte, mauvais port, mauvais chemin de `command`, montage dossier sur fichier, réseau `internal` qui avale silencieusement le `-p`. Un `up --wait` suivi d'un `curl` aurait tout montré.
- **Les healthchecks étaient absents ou faux.** Ce n'est pas la stack qui a signalé l'incident, ce sont les utilisateurs. Le healthcheck de la base « réussissait » tout en écrivant un `FATAL` toutes les 5 s. Front et Redis n'en avaient pas.
- **Les healthchecks rassurent à tort.** Celui de l'API teste `/health` (le processus vit), pas `/ready` (ses dépendances répondent). Le bonus B3 le montre : base injoignable, tout reste `healthy`, et les utilisateurs reçoivent un 504.
- **Il n'y a pas eu de revue.** La modification a été poussée juste avant un congé, sans relecture, sans description et sans plan de retour arrière.
- **Certaines anomalies sont silencieuses.** Mots de passe en clair, Redis exposé en mode `host`, réseaux inversés, tags flottants : rien ne casse, mais la stack est exposée. Seule une règle automatique peut les attraper.

## Actions de prévention

1. **Validation et lint du compose en CI**, bloquants à chaque PR :
   - `docker compose config -q` avec un `.env` de CI ;
   - un lint de compose (`dclint`) ;
   - des règles de politique (OPA/`conftest`) qui refusent : `network_mode: host`, `container_name` avec `replicas`, image sans digest, `POSTGRES_PASSWORD` ou `--requirepass` littéral, service sans `healthcheck`, `ports` sur un réseau `internal`.
2. **Smoke test de bout en bout en CI** : `docker compose up -d --wait --wait-timeout 120`, puis [`verify.sh`](verify.sh) en version réduite. Il vérifie :
   - `/products` deux fois, avec `X-Cache: MISS` puis `HIT` ;
   - `/ready` qui renvoie `db: ok` et `redis: ok` ;
   - `docker compose ps` entièrement `healthy` ;
   - en cas d'échec : `docker compose logs`, puis `down -v`.
3. **Healthchecks utiles et démarrage ordonné.**
   - Chaque service a un healthcheck qui teste vraiment le service (`pg_isready` en TCP avec le bon rôle, `redis-cli ping` authentifié, `/health` côté nginx).
   - `depends_on: condition: service_healthy` partout, et `--wait` dans les scripts de déploiement.
   - Une sonde de supervision interroge `/ready` (et pas seulement `/health`) pour alerter quand une dépendance tombe.
4. **Revue de code obligatoire** sur `compose*.yml` et `nginx/` : `CODEOWNERS` équipe plateforme, PR petites et décrites, aucun merge sans relecteur disponible, et une procédure de retour arrière écrite (`git revert` + `up -d --force-recreate`).
5. **Configuration hors du compose** : `.env` non versionné (ou Docker secrets en Swarm, un coffre en prod), images épinglées par digest et mises à jour par Renovate, en PR relue.

## Bonus

### B1 — tcpdump API → PostgreSQL

Script [`bonus/b1-tcpdump.sh`](bonus/b1-tcpdump.sh), sortie dans [`diag/bonus-b1-tcpdump.txt`](diag/bonus-b1-tcpdump.txt).

- **La capture.** netshoot est lancé en `--network container:incident-api-1` avec `tcpdump -i any -A 'tcp port 5432'`. On attend plus de 10 s pour que le pool `pg` ferme sa connexion inactive, on vide la clé `products` dans Redis, puis on appelle `/products`.
- **Résultat.** 14 paquets sont capturés :
  - le démarrage de session en clair (`user shop database shop`, mécanisme `SCRAM-SHA-256`) ;
  - le paquet `172.26.0.4.40708 > 172.26.0.2.5432` qui contient `SELECT id, name, price, stock FROM products ORDER BY id` ;
  - la réponse lisible (`Clavier m…`, `Souris sans fil`, `SELECT 3`).
- **Côté serveur.** `SHOW ssl` renvoie `off`, et aucune des 2 connexions actives n'est chiffrée (`0 / 2`).
- **Conclusion.** Un réseau bridge Docker isole, mais ne chiffre pas. Tout conteneur qui partage la pile réseau (`container:`), ou qui a un accès root à la VM, lit les requêtes et les données. Le mot de passe, lui, ne circule pas en clair grâce à SCRAM. Pour du trafic sensible (prod, multi-hôte, overlay sans `--opt encrypted`), il faut TLS de bout en bout : `ssl=on` côté PostgreSQL avec un certificat, `sslmode=verify-full` dans `DATABASE_URL`, et `rediss://` pour Redis.

### B2 — alias réseau `database`

Fichiers [`bonus/compose.b2-alias.yml`](bonus/compose.b2-alias.yml) et [`bonus/compose.b2-bascule.yml`](bonus/compose.b2-bascule.yml), script [`bonus/b2-alias.sh`](bonus/b2-alias.sh), sortie dans [`diag/bonus-b2-alias.txt`](diag/bonus-b2-alias.txt).

1. `db` reçoit `networks: backend: aliases: [database]` et l'API utilise `@database:5432`. `DNSNames` de db : `["incident-db-1","db","database",…]`, et `database` se résout vers l'IP de db.
2. Une nouvelle base `db-next` (profil `bascule`) est préparée à côté. Ses produits sont marqués `[db-next]`.
3. Bascule : l'override `compose.b2-bascule.yml` fait passer l'alias de db (`!reset []`) à db-next. Il suffit de `up -d --wait db db-next`, et la bascule prend **2 s**.
   - Les conteneurs api gardent le **même ID** et la même `DATABASE_URL`.
   - `database` pointe maintenant vers db-next.
   - Le catalogue renvoie `Clavier mécanique [db-next], …`.
4. Retour à la configuration nominale avec `--remove-orphans`, puis suppression du volume `incident_pgdata-next`.

**Intérêt.** L'application connaît un nom **fonctionnel** (`database`), pas un service précis. On peut migrer, monter de version, restaurer ou basculer sur un réplica en déplaçant l'alias, sans toucher la configuration de l'application, sans la reconstruire ni la redéployer. Le retour arrière se fait de la même façon. Il faut seulement que l'application rouvre ses connexions : ici, la recréation de db coupe le pool, et les nouvelles connexions résolvent `database` vers la nouvelle cible.

**Piège rencontré.** Appeler `docker compose -f compose.yml up front` après l'override recrée aussi les **dépendances** de `front` (api, db) avec la configuration de base, ce qui annule l'alias sans prévenir. Il faut toujours passer le même jeu de `-f` à toutes les commandes d'un même état.

### B3 — `com.docker.network.bridge.enable_icc=false`

Fichier [`bonus/compose.b3-icc.yml`](bonus/compose.b3-icc.yml), script [`bonus/b3-icc.sh`](bonus/b3-icc.sh), sortie dans [`diag/bonus-b3-icc.txt`](diag/bonus-b3-icc.txt).

Appliqué au réseau `backend` (avec `--force-recreate`, pour éviter le piège de l'alias perdu) :

| Test | Résultat |
|---|---|
| `getent hosts db` depuis api | `172.26.0.2 db` : le DNS fonctionne toujours |
| `nc -z db 5432`, `nc -z redis 6379` depuis api | Échec (code 1) : le trafic entre conteneurs **du même bridge** est bloqué |
| front → api sur `public` (`icc` laissé à `true`) | `{"status":"ok"}` |
| `/health` via le port publié | 200 en 1 ms (le DNAT hôte → conteneur n'est pas concerné) |
| `/ready` et `/products` | **504 en 30 s**. nginx essaie un réplica (`proxy_read_timeout 15s`), puis l'autre (`proxy_next_upstream`), car le client `pg` n'a pas de timeout de connexion |
| `docker compose ps` | Tout reste `healthy`. Les healthchecks sont locaux, ils ne voient pas la coupure |
| Règle dans la VM | `-A DOCKER-FORWARD -i br-72a6537e6600 -o br-72a6537e6600 -j DROP`, et en nft `iifname "br-…" oifname "br-…" counter packets 150 … drop` |

**Ce qui se passe.** Docker ajoute une règle de pare-feu qui jette tout paquet entrant et sortant par le même bridge. Les conteneurs ne se parlent plus, même sur le même réseau. Le DNS et l'accès depuis l'hôte (via les ports publiés) continuent de fonctionner. Sur un réseau applicatif, ça casse donc l'application sans qu'un healthcheck ne s'en aperçoive.

**Usage pertinent.** Un réseau où plusieurs clients ne doivent pas se voir entre eux, et qui ne passent que par des ports publiés ou une passerelle. Pour segmenter une application, on préfère plusieurs réseaux utilisateurs : c'est ce que fait la séparation `public` / `backend`.

### B4 — conflit de sous-réseau avec le VPN d'entreprise

Script [`bonus/b4-vpn.sh`](bonus/b4-vpn.sh), configuration [`bonus/b4-vpn/daemon.json`](bonus/b4-vpn/daemon.json), sortie dans [`diag/bonus-b4-vpn.txt`](diag/bonus-b4-vpn.txt).

Pour ne pas toucher au daemon Colima (ni aux autres stacks), la démonstration tourne dans un `docker:28.5-dind` jetable. Le « VPN » y est simulé par une interface `dummy` `vpn0` qui pousse la route `172.16.0.0/12` (l'intranet, serveur `172.18.5.10`).

Contexte réel : la VM Colima utilise déjà **onze /16**, de `172.17.0.0/16` à `172.27.0.0/16`. C'est exactement la plage que les VPN d'entreprise utilisent souvent.

| Scénario | Sous-réseaux Docker | `ip route get 172.18.5.10` |
|---|---|---|
| A. Pools par défaut, réseaux créés **avant** le VPN | `docker0 172.18.0.0/16`, `app1 172.19.0.0/16`, `app2 172.20.0.0/16` | `dev docker0` : **l'intranet est injoignable**, car le /16 local est plus spécifique que le /12 du VPN |
| A'. Même daemon, VPN **déjà** connecté | `app3` reçoit `192.168.16.0/20` : Docker évite les plages couvertes par une route existante | Toujours `dev docker0` : les anciens réseaux ne bougent pas |
| B. `daemon.json` : `"bip": "10.200.0.1/24"` et `"default-address-pools": [{"base": "10.201.0.0/16", "size": 24}]` | `docker0 10.200.0.0/24`, `app1..3` de `10.201.0.0/24` à `10.201.2.0/24` | `dev vpn0` : le trafic intranet passe par le VPN |

**À retenir.**
- Le conflit dépend de l'ordre : Docker évite une route **présente** au moment où il crée le réseau, mais un VPN qui se connecte **après** se fait « voler » ses plages par les bridges existants.
- La correction durable est donc de réserver une plage dédiée à Docker, connue de l'équipe réseau : `bip` et `default-address-pools` dans `/etc/docker/daemon.json`. Sous Colima, c'est la clé `docker:` de `colima.yaml`, qui demande un redémarrage de Colima.
- Des `/24` plutôt que des `/16` : on consomme 256 fois moins d'adresses par réseau.
- Il faut ensuite recréer les réseaux existants (`docker compose down` puis `up`), car un réseau garde son sous-réseau.

## Nettoyage

- Les ressources de démonstration ont été supprimées : conteneurs `tp06-*`, réseaux `demo` et `tp06-internal`, projet `tp06-alias`, conteneur `tp06-dind`, volume `incident_pgdata-next`.
- La stack `incident` corrigée tourne encore, sur le port 8081.
- Pour l'arrêter :

```bash
docker compose down
```

- Pour supprimer aussi ses volumes :

```bash
docker compose down -v
```
