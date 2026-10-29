# TP04 : une stack Compose d'entreprise

Environnement : Mac Apple Silicon, Colima, Docker Engine 29.5.2, Docker Compose v5.1.4.
Sorties brutes : [`diag/`](diag/). Aucun commentaire dans les fichiers livrés : les explications sont ici.

| Livrable | Fichier |
|---|---|
| Base commune | [`compose.yml`](compose.yml) |
| Surcharge dev (appliquée automatiquement) | [`compose.override.yml`](compose.override.yml) |
| Surcharge prod | [`compose.prod.yml`](compose.prod.yml) |
| Variables | [`.env.example`](.env.example) (`.env`, `secrets/` et `pip.conf` sont gitignorés) |
| Outillage | [`Makefile`](Makefile), [`smoke-test.sh`](smoke-test.sh) |
| Données | [`db/init.sql`](db/init.sql), [`db/migrations/002-add-sku.sql`](db/migrations/002-add-sku.sql) |
| `DATABASE_URL` depuis le secret | [`config/db-url.cjs`](config/db-url.cjs) (Node), [`config/python/sitecustomize.py`](config/python/sitecustomize.py) (Python) |
| Bonus | [`compose.watch.yml`](compose.watch.yml) (B1), [`compose.tls.yml`](compose.tls.yml) + [`tls/`](tls/) (B2), [`b5-include/`](b5-include/) (B5) |
| Applications | [`apps/`](apps/) : copies des TP01 et TP02. Code applicatif inchangé ; commentaires retirés des Dockerfiles et `.dockerignore` |

```bash
make init
make up
make test
make prod-up
make prod-test
```

## Adaptations au poste

| Exigence de l'énoncé | Réalisé | Pourquoi |
|---|---|---|
| `traefik:v3.1` | `traefik:v3.6.25` épinglé par digest | Docker 29 n'accepte plus les clients API < 1.40. Traefik 3.1.7 force l'API 1.24 (`client version 1.24 is too old`), et `DOCKER_API_VERSION` n'y change rien |
| Port de debug PostgreSQL 5432 | `127.0.0.1:${DB_DEBUG_PORT:-5432}`, ici 5433 dans `.env` | Le port 5432 du Mac est déjà pris par `avis-stades-postgres` |
| Rechargement via bind mount | Fonctionne, sauf depuis l'éditeur du Mac | Colima est configuré avec `mountInotify: false` : voir l'étape 3 et le bonus B1 |
| TLS avec `mkcert` | CA locale générée avec `openssl`, mêmes noms de fichiers que mkcert | `mkcert` n'est pas installé, et `mkcert -install` modifie le trousseau système : c'est à toi de le faire si tu le souhaites |

---

## 1. Critique de `starter/docker-compose.yml`

| # | Problème | Conséquence |
|---|---|---|
| 1 | `version: '3'` | Clé obsolète, ignorée par Compose v2 et suivants (avertissement). Elle fige à tort un « format » qui n'existe plus |
| 2 | `links:` | Mécanisme hérité. Le DNS du réseau utilisateur résout déjà `db` et `redis`. `links` n'exprime aucun ordre de démarrage fiable |
| 3 | Images non épinglées (`postgres`, `redis`) | `latest` change sans prévenir. Passer de PostgreSQL 16 à 17 en tirant l'image casse le volume de données (format incompatible) |
| 4 | `5432:5432` et `6379:6379` publiés sur `0.0.0.0` | Base et Redis exposés à tout le réseau, voire à Internet. Redis n'a même pas de mot de passe |
| 5 | Mot de passe `postgres` en clair, deux fois, dans un fichier versionné | Fuite dans git, dans `docker inspect` et dans les logs. Rotation impossible sans modifier le fichier |
| 6 | Superutilisateur `postgres` et base `postgres` utilisés par l'application | Aucun moindre privilège : une injection SQL a tous les droits |
| 7 | `sh -c "sleep 10 && node src/server.js"` | Délai arbitraire : trop court sur une machine lente, du temps perdu sinon. `sh` devient PID 1 et ne relaie pas SIGTERM (arrêt en 10 s, puis SIGKILL) |
| 8 | Pas de healthcheck ni de `depends_on: condition: service_healthy` | Le worker démarre avant la base, Compose ne sait pas si la stack est saine, `up --wait` est inutilisable |
| 9 | Un seul réseau par défaut | Tous les services se voient. La base est joignable depuis tout conteneur exposé, sans aucune segmentation |
| 10 | Aucun volume nommé | Les données PostgreSQL et Redis sont dans des volumes **anonymes** : un `docker compose down -v` ou `rm -v` les détruit, et on ne les retrouve pas facilement |
| 11 | Aucun schéma ni jeu de données initial | L'API interroge `products` et `orders` qui n'existent pas. Erreur 500 dès qu'une `DATABASE_URL` est fournie |
| 12 | `restart` incohérent (`always` pour le worker seulement) | Après un reboot, le worker redémarre mais pas la base ni l'API. Avec `always`, même un conteneur arrêté volontairement redémarre |
| 13 | Pas de limites CPU/mémoire ni de rotation des logs | Une fuite mémoire ou un flot de logs peut saturer la machine ou le disque (`json-file` sans `max-size`) |
| 14 | Pas de reverse proxy | L'API est exposée directement en 3000 : ni nom d'hôte, ni TLS, ni répartition de charge, impossible d'avoir plusieurs réplicas |
| 15 | Pas de séparation dev / prod | Le même fichier fait `build` en prod et publie les ports de debug partout |
| 16 | Nom de projet dépendant du dossier | `starter_db_1` d'un poste à l'autre : les volumes et réseaux changent de nom selon l'endroit où le dépôt est cloné |

