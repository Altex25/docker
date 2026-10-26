# Livrable 2 : rapport de remise en conformité de `shopapi`

Fichiers livrés (le code applicatif `src/`, `test/` et `package.json` n'a **pas** été modifié) :

| Fichier | Rôle |
|---|---|
| [`Dockerfile`](Dockerfile) | Nouveau Dockerfile multi-stage (cible par défaut `runtime`, plus `runtime-distroless` pour le bonus B1) |
| [`.dockerignore`](.dockerignore) | Liste blanche du contexte de build |
| [`package-lock.json`](package-lock.json) | Lockfile ajouté (`npm install --package-lock-only` dans `node:20-alpine`), nécessaire à `npm ci` |
| [`Dockerfile.legacy`](Dockerfile.legacy) | Dockerfile d'origine, gardé pour la comparaison |
| [`DIAGNOSTIC.md`](DIAGNOSTIC.md) | Livrable 1 : les 20 problèmes relevés |
| [`diag/`](diag/) | Sorties brutes de toutes les commandes |
| [`bonus/`](bonus/) | Scripts de mesure des bonus B2 (`b2-cache-mount.sh`) et B3 (`b3-reproductible.sh`) |
| `.gitignore` | Ajout de `.env` et `*.sql` |

## Tableau avant / après

| Critère | `shopapi:legacy` | `shopapi:1.4.2` | Standard |
|---|---|---|---|
| Image de base | `ubuntu:22.04` (tag mobile) + NodeSource | `node:20.20.2-alpine3.23@sha256:fb4c…` | ✅ 1 |
| Taille compressée (registre, `CONTENT SIZE`) | 279 Mo | **51,7 Mo** (−81 %) | ✅ 1 |
| Système de fichiers (`du -sh /`) | 746 Mo | **152,5 Mo** (−80 %) | ✅ 1 |
| `DISK USAGE` (`docker image ls`) | 1,06 Go | 212 Mo (*voir note*) | |
| Couches de système de fichiers | 9 (1 ubuntu + 8) | 8 (4 node + 4 app) | |
| Paquets dans `node_modules` | 196 (dont dev) | 111 (prod seulement) | ✅ 6 |
| Build initial (sans cache) | 93 s | 2,9 s (`--no-cache`, cache mount npm chaud) | |
| **Rebuild après changement de code** | **15,5 s** (`npm install` rejoué) | **0,9 s** (`npm ci` *CACHED*) | ✅ 4 |
| Utilisateur | `uid=0(root)` | `uid=1000(node)` | ✅ 2 |
| PID 1 | `/bin/sh -c npm start` (4 processus) | `node src/server.js` (1 processus) | ✅ 2 |
| **Temps d'arrêt (`docker stop`)** | **10,13 s**, exit 137 (SIGKILL) | **0,11 s**, exit 0 | ✅ 2 |
| Secrets dans l'image | 3 (`ENV DATABASE_URL`, `.env`, dump) | 0 | ✅ 3 |
| Fichiers inutiles dans `/app` | `.env`, `*.sql`, `Dockerfile`, `.gitignore` | `node_modules`, `package.json`, `src` | ✅ 3 |
| `HEALTHCHECK` | absent | `healthy` en < 6 s | ✅ 5 |
| Labels OCI | `version=22.04` (hérité d'Ubuntu !) | title, version, revision, source, … | ✅ 5 |
| Tests / lint dans le build | non | étape `test`, bloquante | ✅ 6 |
| hadolint (warning/error) | 6 warnings + 4 infos | **0** (aucune sortie) | ✅ 7 |
| dive : efficacité / gaspillage | 99,6 % / 4,0 Mo | 99,97 % / 75 ko | |

> **Note sur la taille.** Ce poste utilise le *containerd image store* (Docker 29). Dans ce mode, la colonne
> `DISK USAGE` de `docker image ls` additionne les blobs **compressés** (51,7 Mo) et le snapshot **décompressé**
> (≈ 152 Mo). Le même fichier est donc compté deux fois. L'image `node:20.20.2-alpine3.23` seule y affiche déjà
> 194 Mo. La taille utile de l'image est de **51,7 Mo** à transférer depuis le registre et de **152,5 Mo** une fois
> décompressée (c'est ce qu'afficherait la colonne `SIZE` avec le stockage classique `overlay2`). Les deux sont
> sous le seuil de 200 Mo. La variante distroless du [bonus B1](#bonus-b1--variante-distroless) passe aussi sous
> 200 Mo sur ce compteur (199 Mo), puisqu'elle ne contient ni npm, ni yarn, ni shell.

Mesures réalisées sur un Mac arm64 (Colima, Docker Engine 29.5.2, BuildKit 0.30). Pour les temps de rebuild, comptez ≈ 4 min en CI
pour le legacy, contre quelques secondes pour la nouvelle image tant que `package*.json` ne change pas.

---

## Étape 2 : pourquoi `npm install` est rejoué

```
$ echo "// commentaire" >> src/server.js
$ docker build -f Dockerfile.legacy -t shopapi:legacy .
#11 [7/9] WORKDIR /app        CACHED
#12 [8/9] COPY . /app         DONE        <- checksum du contexte modifié
#13 [9/9] RUN npm install     DONE 10.0s  <- rejoué : 222 paquets réinstallés
```

Le cache BuildKit est **séquentiel**. Une instruction n'est réutilisée que si elle est identique *et* que
toutes les couches précédentes le sont aussi. Pour un `COPY`, la clé de cache est le hash du contenu copié.
`COPY . /app` prend **tout** le contexte, donc le moindre octet modifié (code, README, et même `Dockerfile.legacy`
ou `diag/` ajoutés à côté) change la clé, la couche est reconstruite et toutes les suivantes aussi, `npm install` compris,
alors que `package.json` n'a pas bougé. Lors du premier « rebuild sans changement », `npm install` a même été rejoué
uniquement parce que de nouveaux fichiers étaient apparus dans le répertoire.

### Ordre de couches idéal (du plus stable au plus volatil)

```
   stabilité   couche                                       invalidée quand…
   ─────────   ──────────────────────────────────────────   ──────────────────────────────
   ▲ +++       FROM node:20.20.2-alpine3.23@sha256:…        on change volontairement de base
   │           WORKDIR /app
   │ ++        COPY package.json package-lock.json ./       une dépendance change
   │           RUN npm ci --omit=dev  (cache mount npm)     (idem, rare)
   │ +         COPY src ./src                               chaque commit de code
   │           USER / EXPOSE / HEALTHCHECK / CMD            (métadonnées, coût nul)
   ▼ −         LABEL revision=${GIT_SHA}                    chaque commit (0 octet)
```

Dans le Dockerfile final, les `LABEL`/`ENV` dépendant des `ARG` sont placés **dans l'étape runtime, avant le `COPY`**.
Ce sont des métadonnées sans couche de fichiers, donc changer `GIT_SHA` ne coûte rien, et les étapes `deps-*`
(où se fait le vrai travail) ne voient jamais ces `ARG`.

---

## Étape 3 : le Dockerfile final

```dockerfile
# syntax=docker/dockerfile:1.7
ARG NODE_IMAGE=node:20.20.2-alpine3.23@sha256:fb4cd12c85ee03686f6af5362a0b0d56d50c58a04632e6c0fb8363f609372293

FROM ${NODE_IMAGE} AS base                      
WORKDIR /app
COPY package.json package-lock.json ./

FROM base AS deps-dev                           
RUN --mount=type=cache,target=/root/.npm npm ci --no-audit --no-fund && npm ls --depth=0 >/dev/null

FROM base AS deps-prod                          
ENV NODE_ENV=production
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev --no-audit --no-fund && npm ls --omit=dev --depth=0 >/dev/null

FROM deps-dev AS test                           
COPY src ./src
COPY test ./test
RUN npm run lint && npm test

FROM ${NODE_IMAGE} AS runtime
ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG SOURCE_URL=https://github.com/Altex25/docker
LABEL org.opencontainers.image.title="shopapi" … version="${APP_VERSION}" revision="${GIT_SHA}" source="${SOURCE_URL}"
ENV NODE_ENV=production APP_VERSION=${APP_VERSION} PORT=3000
WORKDIR /app
COPY --from=deps-prod /app/node_modules ./node_modules
COPY package.json ./
COPY --from=test /app/src ./src                 
USER 1000:1000
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --start-interval=1s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:3000/health"]
CMD ["node", "src/server.js"]
```
(Version complète : [`Dockerfile`](Dockerfile).)

### Choix techniques

| Choix | Justification |
|---|---|
| `node:20-alpine` plutôt que `slim` | Base de 49 Mo compressés contre ≈ 70 Mo pour `slim`. Aucune dépendance native (pas de `bcrypt`, `sharp`…) : `pg` et `ioredis` sont du pur JS, donc la libc musl ne pose aucun problème. `wget` (busybox) est fourni, ce qui permet le healthcheck sans paquet supplémentaire. |
| Tag exact + digest | `20.20.2-alpine3.23` se lit facilement, le `@sha256` garantit les octets (un tag peut être réécrit). Renovate/Dependabot mettront à jour les deux. |
| `package-lock.json` + `npm ci` | Installation exacte et reproductible, qui échoue si le lockfile et `package.json` divergent. |
| `&& npm ls` après `npm ci` | Garde-fou découvert pendant le B2 : sans réseau, `npm ci` abandonne au bout de 140 s (« Exit handler never called! ») mais **renvoie 0** avec une arborescence incomplète. Le build réussirait et l'image serait cassée. `npm ls` renvoie alors 1 et arrête le build. |
| Étapes `deps-dev` et `deps-prod` séparées | Aucune devDependency dans l'image finale (`eslint`, `nodemon` absents, 111 paquets au lieu de 196). BuildKit exécute les deux étapes **en parallèle**. |
| `RUN --mount=type=cache,target=/root/.npm` | Le cache npm est partagé entre builds sans entrer dans une couche (0 Mo dans l'image, alors que le legacy embarquait 34 Mo). |
| `COPY --from=test /app/src` | Sans cela, BuildKit **saute** l'étape `test` lors d'un `docker build` sans `--target`, parce que rien n'en dépend. Copier le code depuis `test` rend les tests bloquants pour l'image finale. |
| `.dockerignore` en **liste blanche** | `*` puis `!package*.json !src/ !test/`. Un futur fichier sensible (`.env.prod`, clé, dump) est exclu par défaut, alors qu'une liste noire suppose de tout prévoir. |
| Fichiers appartenant à `root`, pas de `--chown` | Le processus `node` (uid 1000) peut lire son code mais pas le modifier, ce qui limite la persistance en cas de compromission. |
| `USER 1000:1000` (numérique) | C'est l'utilisateur `node` de l'image officielle. Avec un uid numérique, Kubernetes peut vérifier `runAsNonRoot` sans résoudre `/etc/passwd` (hadolint DL3066). |
| `CMD ["node", "src/server.js"]` en forme exec, sans `npm start` | `docker-entrypoint.sh` de l'image fait `exec "$@"`, donc `node` devient PID 1 et reçoit SIGTERM directement. npm ne s'intercale plus (un processus et de la mémoire en moins, et pas de relais de signal hasardeux). |
| `HEALTHCHECK` avec `--start-interval=1s` | Sonde toutes les secondes pendant la `start-period`, d'où l'état `healthy` en environ 1 s, puis toutes les 30 s. Il vise `/health` (liveness) et non `/ready`, pour ne pas redémarrer l'API quand PostgreSQL tombe. |
| Labels via `ARG` | `APP_VERSION` / `GIT_SHA` injectés par la CI, et `APP_VERSION` aussi exposé en `ENV` (lu par `GET /`). |
| Aucun secret | `DATABASE_URL` / `REDIS_URL` sont fournis **à l'exécution** (`-e`, `--env-file`, secrets Compose/K8s). L'API fonctionne sans, avec des données en mémoire. |

```bash
docker build --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo local) -t shopapi:1.4.2 .
docker build --target test -t shopapi:test .
#18 [test 3/3] RUN npm run lint && npm test
#18 0.181 lint ok
#18 0.274 # tests 1
#18 0.274 # pass 1
#18 0.274 # fail 0
```

Rebuild après `echo "// commentaire" >> src/server.js` : seules `COPY src`, l'étape `test` et la copie finale
sont rejouées, tandis que `npm ci` (dev comme prod) reste **CACHED** ([`diag/cache-1.4.2.txt`](diag/cache-1.4.2.txt)).

---

## Étape 4 : vérification de conformité

Sortie complète : [`diag/conformite-1.4.2.txt`](diag/conformite-1.4.2.txt).

```
$ docker run --rm shopapi:1.4.2 id
uid=1000(node) gid=1000(node) groups=1000(node)

$ docker run --rm shopapi:1.4.2 ls -la /app
drwxr-xr-x  114 root root  node_modules
-rw-r--r--    1 root root  package.json
drwxr-xr-x    2 root root  src

$ docker inspect shopapi:1.4.2 --format '{{json .Config.Labels}}' | jq
{
  "org.opencontainers.image.base.name": "docker.io/library/node:20.20.2-alpine3.23",
  "org.opencontainers.image.description": "API catalogue produits Shop SAS",
  "org.opencontainers.image.revision": "31ffc07",
  "org.opencontainers.image.source": "https://github.com/Altex25/docker",
  "org.opencontainers.image.title": "shopapi",
  "org.opencontainers.image.vendor": "Shop SAS",
  "org.opencontainers.image.version": "1.4.2"
}

$ docker run -d --name api -p 3000:3000 shopapi:1.4.2
$ sleep 6 && docker inspect api --format '{{.State.Health.Status}}'
healthy
$ curl -s localhost:3000/products | jq
[ { "id": 1, "name": "Clavier mécanique", ... }, ... ]
$ curl -s localhost:3000/
{"service":"shopapi","version":"1.4.2"}

$ time docker stop api
docker stop api  ... 0.117 total
$ docker logs api | tail -1
{"level":30,...,"pid":1,"signal":"SIGTERM","msg":"arrêt demandé"}
```

### Pourquoi 10 s avec le legacy et 0,1 s maintenant ?

```
legacy                                          1.4.2
PID 1  /bin/sh -c npm start   <- reçoit SIGTERM  PID 1  node src/server.js   <- reçoit SIGTERM
 └ npm start                                       └ handler shutdown() : server.close(),
    └ sh -c node src/server.js                       fermeture PG/Redis, process.exit(0)
       └ node src/server.js   <- ne reçoit rien
```

1. `docker stop` envoie **SIGTERM au seul PID 1** du conteneur.
2. Legacy : avec la forme shell, PID 1 est `/bin/sh`. Il n'a aucun handler pour SIGTERM, et le noyau **ignore**
   les signaux sans handler explicite pour un PID 1 (protection d'`init`). Le signal n'atteint jamais `node`.
3. Après le délai de grâce (`--time`, 10 s par défaut), Docker envoie **SIGKILL**, qu'on ne peut pas intercepter.
   Le code de sortie est 137 (128 + 9), les requêtes en cours sont coupées et le code d'arrêt propre ne s'exécute pas.
4. 1.4.2 : avec la forme exec, `node` est PID 1. Le handler `process.on('SIGTERM')` déjà présent dans
   `server.js` s'exécute, ferme le serveur HTTP et sort en 0. Résultat : 0,1 s et exit 0, et le rolling update
   n'attend plus le timeout.

(Sans forme exec possible, on aurait utilisé `docker run --init` ou `tini` comme PID 1 pour relayer les signaux.)

---

## Étape 5 : sortie hadolint

```
$ docker run --rm -i hadolint/hadolint:v2.15.1 < Dockerfile
$ echo $?
0
```

Aucune sortie, y compris au niveau `info`. hadolint v2.12 (l'ancien `latest` de beaucoup de tutoriels) ne connaît
pas l'option `HEALTHCHECK --start-interval` (Docker ≥ 25) et renvoie `invalid flag`. Il faut donc utiliser hadolint ≥ 2.13.

## Bonus B1 : variante distroless

La variante est une cible supplémentaire du même [`Dockerfile`](Dockerfile), `runtime-distroless`. Elle réutilise les
étapes `deps-prod` et `test`, donc mêmes dépendances, mêmes tests bloquants et même cache. Elle est placée *avant*
`runtime` pour que `runtime` reste la cible par défaut. hadolint ne remonte toujours rien.

```bash
docker build --target runtime-distroless --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=31ffc07 -t shopapi:1.4.2-distroless .
```

```dockerfile
FROM gcr.io/distroless/nodejs20-debian12:nonroot@sha256:2cd8201… AS runtime-distroless
ARG …  LABEL …  ENV NODE_ENV=production APP_VERSION=${APP_VERSION} PORT=3000
USER 0:0                       # la base est en USER 65532 : sinon WORKDIR crée /app modifiable par l'appli
WORKDIR /app
COPY --from=deps-prod /app/node_modules ./node_modules
COPY package.json ./
COPY --from=test /app/src ./src
USER 65532:65532               
HEALTHCHECK … CMD ["/nodejs/bin/node", "-e", "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
CMD ["src/server.js"]          
```

### Mesures

Sorties brutes : [`diag/conformite-distroless.txt`](diag/conformite-distroless.txt),
[`diag/distroless-debug.txt`](diag/distroless-debug.txt), [`diag/trivy.txt`](diag/trivy.txt).

| Critère | `legacy` | `1.4.2` (alpine) | `1.4.2-distroless` |
|---|---|---|---|
| Base | ubuntu 22.04 | alpine 3.23 (musl) | debian 12 (glibc), sans shell |
| Node | 20.20.2 | 20.20.2 | 20.20.0 |
| Taille compressée (`CONTENT SIZE`) | 279 Mo | 51,7 Mo | **46,8 Mo** |
| Système de fichiers (`docker export \| wc -c`) | 730 Mo | 148,2 Mo | **143,3 Mo** |
| `DISK USAGE` (`docker image ls`) | 1,06 Go | 212 Mo | **199 Mo** |
| Couches de système de fichiers | 9 | 8 | 23 (19 de base, partagées entre images distroless) |
| Utilisateur | root | 1000 (node) | 65532 (nonroot) |
| Shell / npm / wget / gestionnaire de paquets | oui | oui (busybox, npm, yarn, apk) | **aucun** |
| Healthcheck | aucun | `wget`, ≈ 39 ms/sonde | `node -e fetch`, ≈ 103 ms/sonde |
| `healthy` après 6 s | – | oui | oui |
| `docker stop` | 10,1 s, exit 137 | 0,11 s, exit 0 | **0,09 s, exit 0** |
| CVE (trivy 0.69.1) CRIT / HIGH / MED / LOW | 19 / 538 / 1767 / 1178 | 1 / 26 / 27 / 35 | 1 / **6** / 35 / 27 |
| HIGH/CRIT dans des paquets npm | – | 23, **tous dans le CLI npm** (`/usr/local/lib/node_modules/npm`) | **0** |

Temps de sonde : moyenne de 10 `docker exec` de la commande de healthcheck, coût fixe de `docker exec` compris
(≈ 30 ms). Le surcoût réel de `node -e` vient du démarrage d'un second runtime V8 toutes les 30 s.

### Ce que la mesure montre

- **Sécurité.** C'est le vrai gain, plus que la taille (−5 Mo seulement). Sur l'image alpine, 23 des 27 CVE HIGH/CRITICAL
  viennent de **npm lui-même** (`tar`, `minimatch`, `glob`, `cross-spawn`…), un outil qui n'est jamais exécuté en production.
  L'image distroless ne garde que les CVE de la libc et d'OpenSSL de Debian. Sans shell, une RCE ne permet ni
  `sh -c`, ni `wget`, ni `apk add` : l'attaquant doit tout faire depuis Node.
- **Il reste des CVE corrigeables dans les deux images** (OpenSSL d'alpine 3.23.4 et de Debian 12.13). Le digest
  épinglé garantit la reproductibilité, mais il faut le **mettre à jour régulièrement** (Renovate/Dependabot). Sans cela,
  la porte de release du TP03 (`--ignore-unfixed`, HIGH/CRITICAL) refusera les deux images.
- **Taille.** Elle est équivalente : le binaire `node` (≈ 100 Mo) domine. Distroless remplace musl+busybox+npm par
  glibc+OpenSSL et des certificats CA.

### Les compromis

| Sujet | Conséquence en distroless | Contournement |
|---|---|---|
| **Debug** | `docker exec apid sh` et `docker exec apid ls` donnent `executable file not found` (exit 127). Même `docker run … id` échoue : l'argument est passé à `node`, qui cherche le module `/app/id`. | Conteneur outil qui **partage les namespaces** : `docker run --rm --pid=container:apid --network=container:apid busybox:1.37 sh` donne `ps` et `wget` sur l'API. `--cap-add SYS_PTRACE` permet de lire les fichiers via `/proc/1/root/app`. `docker cp apid:/app/... -` fonctionne sans shell. Il y a aussi `kubectl debug --target` et `docker debug` (Docker Desktop). |
| **Image de debug** | – | Tag `:debug-nonroot`, même base avec busybox dans `/busybox/sh`. À réserver au dépannage, jamais en production. |
| **Healthcheck** | Pas de `wget`/`curl` : la sonde est en Node (`fetch` natif depuis Node 18). Elle est plus lente (≈ 100 ms) et plus gourmande en mémoire (un second processus V8). | Garder un intervalle de 30 s. En Kubernetes, le `HEALTHCHECK` Docker est ignoré au profit d'une `livenessProbe: httpGet`, faite par le kubelet sans aucun binaire dans l'image. |
| **Version de Node** | Distroless suit son propre rythme (20.20.0 contre 20.20.2) et fixe la ligne majeure dans le nom (`nodejs20`). | Épingler par digest et le faire monter via Renovate. |
| **libc** | `node_modules` est installé sur alpine (musl) puis copié sur Debian (glibc). Cela ne pose pas de problème ici puisque toutes les dépendances sont en pur JS. | Si un module natif apparaît (`bcrypt`, `sharp`…), faire `deps-prod` sur `node:20-bookworm-slim` pour la variante distroless. |
| **Scripts d'entrée** | Pas de `docker-entrypoint.sh` ni de script shell possible. | Toute la logique de démarrage doit être en Node ou dans l'orchestrateur. |

**Recommandation** : distroless pour la production (surface et CVE minimales, la même chose qui sera exigée au TP03),
alpine pour les environnements de dev et de recette où l'on veut pouvoir `docker exec sh`. Les deux sortent du même
Dockerfile, donc la CI peut construire les deux cibles sans dupliquer de logique.

## Bonus B2 : `--no-cache` contre cache mount

Script : [`bonus/b2-cache-mount.sh`](bonus/b2-cache-mount.sh). Sortie : [`diag/b2-cache-mount.txt`](diag/b2-cache-mount.txt).
Il tourne sur un builder BuildKit **dédié** (`docker buildx create --name tp01-bonus --driver docker-container`), ce qui
permet de vider tout son cache (`buildx prune -af`, cache mounts compris) sans toucher au builder habituel. Il compare
le Dockerfile final et une copie dont seul `--mount=type=cache,target=/root/.npm` a été retiré. Les valeurs sont des médianes de 3 builds.

| Scénario | Sans cache mount (total / npm ci) | Avec cache mount (total / npm ci) |
|---|---|---|
| Froid (builder vide) | 6,1 s / 2,8 s | 11,9 s / 4,1 s ¹ |
| `--no-cache` | 2,4 s / 3,0 s | 2,6 s / 3,2 s |
| **Dépendances invalidées** (lockfile modifié) | 2,3 s / **2,9 s** | 1,9 s / **1,9 s** (−35 %) |
| **Dépendances invalidées, hors ligne** (`--network=none`) | **échec** après 141 s | **OK** en 6,8 s |
| Volume téléchargé par invalidation | 9,4 Mo (dev) + 4,8 Mo (prod) | 0 |

« npm ci » est la somme des étapes `deps-dev` et `deps-prod`, qui s'exécutent en parallèle : cette somme peut donc dépasser le total.
¹ Le premier build froid inclut le téléchargement de l'image de base dans le builder vide, ce qui le rend très variable (de 4 à 12 s selon les essais).

### Ce que montrent les mesures

1. **`--no-cache` vide aussi les cache mounts.** C'est le résultat le plus important et il n'est pas intuitif.
   Avec BuildKit 0.30, un build `--no-cache` démarre avec un cache mount **vide**, d'où des temps identiques dans les deux
   variantes. Preuve : un build `--no-cache --network=none` échoue même avec le cache rempli, alors que le même build
   sans `--no-cache` (couche invalidée par un `ARG`) réussit hors ligne en 1 s.
   ```
   2. hors ligne, cache invalidé par ARG (sans --no-cache) : exit=0 1.0s cache: 5.0M
   3. hors ligne, --no-cache                               : exit=1 141.0s npm error Exit handler never called
   ```
   `--no-cache` sert donc à garantir un build « depuis zéro » (audit, image de release), pas à mesurer le cache mount.
2. **Le cache mount sert quand la couche de dépendances est invalidée**, c'est-à-dire quand `package-lock.json` change.
   Le cache de couches est alors perdu, mais npm retrouve les tarballs dans `/root/.npm` et ne télécharge que la différence.
   Ici le gain absolu est faible (≈ 1 s), parce que le projet n'a que 14 Mo de dépendances et que la connexion est rapide. Il croît
   avec le volume de dépendances et la lenteur du registre (proxy d'entreprise, Nexus/Artifactory distant) :
   c'est ce qui coûte les ≈ 4 min de la CI legacy.
3. **Build hors ligne (`--network=none`) possible seulement avec le cache mount.** C'est utile pour des runners isolés et
   pour vérifier que le build ne dépend que de ce qui a déjà été audité. Voir le bonus B1 du TP02.
4. **Cache mount et cache de couches sont complémentaires.** Le cache de couches évite *tout* le travail tant que
   `package*.json` ne bouge pas (rebuild en 0,9 s après une modification de code, étape 2). Le cache mount réduit le coût
   quand cette couche est invalidée.
5. **Limite en CI** : un cache mount reste **dans le builder**. Il n'est pas exporté par `--cache-to type=registry|gha`.
   Sur des runners éphémères, il faut un builder persistant (ou distant), ou un outil comme `buildkit-cache-dance` pour GitHub Actions.

### Garde-fou ajouté au Dockerfile

Le scénario hors ligne a révélé un vrai défaut. Sans réseau, `npm ci` abandonne au bout de 140 s
(« npm error Exit handler never called! ») mais **sort avec le code 0**. BuildKit considère alors l'étape comme
réussie, avec un `node_modules` incomplet (197 dossiers, mais `npm ls` en erreur), et le test actuel ne le voit pas puisqu'il ne charge pas
les dépendances. Une coupure réseau en CI aurait produit une image cassée sans faire échouer le build. Le Dockerfile
enchaîne désormais `npm ci … && npm ls --depth=0 >/dev/null`. `npm ls` renvoie 1 (`ELSPROBLEMS`) sur une
arborescence incomplète, ce qui fait échouer le build.

---

## Bonus B3 : image reproductible

Script : [`bonus/b3-reproductible.sh`](bonus/b3-reproductible.sh). Sortie : [`diag/b3-reproductible.txt`](diag/b3-reproductible.txt).
Chaque scénario est construit **deux fois avec `--no-cache`**. Avec le cache, BuildKit réutiliserait simplement les mêmes couches,
ce qui mesurerait le cache et non la reproductibilité. Les deux images sont exportées en archive OCI et on compare le digest
du manifeste. Les attestations sont désactivées (`--provenance=false --sbom=false`) parce qu'elles contiennent des horodatages
et des identifiants de build.

```bash
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
docker buildx build --no-cache --provenance=false \
  --build-arg SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=31ffc07 \
  --output type=oci,dest=shopapi.tar,rewrite-timestamp=true .
```

| Scénario | Digests des 2 builds | `created` | mtime d'un fichier écrit par `npm ci` |
|---|---|---|---|
| 1. Aucun réglage | ❌ `7fb775f7…` ≠ `4ea3ec81…` | heure du build (09:27:36 ≠ 09:27:39) | heure du build |
| 2. `SOURCE_DATE_EPOCH` seul | ❌ `d317b5af…` ≠ `eef8f60d…` | fixée au commit (08:56:34Z) | **heure du build** |
| 3. `SOURCE_DATE_EPOCH` + `rewrite-timestamp=true` | ✅ `ff13e787…` = `ff13e787…` | 08:56:34Z | ramenée au commit |
| 4. Idem, cible `runtime-distroless` | ✅ `cb296cb8…` = `cb296cb8…` | 08:56:34Z | ramenée au commit |

- `SOURCE_DATE_EPOCH` (argument de build reconnu par BuildKit) fixe la date `created` de l'image et celle de l'historique,
  mais **pas** les dates des fichiers créés pendant le build. Les fichiers que `npm ci` écrit dans `node_modules` portent l'heure
  du build, donc le contenu des couches, et leur digest, change à chaque fois (scénario 2).
- `rewrite-timestamp=true` réécrit les mtimes **postérieurs** à `SOURCE_DATE_EPOCH` dans les couches exportées. Les deux
  builds deviennent identiques octet pour octet (scénario 3), y compris pour la variante distroless.

### Qu'est-ce qui empêche la reproductibilité ?

| Obstacle | Dans ce projet |
|---|---|
| **Horodatages** : date `created`, historique, mtime des fichiers créés pendant le build | Réglé par `SOURCE_DATE_EPOCH` + `rewrite-timestamp` (démontré ci-dessus) |
| **Image de base mobile** (`node:20-alpine` réécrit à chaque patch) | Réglé : digest épinglé |
| **Dépendances non verrouillées** (`^4.19.2`, `npm install`) | Réglé : `package-lock.json` + `npm ci` |
| **Index de paquets de l'OS** (`apt-get update`, `apk add` sans version) : le résultat dépend du jour | Évité : aucun `apt`/`apk` dans le Dockerfile |
| **Arguments variables** (`GIT_SHA`, `APP_VERSION`, `BUILD_DATE`) | Normal : un autre commit doit donner une autre image. Pas de label `created` = `$(date)` |
| **Attestations** provenance/SBOM (horodatages, identifiant d'invocation) | Désactivées pour la comparaison. En production, on compare le digest du *manifeste image* et non celui de l'index |
| **Mtimes des fichiers source** : `rewrite-timestamp` ne modifie que les dates *postérieures* à `SOURCE_DATE_EPOCH` | Ici `src/` date de 08:37Z, avant le dernier commit du dépôt (08:56Z), puisque `26-10/` n'est pas encore commité : ces dates sont conservées. Sur un clone frais en CI, tous les fichiers sont plus récents que le commit, donc ramenés à la même date : même digest sur tous les postes |
| **Outils** : version de BuildKit (compression gzip, ordre des fichiers), *media types* Docker ou OCI selon l'exporteur | Même builder (BuildKit 0.30) pour les deux builds. D'un poste à l'autre, il faut épingler la version du builder |
| **Code non déterministe** dans un `RUN` (scripts `postinstall`, compilation native qui embarque un chemin ou une date) | Aucun module natif. `npm ls` n'écrit rien |

**Intérêt** : un tiers (auditeur, autre runner) peut reconstruire l'image depuis le commit et vérifier qu'il obtient **le même
digest** que celui qui a été signé et déployé. C'est la base de la vérification de chaîne d'approvisionnement du TP03
(SLSA, signature cosign du digest).
