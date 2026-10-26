# TP02 : BuildKit avancé (cache, secrets, multi-architecture, bake)

Environnement : Mac Apple Silicon (arm64), Colima (VZ), Docker Engine 29.5.2, buildx 0.34.1, BuildKit 0.30.0.
Les sorties brutes de toutes les commandes sont dans [`shop-worker/diag/`](shop-worker/diag/), et les scripts de mesure
dans [`shop-worker/mesures/`](shop-worker/mesures/).

| Livrable | Fichier |
|---|---|
| Dockerfile final | [`shop-worker/Dockerfile`](shop-worker/Dockerfile) (`builder` → `test` → `runtime`) |
| Bake | [`docker-bake.hcl`](docker-bake.hcl) (à lancer depuis `starter/`) |
| Rapport | ce fichier |
| Annexes | [`shop-worker/Dockerfile.leak`](shop-worker/Dockerfile.leak) (Dockerfile d'origine), [`.dockerignore`](shop-worker/.dockerignore), `.gitignore` (contient `pip.conf`) |
| Bonus | [`shop-worker/bonus/`](shop-worker/bonus/) : `Dockerfile.offline` (B1), `Dockerfile.uv` et `b3-pip-vs-uv.sh` (B3) |

Infrastructure créée pour le TP (toujours en place) :

```bash
docker buildx create --name shop --driver docker-container --driver-opt network=host
docker run -d --name tp02-registry --restart unless-stopped -p 5050:5000 registry:2.8.3
```

- **`network=host`** : sans cette option, `localhost` dans le conteneur BuildKit désigne le conteneur lui-même, pas le
  registre. Le `docker buildx create` du README ne pourrait donc pas pousser vers `localhost:5000`.
- **Port 5050 au lieu de 5000** : sur macOS, le port 5000 est déjà pris par le récepteur AirPlay (`ControlCenter`). Les
  commandes qui tournent côté Mac (`imagetools inspect`, `curl`) tomberaient sur lui.
- **`BUILDX_BUILDER=shop`** : je l'ai exporté au lieu de `--use`, pour ne pas changer le builder par défaut du poste.

---

## 1. Prouver la fuite

```
$ docker build --build-arg PIP_INDEX_URL=https://svc-ci:Tr3sS3cret@pypi.internal.example.com/simple -t worker:leak .
0.870 Looking in indexes: https://svc-ci:****@pypi.internal.example.com/simple
8.435 ERROR: Could not find a version that satisfies the requirement redis==5.0.8 (from versions: none)
ERROR: failed to build: ... exit code: 1
$ docker history --no-trunc worker:leak | grep -i secret
(rien : l'image n'existe pas)
```

pip masque le mot de passe dans ses propres logs (`****`), mais c'est bien le seul endroit où il est protégé.
Pour montrer où il apparaîtrait si le build réussissait, [`diag/leak-demo/Dockerfile`](shop-worker/diag/leak-demo/Dockerfile)
reproduit le même mécanisme sans réseau : un `ARG` lu par pip, puis un `pip.conf` écrit et « supprimé » au `RUN` suivant,
un schéma courant. Preuves complètes : [`diag/etape1-preuves.txt`](shop-worker/diag/etape1-preuves.txt).

> **Piège du README** : `grep -i secret` ne trouve **jamais** rien, car le mot de passe s'écrit `Tr3sS3cret`, avec un *3*.
> Il faut chercher la vraie valeur (`grep S3cret`).

| # | Où le secret est visible | Preuve |
|---|---|---|
| 1 | **`docker history`** : chaque `RUN` qui suit l'`ARG` enregistre sa valeur | `RUN \|1 PIP_INDEX_URL=https://svc-ci:Tr3sS3cret@… /bin/sh -c pip …` |
| 2 | **`docker inspect` / config OCI** : l'historique fait partie de la config de l'image, il est donc **poussé au registre** et lisible par quiconque fait un pull | `jq '.history[].created_by'` sur la config extraite par `docker save` |
| 3 | **Couche intermédiaire** : `rm /etc/pip.conf` ajoute une couche qui masque le fichier, mais la couche précédente le contient toujours | `docker run … cat /etc/pip.conf` donne « No such file », mais `docker save` puis l'extraction de la couche `bb10e557…` affichent `index-url = https://svc-ci:Tr3sS3cret@…` |
| 4 | **Historique des builds BuildKit**, conservé **même pour le build en échec** | `docker buildx history inspect lt17xosz…` : `PIP_INDEX_URL  https://svc-ci:Tr3sS3cret@…` |
| 5 | **Ligne de commande** : `ps`, historique du shell, logs du job CI qui affichent la commande | `--build-arg PIP_INDEX_URL=https://svc-ci:Tr3sS3cret@…` |
| 6 | **Le Dockerfile lui-même** : la valeur par défaut `https://user:password@…` est commitée dans git | `Dockerfile.leak:5` |

À cela s'ajoutent le cache de build (la clé de cache contient la valeur de l'`ARG`) et l'attestation de provenance
`--provenance=mode=max`, qui enregistre les build args (bonus B2).