---

## 2. Fichier de base `compose.yml`

| Exigence | Mise en œuvre |
|---|---|
| Nom de projet stable | `name: shop` : réseaux `shop_front`/`shop_back`, volumes `shop_pgdata`/`shop_redisdata`, quel que soit le dossier |
| Deux réseaux | `front` (Traefik, API, Adminer) et `back` en `internal: true` (API, worker, base, Redis, Adminer, migrate) |
| Images épinglées | `postgres:16.4-alpine`, `redis:7.4-alpine`, `traefik:v3.6.25`, `adminer:4.8.1`, toutes avec tag **et** digest |
| Healthchecks factorisés | Ancre `x-healthcheck-defaults` (intervalle, timeout, retries, `start_period`, `start_interval: 1s`). Pour l'API et le worker, seule l'ancre est fournie : le **test est hérité de l'image** (`wget` sur l'image alpine, `node fetch` sur l'image distroless, qui n'a ni `wget` ni `node` dans le PATH). Un même `compose.yml` sert donc les deux images |
| Ordre de démarrage | `depends_on: condition: service_healthy` **et** `restart: true` vers la base et Redis (voir ci-dessous) |
| Secret | `secrets.db_password` (fichier `secrets/db_password.txt`, gitignoré, généré par `make init`), `POSTGRES_PASSWORD_FILE` côté base |
| Volumes, init | `pgdata`, `redisdata` (Redis en `appendonly yes`), `db/init.sql` monté dans `docker-entrypoint-initdb.d` |
| Traefik | Configuration statique **par variables d'environnement** (`TRAEFIK_*`), dynamique par labels. `api.localhost` vers l'API, healthcheck de backend sur `/ready` toutes les 5 s, logs d'accès en JSON |
| Logs, redémarrage | Ancres `x-logging` (`json-file`, 3 × 10 Mo) et `x-service-defaults` (`restart: unless-stopped`) |
| Profils | `tools` : `adminer` sur `adminer.localhost`. `ops` : `migrate`, conteneur à usage unique (`restart: "no"`) |

### `DATABASE_URL` construite à partir du secret, sans modifier le code

L'application ne lit que `DATABASE_URL`. La mettre dans `environment:` remettrait le mot de passe en clair dans le fichier et dans
`docker inspect`. Solution : un **préchargement** au démarrage du runtime, fourni par Compose (`configs:`).

| Service | Mécanisme | Fichier |
|---|---|---|
| API (Node) | `NODE_OPTIONS=--require /etc/shop/db-url.cjs`, chargé par `node` avant `server.js` | [`config/db-url.cjs`](config/db-url.cjs) |
| Worker (Python) | `PYTHONPATH=/etc/shop/python` : Python importe automatiquement `sitecustomize.py` au démarrage | [`config/python/sitecustomize.py`](config/python/sitecustomize.py) |

Les deux lisent `DATABASE_PASSWORD_FILE`, **encodent** le mot de passe pour l'URL (`encodeURIComponent` / `quote`), et définissent
`DATABASE_URL` dans le processus seulement. Avantages :
- aucune dépendance à un shell : ça fonctionne aussi sur l'image distroless ;
- `node` ou `python` reste le processus principal (signaux transmis) ;
- l'URL n'apparaît **nulle part** dans la configuration du conteneur (`docker inspect … | grep -c DATABASE_URL` donne 0).

