# Livrable 1 : diagnostic de l'image `shopapi:legacy`

Environnement : Docker Engine 29.5.2 (containerd image store), macOS arm64.
`hadolint` (v2.15.1) et `dive` (v0.13.1) sont lancés en conteneur (`hadolint/hadolint`, `wagoodman/dive`).
Le Dockerfile d'origine est conservé dans [`Dockerfile.legacy`](Dockerfile.legacy). Les sorties brutes des commandes sont dans [`diag/`](diag/).

```bash
docker build -f Dockerfile.legacy -t shopapi:legacy .
```

## Vue d'ensemble

| Indicateur | Valeur | Preuve |
|---|---|---|
| Taille sur disque | **1,06 Go** (279 Mo compressés, 746 Mo de système de fichiers) | `docker image ls`, `du -sh /` |
| Utilisateur | `uid=0(root)` | `docker run --rm shopapi:legacy id` |
| Secrets | 3 (ENV `DATABASE_URL`, `.env`, dump SQL) | voir S1 à S3 |
| Arrêt | 10,1 s, code de sortie **137** (SIGKILL) | `time docker stop` |
| hadolint | 6 warnings, 4 infos, code de sortie 1 | [`diag/hadolint-legacy.txt`](diag/hadolint-legacy.txt) |
| Healthcheck / labels OCI | absents | `docker inspect` |

---

## A. Taille et performance

### P1 : image de base généraliste et Node installé à la main
```
$ docker image ls shopapi:legacy
IMAGE            ID             DISK USAGE   CONTENT SIZE
shopapi:legacy   cd87e0777ee1       1.06GB          279MB
$ docker history shopapi:legacy
RUN /bin/sh -c apt-get install -y nodejs              173MB
ADD file:1e8b3941ec802b3e9…   (ubuntu:22.04)            79.5MB
```
**Impact** : `ubuntu:22.04`, plus Node installé via NodeSource, revient à rebâtir ce que l'image officielle `node:20-alpine` fournit déjà en environ 50 Mo compressés. Le registre sature, les pulls sont lents et le démarrage des nœuds aussi.

### P2 : outils de build et de debug dans l'image d'exécution
```
$ docker history shopapi:legacy
RUN /bin/sh -c apt-get install -y curl wget vim git build-essential python3   379MB
$ docker run --rm shopapi:legacy du -sh /usr/lib/gcc /usr/lib/git-core
90M  /usr/lib/gcc
8.8M /usr/lib/git-core
```
**Impact** : c'est la plus grosse couche (379 Mo), et aucun de ces outils ne sert à l'exécution. Elle augmente aussi la surface d'attaque (voir S5).

### P3 : index APT non supprimé et `apt-get update` dans une couche séparée
```
$ docker run --rm shopapi:legacy du -sh /var/lib/apt/lists
77M  /var/lib/apt/lists
hadolint : -:4 DL3009 info: Delete the apt lists (/var/lib/apt/lists) after installing something
```
**Impact** : 77 Mo inutiles (la couche `apt-get update` pèse 80,7 Mo). Comme l'`update` est dans un `RUN` à part, sa couche reste en cache : un futur `apt-get install` modifié utilisera un index périmé, avec un risque de paquets introuvables ou obsolètes.

### P4 : paquets « recommandés » installés
```
hadolint : -:5 DL3015 info: Avoid additional packages by specifying `--no-install-recommends`
hadolint : -:7 DL3015 info: ...
```
**Impact** : des dépendances supplémentaires sont installées sans avoir été demandées, ce qui alourdit l'image et la surface d'attaque.

### P5 : invalidation du cache. `COPY . /app` passe avant `npm install`
```
$ echo "// commentaire" >> src/server.js
$ docker build -f Dockerfile.legacy -t shopapi:legacy .
#12 [8/9] COPY . /app       DONE 0.0s
#13 [9/9] RUN npm install   added 222 packages ... in 10s   <- rejoué
legacy, après commentaire : 15.50 s
```
**Impact** : n'importe quel changement dans le contexte (code, README, et même un fichier ajouté à côté) invalide la couche `COPY . /app` et donc `npm install`. On paie ~10 s en local et ≈ 4 min en CI à chaque commit. Le détail est dans [`diag/cache-legacy.txt`](diag/cache-legacy.txt).

### P6 : pas de `.dockerignore`
```
$ docker run --rm shopapi:legacy ls -la /app
-rw-r--r--  .env
-rw-r--r--  .gitignore
-rw-r--r--  Dockerfile
-rw-r--r--  dump-prod-2024.sql
drwxr-xr-x  node_modules
```
**Impact** : tout le répertoire est envoyé au daemon puis copié dans l'image, y compris les secrets, le dump, le Dockerfile et un éventuel `node_modules` local compilé pour macOS (non portable vers Linux). Chaque fichier modifié casse le cache.