---

## 2. Secret mount

```dockerfile
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf,required=true \
    --mount=type=cache,target=/root/.cache/pip,id=pip-${TARGETARCH} \
    pip install -r requirements.txt
```

```bash
printf '[global]\nindex-url = https://pypi.org/simple\n' > pip.conf      # gitignored, exclu du contexte par .dockerignore
docker build --secret id=pipconf,src=pip.conf --build-arg APP_VERSION=1.0.0 --build-arg GIT_SHA=$(git rev-parse --short HEAD) -t worker:1.0 .
```

| Étape | Rôle |
|---|---|
| `builder` | venv `/opt/venv` avec les seules dépendances de production. Secret monté le temps du `RUN`. |
| `test` | Part de `builder`, ajoute `requirements-dev.txt`, puis `ruff check .` et `python -m pytest`. |
| `runtime` | `python:3.12.15-slim-trixie` épinglée par digest. Copie le venv et le code. Utilisateur `worker` (uid 10001), labels OCI, `HEALTHCHECK` sur `/metrics`, `CMD` en forme exec. |

Choix à noter :
- **`required=true`** : sans secret, le build échoue au lieu de se rabattre en silence sur pypi.org, ce qui contournerait
  le registre interne (et ses contrôles).
- **`COPY --from=test /app/worker`** : comme au TP01, sans cela BuildKit sauterait l'étape `test` lors d'un build sans `--target`.
- **`python -m pytest`** et non `pytest` : seul le premier ajoute `/app` au `sys.path`, et `pytest` seul ne trouverait pas le paquet `worker`.
- **`.dockerignore` en liste blanche** : même un `docker build` lancé par erreur sans `--secret` ne peut pas embarquer
  `pip.conf` via `COPY`.

### Vérifications ([`diag/etape2-verifications.txt`](shop-worker/diag/etape2-verifications.txt))

```
$ docker history --no-trunc worker:1.0 | grep -iE "S3cret|pip.conf|index-url"     -> (aucune sortie)
$ docker run --rm worker:1.0 cat /etc/pip.conf                                  -> No such file or directory
$ docker save worker:1.0 -> recherche de pip.conf / index-url dans toutes les couches -> aucune occurrence
$ docker buildx history inspect <build>   -> BUILD ARG : APP_VERSION, GIT_SHA seulement (les secrets n'y figurent jamais)
$ docker run --rm worker:1.0 id                                                 -> uid=10001(worker)
$ docker run --rm worker:1.0 pip list | grep -iE "pytest|ruff"                  -> (aucune sortie)
healthy · docker stop : 0,13 s, exit 0 (« signal 15 reçu » puis « worker arrêté proprement »)
```

Le `pip install` n'apparaît même pas dans `docker history worker:1.0` : il a lieu dans l'étape `builder`, dont
l'historique n'est pas embarqué dans l'image finale.

**Constat important : le secret ne fait pas partie de la clé de cache.**

```
$ docker build -t worker:nosecret .               # sans --secret, cache chaud
#18 [builder 5/5] RUN --mount=type=secret,id=pipconf,...,required=true ... pip install -r requirements.txt
#18 CACHED                                         -> exit 0 : le build RÉUSSIT sans secret
$ docker build --no-cache -t worker:nosecret .
ERROR: failed to build: failed to solve: secret pipconf: not found
```