Le mot de passe est généré aléatoirement (32 octets en base64).

`secrets/db_password.txt` est en `0644`. Hors Swarm, un secret Compose est un simple bind mount qui garde les droits de l'hôte
(`uid`/`gid`/`mode` sont ignorés). Les conteneurs non-root (uid 70, 1000, 10001, 65532) doivent pouvoir le lire. La protection
vient du dossier `secrets/` (gitignoré, et `0700` sur le serveur) et de l'absence de copie dans les images.

### `restart: true` dans `depends_on` : trouvé en testant

Ajouter le réseau `debug` en dev a recréé le conteneur de la base. PostgreSQL a coupé les connexions
(`57P01 terminating connection due to administrator command`), et l'API a **planté** : son pool `pg` n'écoute pas l'événement `error`.
C'est une faiblesse du code, hors périmètre. `restart: true` demande à Compose de redémarrer l'API et le worker chaque fois qu'il
redémarre ou recrée la base ou Redis. En prod, `restart: unless-stopped` relance en plus un conteneur dont le processus principal s'arrête.

### Vérification

```
$ docker compose -f compose.yml up -d --build --wait    -> exit 0, tous les services Healthy
$ curl http://api.localhost/ready                       -> {"status":"ready","checks":{"db":"ok","redis":"ok"}}
$ curl -D - http://api.localhost/products (2 appels)     -> X-Cache: MISS, puis X-Cache: HIT
$ POST /orders {"productId":1,"quantity":2}             -> en base : 1|1|2|confirmed (traitée par le worker)
```

Configurations résolues : [`diag/config-base.yml`](diag/config-base.yml), [`config-dev.yml`](diag/config-dev.yml),
[`config-prod.yml`](diag/config-prod.yml). Aucune ne contient le mot de passe.

---

## 3. Surcharge dev `compose.override.yml`

| Ajout | Détail |
|---|---|
| Rechargement | `command: node --watch src/server.js` + bind mount `./apps/shopapi/src:/app/src:ro` |
| Ports de debug, sur `127.0.0.1` uniquement | API 3000, PostgreSQL `${DB_DEBUG_PORT}`, dashboard Traefik 8080 (`TRAEFIK_API_INSECURE`) |
| Niveau de log | `LOG_LEVEL=debug` (API), `DEBUG` (worker et Traefik) |

Les variables `TRAEFIK_*` sont **fusionnées** entre la base et la surcharge, alors qu'une liste `command:` serait remplacée en entier.
C'est pour cette raison que Traefik est configuré par variables d'environnement.

### Un port publié sur un réseau `internal` ne s'ouvre pas

Au premier essai, `127.0.0.1:5433:5432` était bien enregistré (`HostConfig.PortBindings`), mais **aucun port n'était ouvert**
(`NetworkSettings.Ports` vide). Un conteneur relié uniquement à un réseau `internal: true` ne peut pas être publié. C'est l'isolation
voulue en prod. En dev, la surcharge rattache donc la base à un réseau `debug` supplémentaire, non interne : le port s'ouvre (`pg_isready` OK).

### Rechargement ([`diag/etape3-reload.txt`](diag/etape3-reload.txt))

```
Modification faite depuis le Mac            -> aucun "Restarting" (0)
Même modification faite depuis la VM Linux  -> Restarting 'src/server.js'
                                              arrêt demandé (SIGTERM) puis code rechargé à chaud, shopapi démarré
RestartCount du conteneur : 0 (seul le processus node est relancé)
```

`node --watch` repose sur inotify. Avec `mountInotify: false` (configuration actuelle de Colima), les modifications faites sous macOS
traversent virtiofs **sans événement inotify** dans la VM. Je l'ai prouvé avec `inotifywait` : rien pour un `touch` côté Mac,
un événement pour un `touch` côté VM. Deux solutions : `mountInotify: true` dans `~/.colima/default/colima.yaml` (je ne l'ai pas
modifié), ou `docker compose watch`, qui fonctionne tel quel (bonus B1).

---

## 4. Surcharge prod `compose.prod.yml`

```bash
docker compose -f compose.yml -f compose.prod.yml config
docker compose -f compose.yml -f compose.prod.yml up -d --wait
```