### P7 : dépendances de développement et cache npm dans l'image finale
```
$ docker run --rm shopapi:legacy sh -c 'ls /app/node_modules | grep -E "^(eslint|nodemon)$"; which nodemon'
eslint
nodemon
/usr/bin/nodemon
$ docker run --rm shopapi:legacy du -sh /root/.npm
34M  /root/.npm
```
**Impact** : 196 paquets dans `node_modules` (contre 111 en production), `nodemon` installé en global en plus, et un cache npm de 34 Mo. Ce sont des mégaoctets et des CVE potentielles pour du code qui ne s'exécute jamais en production.

### P8 : build non reproductible (pas de lockfile, `npm install`)
```
$ docker run --rm shopapi:legacy ls -la /app
-rw-r--r--  96529  package-lock.json      <- généré PENDANT le build, absent du dépôt
package.json : "express": "^4.19.2", "pg": "^8.12.0", ...
```
**Impact** : les plages `^` sont résolues au moment du build. Deux builds du même commit peuvent donc embarquer des versions différentes, ce qui rend impossible de garantir que l'image testée est celle qui est déployée.

### P9 : trop de couches `RUN` consécutives
```
hadolint : -:5 DL3059 info: Multiple consecutive `RUN` instructions. Consider consolidation.
hadolint : -:8 DL3059 info: ...
```
**Impact** : les fichiers créés puis supprimés dans des couches différentes restent dans l'image. `dive` mesure 4 Mo de gaspillage strict (`dpkg.log`, `status-old`, ...). Remarque : l'efficacité dive de 99,6 % est trompeuse. dive ne détecte que les fichiers écrasés ou supprimés d'une couche à l'autre, pas les fichiers *inutiles mais présents* (P2, P3, P7), et c'est pourtant là que se trouve l'essentiel du poids. Sortie complète : [`diag/dive-legacy.txt`](diag/dive-legacy.txt).

---

## B. Sécurité

### S1 : mot de passe de base de données en `ENV` dans l'image
```
$ docker run --rm shopapi:legacy env | grep -i -E 'secret|database'
DATABASE_URL=postgres://shop:S3cret!@db.internal:5432/shop
$ docker history shopapi:legacy
ENV DATABASE_URL=postgres://shop:S3cret!@db.…
$ docker inspect shopapi:legacy --format '{{json .Config.Env}}'
[..., "NODE_ENV=development", "DATABASE_URL=postgres://shop:S3cret!@db.internal:5432/shop"]
```
**Impact** : quiconque peut faire un pull de l'image (CI, développeurs, registre compromis) lit l'identifiant de la base de production, sans même lancer de conteneur. Le secret est figé dans les métadonnées : il faut changer le mot de passe et reconstruire.

### S2 : fichier `.env` avec une clé AWS copié dans l'image
```
$ docker run --rm shopapi:legacy cat /app/.env
DATABASE_URL=postgres://shop:S3cret!@localhost:5432/shop
REDIS_URL=redis://localhost:6379
AWS_SECRET_ACCESS_KEY=AKIAFAKEFAKEFAKEFAKE
```
**Impact** : une clé cloud fuit dans chaque copie de l'image. Les scanners de secrets (trivy, voir TP03) la détectent, mais les attaquants aussi.

### S3 : dump de production dans l'image
```
$ docker run --rm shopapi:legacy ls -la /app
-rw-r--r--  1 root root  47  dump-prod-2024.sql
```
**Impact** : des données de production (et potentiellement personnelles, RGPD) se retrouvent distribuées avec l'application. Le vrai fichier fait 50 Mo, qui s'ajoutent aussi à la taille de l'image.

### S4 : le conteneur tourne en root
```
$ docker run --rm shopapi:legacy id
uid=0(root) gid=0(root) groups=0(root)
$ docker exec legacy ps -eo pid,ppid,user,args
  1  0 root /bin/sh -c npm start
 19 18 root node src/server.js
```
**Impact** : une RCE dans l'API (Express ou une dépendance) donne root dans le conteneur. En cas d'évasion du conteneur, ou avec un volume monté, c'est root sur l'hôte. Kubernetes refuse aussi ces pods avec `runAsNonRoot: true`.

### S5 : surface d'attaque (compilateur, git, curl, wget, vim)
```
apt-get install -y curl wget vim git build-essential python3
```
**Impact** : un attaquant dispose sur place de quoi télécharger (`curl`/`wget`), compiler (`gcc`) et exfiltrer (`git`). Chaque paquet apporte aussi des CVE que les scanners remonteront (bruit, puis blocage de la release au TP03).

### S6 : chaîne d'approvisionnement non maîtrisée (rien d'épinglé, `curl | bash`)
```
FROM ubuntu:22.04                                         <- tag mobile, réécrit à chaque mise à jour
hadolint : -:5 DL3008 warning: Pin versions in apt get install
hadolint : -:6 DL4006 warning: Set the SHELL option -o pipefail before RUN with a pipe in it
hadolint : -:8 DL3016 warning: Pin versions in npm
```
**Impact** : `curl -fsSL https://deb.nodesource.com/setup_20.x | bash -` exécute en root un script distant sans le vérifier. Sans `pipefail`, si `curl` échoue, le build continue silencieusement. Rien n'est épinglé, ni l'image de base, ni les paquets APT, ni `nodemon`. Le build d'aujourd'hui n'est pas celui d'hier, et une dépendance compromise entre dans l'image sans que personne ne s'en aperçoive.