C'est voulu : changer le mot de passe n'invalide pas le cache, et la valeur du secret ne fuit pas par le cache. En revanche,
`required=true` n'est vérifié **que si le `RUN` s'exécute**. Il ne remplace donc pas un contrôle en CI. Et si le *contenu* fourni par
le secret doit compter (un index différent par exemple), il faut invalider le cache explicitement (`ARG` d'index, `--no-cache-filter builder`).

### Alternatives

- **`--mount=type=ssh`** pour les dépendances Git privées (`git+ssh://git@github.com/shop/lib.git`) : l'agent SSH de l'hôte est
  relayé (`docker build --ssh default .`). La clé privée n'entre jamais dans le build, seul le socket de l'agent est monté.
- **Secret depuis une variable d'environnement** : `docker build --secret id=PIP_TOKEN,env=PIP_TOKEN`, pratique en CI où les secrets
  sont déjà des variables (`${{ secrets.X }}`). Côté Dockerfile, il est monté comme fichier (`/run/secrets/PIP_TOKEN`), ou directement
  en variable avec `RUN --mount=type=secret,id=PIP_TOKEN,env=PIP_TOKEN` (syntaxe `dockerfile:1.10` et plus). Attention : une variable
  d'environnement est visible par tous les processus du `RUN`, et parfois dans leurs messages d'erreur.
- **Ne jamais** utiliser `ARG`/`ENV` pour un secret, ni `COPY` d'un fichier de credentials suivi de `rm`. Le multi-stage
  ne suffit pas non plus : le secret reste dans le cache et l'historique de l'étape intermédiaire.

---

## 3. Cache mount

Script : [`mesures/etape3-cache.sh`](shop-worker/mesures/etape3-cache.sh). Sortie : [`diag/etape3-cache.txt`](shop-worker/diag/etape3-cache.txt).
Il rejoue la séquence du README sur le builder `shop`, avec et sans `--mount=type=cache`, et restaure `requirements.txt` à la fin.
Comme les temps sont trop courts pour être fiables à eux seuls (connexion rapide, peu de dépendances), j'ai aussi compté les lignes
`Downloading` (paquet téléchargé) et `Using cached` (paquet servi par le cache pip) dans les logs de pip.

| Étape | Sans cache mount : pip / téléchargés / en cache | Avec cache mount : pip / téléchargés / en cache | Cache mount pip après l'étape |
|---|---|---|---|
| 1. build initial (builder vide) | 2,1 s / 16 / 0 | 2,2 s / 16 / 0 | 15,5 Mo |
| 2. `docker builder prune -f` | | | **supprimé** |
| 3. `+ requests==2.32.3`, rebuild | 3,1 s / 26 / 0 | 2,4 s / 26 / 0 | |
| 4. `--no-cache` | 2,5 s / 26 / 0 | 2,5 s / **26 / 0** | |
| 5. `prune -f --filter type=regular` | | | **conservé** (16,9 Mo) |
| 6. rebuild après ce prune | 2,4 s / 26 / 0 | **1,5 s / 0 / 26** | |

### Cache de couches et cache mount : quelle différence ?

| | Cache de couches | Cache mount (`type=cache`) |
|---|---|---|
| Contenu | Le **résultat** d'une instruction (système de fichiers après le `RUN`) | Un **répertoire de travail** persistant (`/root/.cache/pip`) |
| Clé | Instruction + parent + fichiers copiés | Un `id` (ici `pip-${TARGETARCH}`), indépendant des instructions |
| Quand il sert | Tout ou rien : si `requirements.txt` change, la couche est perdue | Précisément quand la couche est invalidée : pip retrouve ses wheels et ne télécharge que la différence |
| Dans l'image ? | Oui (c'est la couche) | **Jamais** |
| Exporté (`--cache-to`) | Oui | **Non** : il reste dans le builder |

### Ce que montrent les mesures

1. **Le README se trompe : `docker builder prune -f` supprime aussi le cache mount.** Un cache mount qui n'est pas en cours
   d'utilisation est « reclaimable » et part avec le reste (étape 2 : absent). Pour ne vider que le cache de couches, il faut
   `docker builder prune -f --filter type=regular` (étape 5 : cache mount conservé).