| Exigence | Mise en œuvre |
|---|---|
| Images du registre, sans `build` | `image: ${REGISTRY:?…}/shopapi:${VERSION:?…}` et `build: !reset null`. `!reset` **supprime** la clé héritée (une valeur vide ne suffirait pas) |
| Images utilisées | `registry.local:5000/shopapi:1.4.3` (Node 24 distroless, TP03) et `registry.local:5000/shop-worker:1.0.0` (passée par `release-gate.sh` : acceptée, signée, SBOM attestés) |
| Réplicas | `deploy.replicas: 2` pour l'API |
| Durcissement | Ancre `x-hardening` : `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges:true` sur tous les services. `tmpfs` là où il faut écrire |
| Non-root partout | Base `user: 70:70` (tmpfs `/var/run/postgresql` en uid 70), Redis `999:1000`. L'API (65532) et le worker (10001) le sont déjà par leur image. Sans root, les entrypoints n'ont plus besoin de `chown`/`su-exec`, donc `cap_drop: ALL` fonctionne |
| Limites | CPU et mémoire par service (Traefik 128 Mo, base 512 Mo, API, worker et Redis 256 Mo) |
| Exposition | Seul le port 80 de Traefik. Pas de dashboard, pas de ports de debug. Adminer est désactivé (`profiles: !override [disabled-in-prod]`) |

Vérifications ([`diag/etape4-prod.txt`](diag/etape4-prod.txt)) :

```
api : shop-api-1 172.23.0.3, shop-api-2 172.23.0.4
10 requêtes sur http://api.localhost/, champ ServiceAddr des logs d'accès Traefik : 5 × 172.23.0.3:3000, 5 × 172.23.0.4:3000
user / read_only / cap_drop / no-new-privileges / limites / json-file 10m×3 : OK sur les 5 conteneurs
écriture dans /app de l'API                    -> EROFS: read-only file system
localhost:8080, localhost:3000, 127.0.0.1:5433 -> fermés
worker -> https://pypi.org                       -> échec de résolution DNS (réseau back internal : pas d'accès à Internet)
```

### `--scale api=3` puis `up -d` ([`diag/etape4-scale.txt`](diag/etape4-scale.txt), [`etape4-scale-dev.txt`](diag/etape4-scale-dev.txt))

| | `up -d --scale api=3` | puis `up -d` |
|---|---|---|
| Prod | 3 réplicas. Traefik les découvre seul et répartit 3/3/3 | **Retour à 2** : `shop-api-3` est arrêté et supprimé, car `deploy.replicas` du fichier fait foi |
| Dev | **Échec** : `port is already allocated` pour `shop-api-2`, puisque `127.0.0.1:3000` ne peut appartenir qu'à un conteneur | Retour à 1 |

`--scale` est un ajustement ponctuel : le prochain `up` réapplique l'état déclaré, comme un *reconcile*. Un service mis à l'échelle ne
doit pas publier de port fixe sur l'hôte (ni `container_name`) : c'est le reverse proxy qui sert de point d'entrée.

---

## 5. Outillage d'équipe

| Cible | Action |
|---|---|
| `make init` | Crée `.env` depuis `.env.example`, un mot de passe aléatoire dans `secrets/db_password.txt`, et `pip.conf` |
| `make up` / `down` / `ps` / `logs` | Dev : `docker compose up -d --build --wait`, etc. |
| `make tools` | Adminer (profil `tools`) |
| `make watch` | Bonus B1 |
| `make prod-config` / `prod-up` / `prod-down` / `prod-ps` / `prod-logs` | Mêmes commandes avec `-f compose.yml -f compose.prod.yml` |
| `make migrate M=002-add-sku.sql` / `prod-migrate` | `docker compose --profile ops run --rm migrate` |
| `make test` / `prod-test` | `smoke-test.sh` |

`smoke-test.sh` vérifie, avec un code de sortie 1 en cas d'échec :
- `/ready` (base et Redis à `ok`) ;
- `/products` deux fois, avec `X-Cache: HIT` au second appel ;
- une commande de quantité 2 qui doit passer `confirmed` ;
- une commande de quantité 500 qui doit passer `rejected`.

Les statuts sont relus **dans PostgreSQL** (`docker compose exec db psql`), en attendant jusqu'à 15 s.

```
$ make prod-test
  OK     /ready : {"status":"ready","checks":{"db":"ok","redis":"ok"}}
  OK     /products : 3 produits, X-Cache: HIT au second appel
  OK     commande 2 (quantité 2) : pending -> confirmed par le worker
  OK     commande 3 (quantité 500) : pending -> rejected par le worker
== OK
```