---

## C. Exploitabilité

### E1 : `CMD` en forme shell, SIGTERM jamais reçu par Node
```
$ docker inspect shopapi:legacy --format '{{json .Config.Cmd}}'
["/bin/sh","-c","npm start"]
$ docker exec legacy ps -eo pid,ppid,user,args
  1  0 root /bin/sh -c npm start
  7  1 root npm start
 18  7 root sh -c node src/server.js
 19 18 root node src/server.js
$ time docker stop legacy
docker stop legacy  ... 10.134 total
$ docker inspect legacy --format '{{.State.ExitCode}}'
137
hadolint : -:15 DL3025 warning: Use arguments JSON notation for CMD and ENTRYPOINT arguments
```
**Impact** : PID 1 est `/bin/sh`, qui ne relaie pas SIGTERM à ses enfants. Comme le noyau ignore les signaux sans handler pour un PID 1, rien ne se passe. Docker attend son timeout (10 s), puis envoie SIGKILL (code 137). Le handler `shutdown()` de `server.js` ne s'exécute jamais : les requêtes en cours sont coupées et les connexions PG/Redis ne sont pas fermées. Chaque réplique bloque le rolling update pendant 10 s ou plus (30 s en production avec le `terminationGracePeriod`). Quatre processus (sh, npm, sh, node) tournent là où un seul suffit.

### E2 : pas de `HEALTHCHECK`
```
$ docker inspect shopapi:legacy --format '{{json .Config.Healthcheck}}'
null
```
**Impact** : Docker et Compose considèrent le conteneur sain dès que le processus existe, même si l'API ne répond pas (boucle d'événements bloquée, port non ouvert). Ni `depends_on: condition: service_healthy` ni le redémarrage automatique ne sont possibles.

### E3 : labels OCI absents (et un label hérité trompeur)
```
$ docker inspect shopapi:legacy --format '{{json .Config.Labels}}'
{"org.opencontainers.image.version":"22.04"}
```
**Impact** : le seul label présent vient d'Ubuntu et annonce une « version 22.04 » de shopapi. Impossible de savoir quel commit ou quelle version tourne en production, ni de remonter au dépôt source (audit, SBOM, porte de release du TP03).

### E4 : `NODE_ENV=development` en production
```
ENV NODE_ENV=development
```
**Impact** : Express et les bibliothèques passent en mode développement (pas de cache des vues, messages d'erreur détaillés par défaut, performances dégradées). Le comportement en production diffère de ce qui a été validé.

### E5 : aucun test ni lint dans le build
Le Dockerfile ne lance ni `npm test` ni `npm run lint`.
**Impact** : on peut construire et pousser une image qui ne passe pas les tests. La qualité dépend alors de la discipline de chacun, pas du pipeline.

---

## Synthèse

| # | Catégorie | Problème | Gravité |
|---|---|---|---|
| S1 | Sécurité | Mot de passe DB en `ENV` | Critique |
| S2 | Sécurité | `.env` avec clé AWS copié | Critique |
| S3 | Sécurité | Dump de prod dans l'image | Critique |
| S4 | Sécurité | Exécution en root | Haute |
| S6 | Sécurité | `curl \| bash`, rien d'épinglé | Haute |
| S5 | Sécurité | Outils de build/debug présents | Moyenne |
| E1 | Exploitabilité | Forme shell, SIGTERM perdu (10 s, exit 137) | Haute |
| E2 | Exploitabilité | Pas de healthcheck | Moyenne |
| E3 | Exploitabilité | Pas de labels OCI (label trompeur) | Moyenne |
| E4 | Exploitabilité | `NODE_ENV=development` | Moyenne |
| E5 | Exploitabilité | Pas de tests dans le build | Moyenne |
| P1 | Taille/perf | Base ubuntu + NodeSource (1,06 Go) | Haute |
| P2 | Taille/perf | build-essential, git, vim... (379 Mo) | Haute |
| P5 | Taille/perf | Cache invalidé à chaque commit | Haute |
| P6 | Taille/perf | Pas de `.dockerignore` | Haute |
| P3 | Taille/perf | Index APT conservé (77 Mo) | Moyenne |
| P7 | Taille/perf | devDependencies + cache npm (34 Mo) | Moyenne |
| P8 | Taille/perf | Pas de lockfile, `npm install` | Moyenne |
| P4 | Taille/perf | Pas de `--no-install-recommends` | Faible |
| P9 | Taille/perf | Couches `RUN` multiples | Faible |

> Ce qu'il faut faire au-delà de l'image : les secrets S1 et S2 ont été publiés, donc **il faut les changer**
> (mot de passe PG, clé AWS). Les retirer du Dockerfile ne rend pas inutilisables les images déjà poussées dans le registre.
> Ces secrets doivent être injectés à l'exécution (`docker run -e` / `--env-file`, secrets Compose/Kubernetes, Vault).