2. **Quand il est conservé, le cache mount évite tout téléchargement** (étape 6 : 0 paquet téléchargé, 26 servis depuis le cache, pip
   en 1,5 s au lieu de 2,4 s). Le gain est modeste ici : 17 Mo de wheels et une bonne connexion. Il croît avec la taille des
   dépendances et la lenteur du registre (proxy d'entreprise, Nexus/Artifactory distant).
3. **`--no-cache` ignore aussi le cache mount** (étape 4 : 26 téléchargements, même avec le cache mount). BuildKit démarre avec un cache
   mount vide : `--no-cache` garantit un build entièrement « depuis zéro ». J'avais fait le même constat avec npm au TP01 (bonus B2).

---

## 4. Multi-architecture

Sorties : [`diag/etape4-multiarch.txt`](shop-worker/diag/etape4-multiarch.txt), [`diag/etape4-plateformes.txt`](shop-worker/diag/etape4-plateformes.txt).

```bash
BUILDX_BUILDER=shop docker buildx build --platform linux/amd64,linux/arm64 --secret id=pipconf,src=pip.conf \
  --build-arg APP_VERSION=1.0.0 --build-arg GIT_SHA=6c6d9a7 -t localhost:5050/shop-worker:1.0 --push .     # 27 s
docker buildx imagetools inspect localhost:5050/shop-worker:1.0
```

```
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:6d4582ab…
Manifests:
  …@sha256:b8df05e4…  Platform: linux/amd64
  …@sha256:9a12ece5…  Platform: linux/arm64
  …@sha256:160a0573…  Platform: unknown/unknown  vnd.docker.reference.type: attestation-manifest  (-> b8df05e4)
  …@sha256:295ddb7a…  Platform: unknown/unknown  vnd.docker.reference.type: attestation-manifest  (-> 9a12ece5)
```

| Plateforme | Build `--no-cache` | `pip install` (builder) | pytest |
|---|---|---|---|
| linux/arm64 (natif) | **5,3 s** | 0,8 s | 0,03 s |
| linux/amd64 (émulé) | **23,2 s** (×4,4) | 3,8 s | 0,21 s (×7) |

Les deux variantes s'exécutent : `docker run --platform linux/amd64 …` affiche `x86_64 3.12.15`, et en arm64 `aarch64 3.12.15`.

### Réponses

- **Pourquoi `--push` ou `-o` est-il obligatoire ?** Un build multi-plateforme produit un *index* (plusieurs images), que le
  stockage d'images classique de Docker ne sait pas contenir. Avec le driver `docker-container`, le résultat reste sinon dans le cache du
  builder (`WARNING: No output specified … Build result will only remain in the build cache`). Il faut donc l'envoyer quelque part :
  au registre (`--push`) ou dans une archive (`-o type=oci,dest=worker.tar`). Nuance : avec le **containerd image store**
  (activé sur ce poste), `--load` accepte le multi-plateforme. L'image `shop-worker:multi` apparaît avec ses deux
  variantes (`docker image ls --tree`).
- **Que contient le *manifest list* ?** Un index OCI avec, pour chaque plateforme, le digest de son manifeste (lui-même pointant
  vers la config et les couches de cette architecture). BuildKit y ajoute un **manifeste d'attestation** par image
  (`unknown/unknown`, provenance SLSA), relié à l'image par l'annotation `vnd.docker.reference.digest`. Le client fait un pull
  du tag, lit l'index et ne télécharge que le manifeste de sa plateforme.
- **`TARGETARCH` pour isoler le cache pip** : `ARG TARGETARCH`, puis `--mount=type=cache,target=/root/.cache/pip,id=pip-${TARGETARCH}`.
  Le builder contient bien deux caches distincts, `id "/pip-amd64"` et `id "/pip-arm64"`. Sans cela, les deux builds parallèles
  partageraient le même répertoire et y mélangeraient leurs wheels (`manylinux_x86_64` et `aarch64`), avec des risques de
  verrous et de cache pollué.
- **Pourquoi l'architecture émulée est-elle plus lente ?** Ici, c'est **amd64 sur un hôte arm64** (l'inverse de l'énoncé, même
  principe). Le noyau de la VM Colima confie les binaires x86-64 à `qemu-x86_64` (binfmt_misc, flag `F`), qui **traduit chaque
  instruction** à la volée en mode utilisateur. Tout ce qui calcule (interpréteur Python, décompression des wheels, ruff)
  devient 4 à 7 fois plus lent. **Alternatives** :
  - **Nœuds natifs** dans le même builder, un par architecture :
    `docker buildx create --name shop --driver docker-container --platform linux/arm64` puis
    `docker buildx create --append --name shop --driver docker-container --platform linux/amd64 runner-amd64`
    (`runner-amd64` étant un contexte Docker pointant vers une machine x86, par exemple `ssh://ci@runner-amd64`). BuildKit envoie
    chaque plateforme au nœud natif correspondant.
  - **Builders distants managés** (Docker Build Cloud, runners arm64 natifs GitHub/GitLab).
  - **Compilation croisée** avec `FROM --platform=$BUILDPLATFORM`, quand la chaîne le permet (Go, Rust…). Pour Python, on peut
    télécharger les wheels de la cible depuis l'hôte (`pip download --platform manylinux2014_aarch64 --only-binary=:all:`).

---

## 5. Cache distant

Script : [`mesures/etape5-cache-distant.sh`](shop-worker/mesures/etape5-cache-distant.sh). Sortie :
[`diag/etape5-cache-distant.txt`](shop-worker/diag/etape5-cache-distant.txt). Chaque « runner » est simulé par un builder
**entièrement vidé** (`buildx prune -af`), donc sans cache local ni cache mount, comme un runner CI éphémère.

```bash
docker buildx build --cache-to type=registry,ref=localhost:5050/cache:worker-max,mode=max \
                    --cache-from type=registry,ref=localhost:5050/cache:worker-max ...
```

| Scénario (linux/arm64) | `mode=min` | `mode=max` | Sans cache distant |
|---|---|---|---|
| Runner A : build + export du cache | 8,9 s | 8,7 s | 7,6 s |
| Runner B neuf, même commit | **2,6 s**, 0 étape exécutée | **2,1 s**, 0 étape exécutée | 7,6 s, 12 étapes |
| Runner C neuf, **code modifié** | 8,6 s, **9 étapes** (dont les 2 `pip install`) | **3,3 s, 4 étapes** (2 `COPY`, ruff + pytest, copie finale) | 7,6 s, 12 étapes |
| Taille du cache dans le registre | 51 Mo | 73 Mo | – |

- **`mode=min`** (défaut) n'exporte que les couches de l'**image finale**. Les étapes `builder` et `test` n'y figurent pas :
  dès que le code change, le runner refait le venv et réinstalle les dépendances de dev. C'est le cas de la plupart des commits.
- **`mode=max`** exporte les couches de **toutes les étapes**, intermédiaires comprises. Le cache est plus gros (+43 % ici) et
  l'export plus long, mais seules les étapes réellement touchées sont rejouées. Pour un multi-stage, `max` est presque toujours le bon choix.
- **Variantes CI** :
  - `type=gha` (cache GitHub Actions, avec `scope=` par image/branche, quota de 10 Go par dépôt) ;
  - `type=s3` (bucket S3/MinIO, `region=`, `bucket=`, `name=`) ;
  - `type=azblob`, et `type=local,dest=…` (répertoire partagé ou mis en cache par le CI).
- **Limite** : les cache mounts (`type=cache`) ne sont **pas** exportés. Sur un runner neuf, le `pip install` qui doit être
  rejoué retélécharge tout. Il faut alors un builder persistant (BuildKit distant), ou une astuce comme `buildkit-cache-dance` sur GitHub Actions.

---

## 6. `docker buildx bake`

[`docker-bake.hcl`](docker-bake.hcl), à lancer depuis `starter/` :

| Élément | Contenu |
|---|---|
| Variables | `VERSION`, `GIT_SHA`, `REGISTRY` (défaut `localhost:5050`), surchargeables par l'environnement |
| `_common` (abstraite) | Plateformes `linux/amd64` + `linux/arm64`, args `APP_VERSION`/`GIT_SHA`, labels OCI (version, revision, source, vendor) |
| Fonctions `cache_from` / `cache_to` / `tag` | Un ref de cache **par cible** (`cache:api`, `cache:worker`, `mode=max`). Un ref commun serait écrasé par la dernière cible construite. Si `REGISTRY=""`, tags locaux et aucun cache distant. |
| `group "default"` | `api` (contexte TP01, étape `runtime`) + `worker` (étape `runtime`, secret `pipconf`) |
| `worker-test` | Hérite de `worker`, `target = "test"`, `output = ["type=cacheonly"]`, pas de `cache-to` : n'exécute que lint et tests, sur les deux architectures |

Sorties : [`diag/etape6-bake-print.txt`](shop-worker/diag/etape6-bake-print.txt), [`diag/etape6-bake.txt`](shop-worker/diag/etape6-bake.txt).

```
$ docker buildx bake --print                                   -> plan JSON, sans builder
$ VERSION=1.0 GIT_SHA=6c6d9a7 docker buildx bake worker-test   -> All checks passed! · 2 passed (amd64 et arm64), 23 s
$ VERSION=1.0 GIT_SHA=6c6d9a7 docker buildx bake --set *.platform=linux/arm64 --load
  -> localhost:5050/shop-worker:1.0 et localhost:5050/shopapi:1.0 chargées, labels version=1.0 / revision=6c6d9a7
$ VERSION=1.0 GIT_SHA=6c6d9a7 docker buildx bake --allow=fs.read=../../tp01-optimisation-image/starter/shopapi --push
$ docker buildx imagetools inspect localhost:5050/{shopapi,shop-worker}:1.0  -> linux/amd64 + linux/arm64 chacune
$ docker buildx prune -af && docker buildx bake worker-test    -> 2,2 s, 19 étapes servies par le cache distant
```

À savoir :
- **Premier passage** : `ERROR: failed to configure registry cache importer: localhost:5050/cache:worker: not found` est
  **bénin**. Le cache n'existe pas encore, BuildKit continue sans lui et l'exporte à la fin.
- **`--allow=fs.read`** : depuis buildx 0.17, bake refuse de lire un contexte situé hors du répertoire courant (ici l'API du
  TP01) tant qu'on ne l'autorise pas (« additional privileges requested »). Sur ce poste, la vérification s'est déclenchée de
  façon **intermittente** pour la même commande : je recommande de toujours passer `--allow`, plutôt que `BUILDX_BAKE_ENTITLEMENTS_FS=0`
  qui désactive la protection.
- Les deux cibles du groupe sont construites **en parallèle** par un seul appel, avec un plan versionné dans le dépôt : la
  CI n'a plus qu'à lancer `VERSION=$TAG GIT_SHA=$SHA docker buildx bake --push`.

---

## Bonus B1 : build sans accès Internet (`--network=none`)

Sortie : [`diag/bonus-b1-offline.txt`](shop-worker/diag/bonus-b1-offline.txt).

**Avec le Dockerfile principal, ça ne marche pas**, même avec un cache mount rempli juste avant :

```
en ligne (remplit /root/.cache/pip)        : exit=0
hors ligne, couche deps invalidée par ARG   : exit=1 | ERROR: Could not find a version that satisfies the requirement redis==5.0.8
```

Le cache de pip ne contient que les **wheels** téléchargées. Pour résoudre `redis==5.0.8`, pip doit d'abord interroger
l'index (`/simple/redis/`), et sans réseau il ne trouve aucune version. Contrairement à ce que laisse entendre l'énoncé, un cache
mount pip ne suffit pas.

**La solution : [`bonus/Dockerfile.offline`](shop-worker/bonus/Dockerfile.offline), où le cache mount sert de *wheelhouse*.**

```dockerfile
FROM ${PYTHON_IMAGE} AS prefetch                 # seule étape qui a besoin du réseau et du secret
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf,required=true \
    --mount=type=cache,target=/wheels,id=wheels-${TARGETARCH} \
    pip download --dest /wheels -r requirements-dev.txt

FROM ${PYTHON_IMAGE} AS builder                  # aucun index contacté
RUN --mount=type=cache,target=/wheels,id=wheels-${TARGETARCH},readonly \
    pip install --no-cache-dir --no-index --find-links /wheels -r requirements.txt
```

| Étape (builder `shop` vidé, linux/arm64) | Résultat |
|---|---|
| Build `--network=none`, wheelhouse vide | ❌ `Could not find a version … redis==5.0.8` (6,0 s) |
| `--target prefetch`, **en ligne**, avec secret | ✅ 8 wheels enregistrées (3,3 s) |
| `prune -f --filter type=regular` (couches vidées, wheelhouse conservée) | |
| Build complet `--network=none`, **sans `--secret`** | ✅ 6,4 s, 2 installations hors ligne, 2 tests passés |
| Code modifié, `--network=none` | ✅ 0,6 s |
| `requests==2.32.3` ajouté, `--network=none` | ❌ `Could not find a version … requests==2.32.3` (0,7 s) : erreur claire, il faut relancer le prefetch |
| `docker run --network none worker:offline` | `healthy`, uid 10001 |

Avantages de ce découpage :
- le build « de production » n'a **besoin ni du réseau ni des identifiants du registre**. Seule l'étape `prefetch`, lancée
  sur une machine autorisée, a besoin des deux ;
- `readonly` sur le cache mount : le build hors ligne ne peut pas modifier la wheelhouse ;
- une dépendance absente fait échouer le build immédiatement, au lieu d'attendre des timeouts réseau.

**Où est-ce utile en entreprise ?**
- **Zones isolées** (*air-gapped*) : banque, défense, santé, OT industrielle, où les runners de CI n'ont pas d'accès Internet.
- **Supply chain** : seules les wheels préalablement téléchargées, scannées et approuvées entrent dans l'image. C'est le
  principe des « dépôts de confiance » : un build ne peut pas tirer une version publiée entre-temps, ou malveillante (typosquatting,
  dépendance compromise).
- **Builds hermétiques et reproductibles** (au sens SLSA) : le résultat ne dépend que des entrées déclarées.
- **Robustesse** : un incident sur PyPI ou sur le proxy d'entreprise ne bloque pas les livraisons.

Le bonus B3 montre qu'avec **uv**, le cache mount suffit à lui seul (voir plus bas).

---

## Bonus B2 : attestations de provenance et SBOM

Sortie : [`diag/bonus-b2-attestations.txt`](shop-worker/diag/bonus-b2-attestations.txt).

```bash
docker buildx build --platform linux/amd64,linux/arm64 --provenance=mode=max --sbom=true \
  --secret id=pipconf,src=pip.conf --build-arg APP_VERSION=1.0.0 --build-arg GIT_SHA=6c6d9a7 \
  -t localhost:5050/shop-worker:1.0-attest --push .
docker buildx imagetools inspect localhost:5050/shop-worker:1.0-attest --format '{{json .Provenance}}'
docker buildx imagetools inspect localhost:5050/shop-worker:1.0-attest --format '{{json .SBOM}}'
```

Les attestations sont stockées dans le registre sous forme de **manifestes d'attestation** (un par plateforme, `unknown/unknown`),
reliés à l'image dans l'index (voir l'étape 4).

### Provenance (SLSA v1)

| Champ | Contenu observé (linux/arm64) |
|---|---|
| `buildDefinition.externalParameters.request.args` | `build-arg:APP_VERSION=1.0.0`, `build-arg:GIT_SHA=6c6d9a7`, frontend `docker/dockerfile:1.7` |
| `…request.secrets` | `[{"id":"pipconf"}]` : **l'identifiant seulement, jamais la valeur** |
| `buildDefinition.resolvedDependencies` | `python@3.12.15-slim-trixie?digest=sha256:a0f57064…&platform=linux/arm64`, `dockerfile@1.7`, `buildkit-syft-scanner@stable-1` |
| `runDetails.metadata.buildkit_metadata.vcs` | `source = git@github.com:Altex25/docker.git`, `revision = 6c6d9a75…` |
| `…buildkit_metadata.source.infos` | **Le Dockerfile complet** (base64, 2 451 caractères) |
| `internalParameters.buildConfig.llbDefinition` | Le graphe LLB complet (16 opérations : commandes, mounts, variables d'environnement) |

**`mode=min` ou `mode=max` ?** Je l'ai testé avec le Dockerfile de démonstration de l'étape 1, où le secret est passé en `ARG` :

| | Taille | Occurrences de `Tr3sS3cret` |
|---|---|---|
| `--provenance=mode=min` (défaut) | 2,2 ko | **0** (pas de build args) |
| `--provenance=mode=max` | 13,5 ko | **4** : `"build-arg:PIP_INDEX_URL":"https://svc-ci:Tr3sS3cret@…"`, plus dans le LLB et le Dockerfile |

`mode=max` rend le build **auditable et rejouable** : on sait exactement quelle image de base, quel Dockerfile, quels args
et quel commit ont produit le digest. Mais tout ce qui passe en `ARG` est **publié avec l'image**, pour quiconque peut faire un pull. C'est une
raison de plus de ne passer les secrets que par `--secret`, qui n'apparaît que par son identifiant. À noter aussi : l'URL du
dépôt Git (ici `git@github.com:Altex25/docker.git`) est publiée, ce qui peut révéler un nom de dépôt privé.

### SBOM (SPDX 2.3)

| | Valeur |
|---|---|
| Générateur | `syft-v1.51.0` (image `docker/buildkit-syft-scanner`), BuildKit 0.30.0 |
| Paquets (linux/arm64, idem amd64) | **106** : 87 `deb` (Debian trixie), 5 `pypi`, 1 `generic` (l'interpréteur Python), et des paquets sans purl |
| Paquets Python | `redis@5.0.8`, `psycopg2-binary@2.9.9`, `prometheus-client@0.20.0`, `pip@25.0.1` (×2 : le système et le venv) |
| `pytest` / `ruff` | **absents** : le scan porte sur l'image finale, pas sur les étapes `builder`/`test` |

Pour inclure les étapes intermédiaires dans le scan : `ARG BUILDKIT_SBOM_SCAN_STAGE=true` dans l'étape concernée
(utile pour tracer ce qui a *servi* au build, comme les outils de test ou de compilation).

**Lien avec le TP03** : le SBOM est produit et signé (attestation) au moment du build par le même builder, et pas reconstitué
après coup. `trivy sbom` ou `grype` peuvent scanner ce SBOM pour une CVE publiée des mois plus tard, sans repartir de l'image, et
`cosign verify-attestation` vérifie qu'il n'a pas été modifié.

---

## Bonus B3 : `uv` au lieu de `pip`

Fichiers : [`bonus/Dockerfile.uv`](shop-worker/bonus/Dockerfile.uv), [`bonus/b3-pip-vs-uv.sh`](shop-worker/bonus/b3-pip-vs-uv.sh).
Sortie : [`diag/bonus-b3-pip-vs-uv.txt`](shop-worker/diag/bonus-b3-pip-vs-uv.txt).

```dockerfile
# syntax=docker/dockerfile:1.10
COPY --from=ghcr.io/astral-sh/uv:0.13.0@sha256:cdc60931… /uv /usr/local/bin/uv
ENV UV_LINK_MODE=copy UV_COMPILE_BYTECODE=1 UV_PYTHON_DOWNLOADS=never VIRTUAL_ENV=/opt/venv PATH=/opt/venv/bin:$PATH
RUN uv venv /opt/venv
RUN --mount=type=secret,id=uv_index,env=UV_DEFAULT_INDEX,required=true \
    --mount=type=cache,target=/root/.cache/uv,id=uv-${TARGETARCH} \
    uv pip install -r requirements.txt
```

```bash
UV_DEFAULT_INDEX=https://pypi.org/simple docker buildx build -f bonus/Dockerfile.uv --secret id=uv_index,env=UV_DEFAULT_INDEX -t worker:uv .
```

Adaptations par rapport à pip :

| Point | Raison |
|---|---|
| **Secret de type variable d'environnement** (`--secret id=…,env=…` côté CLI, `env=UV_DEFAULT_INDEX` côté `RUN`) | uv **ne lit pas `pip.conf`**. Il prend l'index dans `UV_DEFAULT_INDEX` (ou `uv.toml`). C'est l'alternative citée à l'étape 2. Elle demande la syntaxe `dockerfile:1.10`. |
| Cache mount sur `/root/.cache/uv`, `id=uv-${TARGETARCH}` | Le cache de uv, isolé par architecture comme celui de pip |
| `UV_LINK_MODE=copy` | uv installe par liens physiques depuis son cache, impossibles entre le cache mount et la couche (systèmes de fichiers différents). Sans cette variable, uv affiche un avertissement et bascule sur la copie. |
| `UV_COMPILE_BYTECODE=1` | pip compile les `.pyc` par défaut et uv non : sans cette variable, la comparaison serait faussée et le premier démarrage plus lent |
| Binaire copié depuis l'image officielle `ghcr.io/astral-sh/uv`, épinglée par digest | Pas de `pip install uv`, et uv reste dans l'étape `builder`, absent de l'image finale |

### Mesures (builder `shop`, linux/arm64, médiane de 3 builds)

| Outil | Scénario | Build total | Installation (builder + test) |
|---|---|---|---|
| pip | Froid (cache mount vide) | 12,0 s | 3,50 s |
| **uv** | Froid (cache mount vide) | 9,5 s | **2,10 s** (×1,7) |
| pip | Dépendances invalidées, cache chaud | 3,4 s | 1,40 s |
| **uv** | Dépendances invalidées, cache chaud | 1,2 s | **0,30 s** (×4,7) |

| Image finale | pip (`worker:1.0`) | uv (`worker:uv`) |
|---|---|---|
| Taille compressée | 51,4 Mo | **47,4 Mo** |
| `DISK USAGE` | 237 Mo | 219 Mo |
| `/opt/venv` | 25 Mo | **12 Mo** : `uv venv` n'installe pas pip dans le venv, donc un outil en moins dans l'image |

uv indique lui-même `Resolved 8 packages in 402ms` et `Installed 5 packages in 38ms`. Son avantage tient à la résolution et à
l'installation en parallèle (Rust), et à un cache qui stocke les wheels déjà décompressées. Le gain grandit avec le nombre de
dépendances : 8 paquets ici, souvent plusieurs centaines dans un vrai projet.

### uv hors ligne : le cache mount suffit

```
en ligne (remplit /root/.cache/uv)               : exit=0 | Installed 3 packages in 8ms
--network=none, deps invalidées (ARG BUST)       : exit=0 | Installed 3 packages in 5ms
--network=none + UV_OFFLINE=1, deps invalidées   : exit=0 | Installed 3 packages in 7ms
```

Contrairement à pip (voir B1), uv met aussi en cache les **métadonnées de l'index**. Il peut donc résoudre et installer
sans réseau, directement depuis le cache mount. Sans `UV_OFFLINE=1`, il réutilise probablement des métadonnées encore « fraîches »
au sens HTTP, ce qui peut cesser de fonctionner une fois qu'elles ont expiré. `UV_OFFLINE=1` (ou `--offline`) rend le comportement **explicite et
déterministe** : uv n'essaie même pas le réseau. C'est la réponse la plus simple au B1 si l'équipe adopte uv. Pour un
verrouillage complet, on irait plus loin avec `uv.lock` et `uv sync --frozen`, ce qui suppose de passer à un `pyproject.toml`.