Migration ([`diag/etape5-test-migrate.txt`](diag/etape5-test-migrate.txt)) :
- sans `M` ou avec un fichier introuvable : refus avec un message, exit 2 ;
- `002-add-sku.sql` est exécutée en une seule transaction (`--single-transaction`, `ON_ERROR_STOP`) et inscrite dans `schema_migrations` ;
- la rejouer ne change rien (`INSERT 0 0`) ;
- le conteneur est supprimé après exécution.

La commande de l'énoncé, `MIGRATION=002-add-sku.sql docker compose run --rm migrate`, fonctionne aussi sans `--profile` : `run`
active automatiquement le profil du service ciblé. Dans le fichier, la variable s'écrit `$$MIGRATION`, pour être évaluée dans le conteneur et non à
l'interpolation (sinon tout `docker compose` échouerait quand elle n'est pas définie).

---

## Bonus

### B1 : `docker compose watch` ([`compose.watch.yml`](compose.watch.yml), [`diag/bonus-b1-watch.txt`](diag/bonus-b1-watch.txt))

`volumes: !reset []` retire le bind mount, et `develop.watch` le remplace.

| Action | Utilisation | Résultat |
|---|---|---|
| `sync` | `apps/shopapi/src` vers `/app/src` | Modification **depuis le Mac** : `Syncing service "api"`, puis `node --watch` relance l'application. Conteneur non redémarré |
| `sync+restart` | `apps/shop-worker/worker` | Le worker est redémarré (`StartedAt` change) : Python n'a pas de rechargement intégré |
| `rebuild` | `package.json`, `package-lock.json`, `requirements.txt` | Une dépendance change : l'image est reconstruite et le conteneur recréé |

Contrairement au bind mount, `sync` **copie** les fichiers dans le conteneur. Les événements inotify se produisent donc à l'intérieur
du conteneur, et le rechargement marche sur macOS quelle que soit la configuration de la VM. C'est aussi plus rapide que virtiofs
pour les gros arbres de fichiers. En revanche, rien n'est resynchronisé vers l'hôte : ce sens n'existe pas.

### B2 : TLS local et redirection 80 → 443 ([`compose.tls.yml`](compose.tls.yml), [`diag/bonus-b2-tls.txt`](diag/bonus-b2-tls.txt))

`tls/gen-certs.sh` crée une CA de dev et un certificat pour `api.localhost`, `adminer.localhost`, `localhost` et `127.0.0.1`. Ce sont les
mêmes noms de fichiers que `mkcert -cert-file tls/certs/localhost.pem -key-file tls/certs/localhost-key.pem …`. Traefik les charge
par son *file provider* ([`tls/dynamic.yml`](tls/dynamic.yml), TLS 1.2 minimum).

```
$ curl -sI http://api.localhost/ready                       -> 308 Permanent Redirect, Location: https://api.localhost/ready
$ curl --cacert tls/ca/rootCA.pem https://api.localhost/ready -> 200, TLS vérifié = 0
$ curl https://api.localhost/ready                         -> exit 60 (CA non reconnue par le système)
$ openssl s_client -tls1_1 …                               -> alert protocol version
```

Pour que les navigateurs fassent confiance au certificat :

```bash
brew install mkcert
mkcert -install
mkcert -cert-file tls/certs/localhost.pem -key-file tls/certs/localhost-key.pem api.localhost adminer.localhost localhost 127.0.0.1
```

En prod, on utiliserait plutôt ACME (Let's Encrypt) dans Traefik, ou un certificat d'entreprise.

### B3 : Adminer et le réseau `back` interne ([`diag/bonus-b3-adminer.txt`](diag/bonus-b3-adminer.txt))

| Réseaux d'Adminer | Via Traefik (`adminer.localhost`) | Vers `db:5432` |
|---|---|---|
| `front` + `back` (livré) | **200**, « Login - Adminer » | joignable |
| `back` seul | **Timeout** : Traefik avertit `Defaulting to first available network ("shop_back")` et vise une IP qu'il ne peut pas joindre | joignable |
| `front` seul | 200 | **introuvable** (`getaddrinfo failed`) |

Oui, Adminer est joignable alors que `back` est interne : il est **aussi** sur `front`, que partage Traefik. `internal: true` ne
supprime que la sortie vers l'extérieur (pas de passerelle ni de NAT) et la publication de ports. Les échanges entre conteneurs d'un
même réseau restent possibles. Un conteneur relié aux deux réseaux fait le pont : c'est voulu pour l'API et Adminer, et c'est
précisément pourquoi la base et Redis ne doivent être que sur `back`. Juste après le démarrage, Traefik renvoie un 404 tant que le
conteneur n'est pas `healthy` : il ignore les conteneurs en cours de démarrage.

### B4 : variables obligatoires ([`diag/bonus-b4-variables.txt`](diag/bonus-b4-variables.txt))

```
$ REGISTRY= docker compose -f compose.yml -f compose.prod.yml config
error while interpolating services.api.image: required variable REGISTRY is missing a value: REGISTRY doit être défini   (exit 1)
$ VERSION= docker compose -f compose.yml -f compose.prod.yml up -d                -> idem pour VERSION, rien n'est lancé
$ (sans .env) docker compose -f compose.yml -f compose.prod.yml config           -> idem pour REGISTRY
$ docker compose config                                                          -> exit 0 (dev non concerné)
```

`${VAR:?message}` échoue aussi quand la variable est **vide**, et pas seulement absente, ce qui évite de déployer `"/shopapi:"`.

### B5 : découper et partager ([`b5-include/`](b5-include/), [`diag/bonus-b5-include.txt`](diag/bonus-b5-include.txt))

**`include:`** : `b5-include/compose.yml` (équipe applicative) inclut `data/compose.yml` (équipe données : base, Redis, réseau `back`,
volumes, secret) et `edge/compose.yml` (équipe plateforme : Traefik, réseau `front`).

- Le modèle fusionné contient les 4 services, les 2 réseaux et les 2 volumes. Les chemins relatifs de chaque fichier inclus sont résolus
  **depuis son propre dossier** (`../../db/init.sql` dans `data/` donne bien `db/init.sql`). Chaque équipe garde donc son fichier sans
  connaître l'arborescence des autres.
- **Piège constaté avec Compose v5.1.4** : redéfinir localement un service inclus (`db` en `postgres:17-alpine` dans `conflict.yml`)
  n'est **ni refusé ni signalé**. La définition locale est fusionnée par-dessus celle de l'équipe données, comme avec un `-f`
  supplémentaire. Ici, cela changerait silencieusement la version majeure de la base. Il faut donc une revue de code ou une CI sur le
  modèle résolu (`docker compose config`).

**`docker compose publish`** (stable dans Compose v5, plus besoin d'`alpha`) :

```
$ docker compose -f compose.yml -f compose.prod.yml publish --resolve-image-digests -y registry.local:5000/shop-stack:1.0.0
artifactType : application/vnd.docker.compose.project
couches      : compose.yml, compose.prod.yml, image-digests.yaml
```

- Exige HTTPS : le registre HTTP `localhost:5050` est refusé, et la commande a été lancée depuis un conteneur `docker:cli` dans la VM.
- `--resolve-image-digests` épingle les images (`shopapi:1.4.3@sha256:e724…`).
- Côté consommateur (`docker compose -f oci://…`, dans un dossier vide) : le `.env` n'est **pas** publié sans `--with-env` (`REGISTRY`
  est donc obligatoire), et les fichiers référencés (`db/init.sql`, `secrets/`, `config/`) ne le sont pas non plus. Leurs chemins pointent
  vers un cache vide.

`publish` convient à une stack « images + variables ». Pour la nôtre, il faudrait embarquer `init.sql` et les préchargeurs dans des images,
ou passer par `configs.content`, et fournir le secret sur le serveur.

---

## Points d'attention restants

- **Socket Docker dans Traefik** : même en lecture seule, `/var/run/docker.sock` donne l'équivalent de root sur l'hôte à qui compromet
  Traefik. En prod, il faudrait un proxy de socket (`tecnativa/docker-socket-proxy` limité à `CONTAINERS=1`), ou le *file provider*.
- **Redis sans mot de passe** : il n'est joignable que depuis `back`. Pour aller plus loin, `requirepass` par secret, avec le même
  préchargement pour `REDIS_URL`.
- **Robustesse de l'API** : elle plante quand PostgreSQL redémarre (pas de `pool.on('error')`). `restart: true` et `unless-stopped`
  compensent côté infrastructure, mais le correctif appartient au code.

## État laissé sur le poste

La stack dev tourne (`shop`, avec Adminer). Pour l'arrêter :

```bash
make down
```

Pour tout supprimer, volumes compris :

```bash
docker compose --profile tools --profile ops down -v
```

L'artefact `registry.local:5000/shop-stack:1.0.0` et l'image `shop-worker:1.0.0` sont dans le registre du TP03.
