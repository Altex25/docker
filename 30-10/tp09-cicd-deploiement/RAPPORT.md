# TP09 : CI/CD, de la pull request au déploiement sans interruption

Environnement : Mac Apple Silicon, Colima (VM arm64, 2 CPU, 2 Go), Docker 29.5.2, Compose v5.1.4, BuildKit v0.30.0, `act` 0.2.92.
Sorties brutes : [`diag/`](diag/). Bonus non traités, comme demandé.

| Livrable | Fichier |
|---|---|
| Dépôt `shop` (apps, compose, porte de release) | [`shop/`](shop/) |
| Workflow CI (GitHub Actions) | [`shop/.github/workflows/ci.yml`](shop/.github/workflows/ci.yml) |
| Rejeu local du pipeline | [`shop/ci-local.sh`](shop/ci-local.sh), outils en conteneur [`shop/ci/oci.sh`](shop/ci/oci.sh) |
| Vérification de signature côté déploiement | [`shop/deploy/verify-signature.sh`](shop/deploy/verify-signature.sh) |
| Rolling update | [`shop/deploy/rolling-update.sh`](shop/deploy/rolling-update.sh) |
| Mesure d'interruption | [`shop/deploy/measure-downtime.sh`](shop/deploy/measure-downtime.sh), [`shop/deploy/mesurer.sh`](shop/deploy/mesurer.sh) (mesure pendant une commande), [`shop/deploy/naive-update.sh`](shop/deploy/naive-update.sh) |
| Serveurs distants simulés (preprod, prod) | [`serveur/`](serveur/) : `Dockerfile`, `sshd_config`, `setup.sh` |
| Campagne de mesures | [`mesures.sh`](mesures.sh), [`experiences/release-cassee.yml`](experiences/release-cassee.yml) |
| Captures | pipeline vert : [`diag/pipeline-pr-act.txt`](diag/pipeline-pr-act.txt), [`diag/pipeline-main.txt`](diag/pipeline-main.txt), [`diag/pipeline-tag-prod.txt`](diag/pipeline-tag-prod.txt) ; signature vérifiée : [`diag/signature.txt`](diag/signature.txt) ; naïf vs rolling et rollback : [`diag/mesures.txt`](diag/mesures.txt), [`diag/mesures-historique.txt`](diag/mesures-historique.txt) ; scan bloquant : [`diag/trivy-bloquant.txt`](diag/trivy-bloquant.txt) |

```bash
./serveur/setup.sh preprod 2222 8090 && ./serveur/setup.sh prod 2223 8091
cd shop && ./ci-local.sh pr && ./ci-local.sh main && ./ci-local.sh tag v1.5.0
cd .. && V_OLD=sha-9cab478 V_NEW=sha-8cab045 ./mesures.sh
```

## Adaptations au poste

- **Pas de commit, donc pas de push sur GitHub** (consigne permanente). Le workflow est écrit pour GitHub Actions et validé par
  `actionlint`. La partie PR est exécutée avec `act`, et les parties `main` et `tag` sont rejouées par `ci-local.sh` contre le
  registre du TP03 (`registry.local:5000`).
- **Identifiant de build sans commit** : le SHA git du dépôt ne change pas entre deux versions. `ci-local.sh` dérive donc
  l'identifiant d'un hash du contenu (`apps/`, compose, `config/`, `db/`) et l'annonce (`!! arbre non commité`). Avec un arbre
  propre, il prend `git rev-parse HEAD`, comme `docker/metadata-action`.
- **Signature keyless** : elle exige un jeton OIDC que ni `act` ni le poste ne fournissent (sauf connexion interactive, comme au
  B2 du TP03). Le workflow signe en keyless ; `ci-local.sh` signe par défaut avec une clé dédiée (`cles-ci/cosign.key`, gitignorée)
  et accepte `COSIGN_MODE=keyless` (flux « device »). `verify-signature.sh` gère les deux : clé publique, ou identité du workflow
  + émetteur OIDC.
- **Serveurs distants** : deux conteneurs `docker:28.5-dind` avec `sshd` et un utilisateur `deploy`, joints par
  `ssh://deploy@localhost:2222` (preprod) et `:2223` (prod). Chacun a son propre daemon, ses volumes, son `/srv/shop` et ses
  secrets. La clé SSH et le `known_hosts` du TP restent dans `serveur/` (gitignorés) : le wrapper `serveur/bin/ssh` les passe à
  `ssh` par `-F`, sans toucher `~/.ssh`.
- **Mémoire de la VM (2 Go)** : j'ai arrêté sans les supprimer les stacks `observability` (TP07), `incident` (TP06) et `shop` (dev
  du TP04), puis les builders buildx inactifs (voir État laissé). Sous `act`, les deux jobs de la matrice construisaient en
  parallèle et `syft-scanner` (SBOM) tombait en `cannot allocate memory`. `--concurrent-jobs 1` règle le problème, mais seulement
  avec plus d'1 Go libre : pour le dernier run, j'ai arrêté les deux serveurs simulés le temps du `act`, puis je les ai relancés.

---

## 1. Le dépôt `shop`

Assemblé selon le starter : applications et stack du TP04, `release-gate.sh` du TP03, plus `ci-local.sh`, `ci/` et `deploy/`.
Les secrets (`.env`, `secrets/`, `apps/shop-worker/pip.conf`) sont gitignorés ; le dépôt fournit `.env.example` et
`pip.conf.example`.

Écarts avec le TP04, tous issus du pipeline ou des mesures :

| Fichier | Changement | Raison |
|---|---|---|
| `apps/shopapi/Dockerfile` | `node:20.20.2` → `node:22.23.4-alpine3.23` (digest épinglé) ; `npm`, `npx`, `corepack` et `yarn` supprimés de l'étape `runtime` | Le **premier** pipeline `main` a été **bloqué** par trivy : Node 20 est en fin de vie depuis avril 2026, son image n'est plus reconstruite (openssl) et embarque un npm avec des CVE HIGH/CRITICAL (`tar`, `minimatch`, `sigstore`…). Le runtime n'a pas besoin de npm. |
| `apps/shopapi/src/server.js` | Drain au SIGTERM : `/ready` répond 503 et `Connection: close` pendant `SHUTDOWN_DRAIN_MS` (5 s), puis `server.close()` | Le SIGTERM du TP01 fermait le port aussitôt : 10 échecs mesurés en rolling update (section 4). Changement suivant : `instance` (hostname) dans `/`, pour voir quel réplica répond. |
| `compose.yml` (api) | `stop_grace_period: 15s` ; healthcheck actif Traefik sur `/ready` toutes les **1 s** (au lieu de 5 s) | Retrait rapide d'un réplica en drain |
| `compose.prod.yml` | `image: ${API_IMAGE:-$REGISTRY/shopapi:$VERSION}`, `WORKER_VERSION` par défaut égal à `VERSION` | Le déploiement injecte la référence **`tag@digest` dont la signature vient d'être vérifiée** |
| `release-gate.sh` | Contrôles seulement (la publication passe par buildx et cosign) ; le label `version` accepte `sha-<commit>` et `pr-<n>` en plus du semver | Un build de `main` est versionné `sha-xxxxxxx` (politique de tags du TP03) |

---

## 2. Le pipeline

### Ce que fait chaque événement

| Étape | PR | `main` | tag `v*` |
|---|:-:|:-:|:-:|
| hadolint (v2.15.1 : la v2.12 de `hadolint-action` ne connaît pas `--start-interval`) | ✓ | ✓ | ✓ |
| `docker compose config -q` (base, dev, prod) | ✓ | ✓ | ✓ |
| Build de l'étape `test` (`node --test`, `ruff`, `pytest`) | ✓ | ✓ | ✓ |
| Build multi-arch `linux/amd64,linux/arm64`, provenance `mode=max` + SBOM | ✓ sans push | ✓ push `sha-<sha7>` | ✓ push `X.Y.Z`, `X.Y`, `X` |
| Trivy HIGH/CRITICAL corrigeables, **bloquant**, par plateforme | | ✓ | ✓ |
| Porte de release (labels OCI, non-root, HEALTHCHECK, ENV, secrets) | | ✓ | ✓ |
| Signature cosign **keyless** du digest | | ✓ | ✓ |
| Déploiement (vérification de signature puis rolling update) | | preprod, automatique | production, **approbation manuelle** |

### Points imposés

| Exigence | Mise en œuvre dans `ci.yml` |
|---|---|
| Tags et labels OCI | `docker/metadata-action` : `type=ref,event=pr`, `type=sha,prefix=sha-` (sur `main` seulement), `type=semver` `{{version}}`, `{{major}}.{{minor}}`, `{{major}}` (sauf `v0.*`), `latest=false`. Les labels et annotations OCI sont passés au build ; `APP_VERSION`, `GIT_SHA` et `SOURCE_URL` aussi, en build-args. |
| Cache | `type=gha`, un `scope` par application (`mode=max`) ; `ci-local.sh` utilise un cache registre (`registry.local:5000/cache/<app>`) |
| Multi-arch | `setup-qemu-action` + `setup-buildx-action`, `platforms: linux/amd64,linux/arm64` ; trivy scanne les deux plateformes |
| Matrice | `app: [shopapi, shop-worker]` pour le build et le scan ; les digests passent d'un job à l'autre en artefacts (`digest-<app>`) |
| Secret de build | `secrets.PIP_CONF` → `secret-files: pipconf=…` (monté par `RUN --mount=type=secret,id=pipconf`), `pip.conf.example` sinon |
| `provenance` + `sbom` | `provenance: mode=max`, `sbom: true` : deux attestations in-toto (`https://slsa.dev/provenance/v1`, `https://spdx.dev/Document`) par plateforme dans l'index ([`diag/signature.txt`](diag/signature.txt)) |
| Keyless | Job `sign` avec `id-token: write` : `cosign sign --yes <image>@<digest>` (certificat Fulcio émis pour l'identité du workflow, entrée Rekor) |
| Vérification au déploiement | `cosign verify --certificate-identity-regexp '^https://github.com/<owner>/<repo>/\.github/workflows/ci\.yml@refs/heads/main$' --certificate-oidc-issuer https://token.actions.githubusercontent.com` ; en prod, l'identité attendue est `@refs/tags/vX.Y.Z` |
| Approbation manuelle | `environment: production`, avec « Required reviewers » à régler dans *Settings → Environments*. Le job attend un relecteur avant même de démarrer : ses secrets (`DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS`) ne sont pas exposés avant. |

À configurer dans le dépôt GitHub (rien de cela n'est dans git) :

| Où | Nom | Contenu |
|---|---|---|
| Secret du dépôt | `PIP_CONF` | `pip.conf` réel (index privé et ses identifiants) ; à défaut, `pip.conf.example` |
| Environnements `preprod` et `production` | secrets `DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS` | Clé privée de `deploy` et empreinte du serveur, **une par environnement** |
| Idem | variables `DEPLOY_SSH_TARGET`, `APP_URL` | `deploy@preprod.shop.example`, URL publique pour le smoke test |
| Environnement `production` | *Required reviewers*, *Deployment branches and tags* : `v*` | L'approbation manuelle ; la prod n'accepte que les tags |
| Paquets GHCR | `shopapi`, `shop-worker` | Lien vers le dépôt, pour que `GITHUB_TOKEN` puisse pousser |

Durcissement du workflow :
- `permissions: contents: read` par défaut, élargies job par job (`packages: write` pour le build et la signature, `id-token: write` pour
  la signature seulement) ;
- toutes les actions sont **épinglées par SHA de commit**, versions correspondantes : checkout v4.4.0, setup-qemu v3.7.0,
  setup-buildx v3.12.0, login v3.7.0, metadata v5.10.0, build-push v6.19.2, upload-artifact v4.6.2, download-artifact v4.3.0,
  cosign-installer v3.10.1 (cosign v2.6.1), setup-crane v0.4 ;
- trivy et hadolint tournent depuis leurs images, épinglées par version ou par digest, plutôt que par une action tierce ;
- les jobs de déploiement sont sérialisés (`concurrency`, sans annulation) : deux rolling updates ne se chevauchent jamais.

### Exécutions

| Exécution | Résultat |
|---|---|
| `act pull_request` ([`diag/pipeline-pr-act.txt`](diag/pipeline-pr-act.txt)) | **Vert** en 44 s : `lint` puis la matrice `build` (2 jobs). Le cache `gha` est importé puis exporté (serveur de cache intégré à `act`), les tests passent (`# pass 1`, `ruff` + `pytest`) et l'image `ghcr.io/altex25/shopapi:pr-42` est construite pour les 2 architectures, sans push |
| `ci-local.sh main` n° 1 ([`diag/trivy-bloquant.txt`](diag/trivy-bloquant.txt)) | **Bloqué au scan** : `ÉCHEC shopapi (linux/amd64) : CVE HIGH/CRITICAL corrigeables, pipeline arrêté` (openssl d'Alpine et npm de Node 20), avant toute signature et tout déploiement |
| `ci-local.sh main` après correction ([`diag/pipeline-main.txt`](diag/pipeline-main.txt)) | Vert en 70 s : hadolint, compose, tests, build multi-arch + push, trivy (×2 plateformes), porte ACCEPTÉ, signature, vérification, premier déploiement preprod |
| `ci-local.sh tag v1.5.0`, puis `deploy-prod v1.5.0` ([`diag/pipeline-tag-prod.txt`](diag/pipeline-tag-prod.txt)) | Tags `1.5.0`, `1.5`, `1` ; relancer `tag v1.5.0` est **refusé** (tag semver déjà publié, immuable) ; l'approbation à « non » annule le déploiement, à « oui » elle mène à la vérification de signature puis au premier déploiement prod (`/ready` ok) |

Deux défauts trouvés en exécutant le flux de tag, et corrigés :
- Le build de tag reposait aussi le tag `sha-8cab045`, qui pointait alors sur un autre digest que le build `main` : c'est une violation de
  la règle « un commit = un build » du TP03. Désormais, le tag `sha-` n'est produit que sur `main`
  (`enable=${{ github.ref == 'refs/heads/main' }}`). Le premier essai a laissé `sha-8cab045` sur le digest de `1.5.0` (même code).
- `echo oui | ci-local.sh tag …` : le `docker run -i` de trivy consommait l'entrée standard avant la question d'approbation.
  L'approbation lit maintenant `/dev/tty`, ou bien `APPROVE=oui|non`.

### Signature vérifiée côté déploiement

[`diag/signature.txt`](diag/signature.txt) : `verify-signature.sh` résout `tag → digest` (crane), vérifie la signature de **ce digest**
et renvoie `API_IMAGE=…:tag@sha256:…`. Compose déploie ensuite cette référence exacte : une réécriture du tag entre la
vérification et le pull est sans effet.

| Image | Résultat |
|---|---|
| `shopapi:1.5.0`, `shopapi:sha-8cab045` (signées par la CI) | OK, digest épinglé |
| `shopapi:1.4.3` (TP03, signée par une autre clé) | **ÉCHEC** `invalid signature when validating ASN.1 encoded signature` |
| `shopapi:sha-e0916e6` (le build bloqué par trivy : poussé avant le scan, jamais signé) | **ÉCHEC** `no signatures found` |
| `shopapi:sha-bad0000` (poussée hors pipeline avec `crane copy`), déploiement prod tenté | **ÉCHEC** avant tout pull, la prod reste en `1.5.0` |
| `shopapi:pr-local` (build de PR, jamais poussé) | **ÉCHEC** introuvable |

Le pipeline pousse **avant** de scanner, parce qu'un build multi-arch ne peut pas être chargé dans le daemon local pour être
scanné. Un digest vulnérable peut donc se trouver dans le registre, mais il n'est jamais signé, et sans signature il ne se déploie
pas : c'est la signature qui sert de porte. Les tags de test `sha-bad0000` ont ensuite été supprimés (`DELETE` par tag, 202 ; le
digest de `1.4.3` reste intact).

---

## 3. Déploiement distant par `docker context`

```bash
./serveur/setup.sh preprod 2222 8090
docker context create preprod --docker "host=ssh://deploy@localhost:2222"
docker --context preprod ps
DOCKER_CONTEXT=preprod docker compose --project-directory /srv/shop -f compose.yml -f compose.prod.yml up -d --wait
```

`docker --context preprod info` → `preprod 28.5.2 Alpine Linux v3.22 (containerized) aarch64`. Le client Docker ouvre
`ssh deploy@localhost -p 2222 docker system dial-stdio` et dialogue avec le daemon distant par ce tunnel. Le serveur n'expose
**aucun port Docker** : dind ouvrait `tcp://0.0.0.0:2375` sans TLS par défaut, je l'ai fermé (`--host=unix:///var/run/docker.sock`).

### Prérequis côté serveur

| Prérequis | Sur les serveurs du TP |
|---|---|
| Docker Engine, et la CLI `docker` dans le `PATH` des sessions SSH (le client lance `docker system dial-stdio` à distance) | `docker:28.5-dind` ; lien `/usr/bin/docker`, car sshd n'inclut pas `/usr/local/bin` |
| Compose sur le serveur | **Inutile** : compose tourne côté client (CI) et pilote l'API distante |
| Utilisateur `deploy` dans le groupe `docker` | `uid=1000(deploy) groups=…,2375(docker)` |
| Clé SSH, sans mot de passe | `sshd_config` : `PasswordAuthentication no`, `PermitRootLogin no`, `AllowUsers deploy`, `AllowTcpForwarding no` ; clé ed25519 dédiée `deploy@ci-shop` |
| Empreinte du serveur connue du client | `known_hosts` rempli par `ssh-keyscan` à l'installation, puis `StrictHostKeyChecking yes` ; en CI, secret `DEPLOY_KNOWN_HOSTS` |
| `/srv/shop/.env` et `/srv/shop/secrets/` **sur le serveur, jamais dans git** | Créés une fois à l'installation, avec un mot de passe **différent** par environnement (empreintes `fbb9f4…` en preprod, `35d26c…` en prod) ; `/srv/shop` en 0750, `.env` en 0600 |
| Accès au registre (CA, nom) | CA du TP03 dans `/etc/docker/certs.d/registry.local:5000/`, `registry.local` → passerelle du bridge de la VM |

Appartenir au groupe `docker`, c'est être **root sur le serveur** (`docker run -v /:/host`). La clé de déploiement est donc une clé
root, à traiter comme telle : un serveur dédié, une clé par environnement, rangée en secret d'environnement GitHub (exposée
seulement après approbation pour la prod), avec une restriction `from=` sur l'IP des runners quand c'est possible. Une restriction
`command=` est impossible, car `dial-stdio` donne l'API entière. Docker rootless réduirait ce risque.

### Comment les secrets arrivent en prod

Avec un contexte distant, compose **lit les fichiers sur le client** mais le **daemon monte les chemins sur le serveur** :
- l'interpolation (`${VERSION}`, `${REGISTRY}`) se fait sur le runner. Le `.env` du serveur n'est donc pas lu par compose ;
  `rolling-update.sh` le récupère par SSH (`cat /srv/shop/.env`) et le passe en `--env-file`. Il ne contient que des valeurs non
  secrètes (`REGISTRY=…`) ;
- `secrets: file:` et `configs: file:` deviennent des **bind mounts**. Leur chemin est résolu contre `--project-directory /srv/shop`,
  donc `/srv/shop/secrets/db_password.txt` est lu **sur le serveur**. Le mot de passe ne transite jamais par la CI ni par git.
  Compose affiche `secret file shop_db_password does not exist` parce qu'il cherche le fichier sur le client ; c'est un
  avertissement (le script le filtre), et `/ready` → `{"db":"ok"}` prouve que le montage côté serveur fonctionne ;
- les fichiers non secrets montés (`config/`, `db/init.sql`, `db/migrations/`) viennent de git : `rolling-update.sh` les copie dans
  `/srv/shop` (`tar | ssh`) avant chaque déploiement ;
- le fichier secret est en 0644 dans un répertoire 0750 : les uid des conteneurs (70, 1000, 10001) peuvent le lire, mais aucun autre
  compte du serveur ne traverse `/srv/shop`. C'est la limite des secrets compose hors Swarm : un simple montage, sans chiffrement
  ni rotation.

Côté CI, seuls des secrets **d'accès** existent : `GITHUB_TOKEN` (push GHCR), `PIP_CONF` (build), `DEPLOY_SSH_KEY` et
`DEPLOY_KNOWN_HOSTS` par environnement. Aucune clé de signature : le keyless la remplace par l'identité OIDC du workflow.

---

## 4. Zéro interruption

### Mesure

`measure-downtime.sh` lance, **sur l'hôte cible** (`docker run --network host` via le contexte), un client Node.js qui envoie
100 requêtes/s sur `/health` à travers Traefik (`Host: api.localhost`, keep-alive, timeout 2 s). Il compte les échecs seconde par
seconde et par cause, et donne la latence des succès. `mesurer.sh` l'exécute pendant une commande de déploiement.
`mesures.sh` rejoue toute la campagne : [`diag/mesures.txt`](diag/mesures.txt).

| Scénario (campagne du 30/10, 15:43) | Durée de la commande | Échecs / requêtes | Détail |
|---|---|---|---|
| A. Témoin, aucun déploiement | | **0** / 3 000 | p99 6,7 ms |
| B. **Naïf** : `docker compose up -d --force-recreate api` | 6 s | **689** / 4 000 (17 %) sur 8 s | 489 × 503 (les deux réplicas en drain), puis 200 × 404 (plus aucun conteneur) |
| C. **Rolling update** `sha-9cab478` → `sha-8cab045` | 25 s | **0** / 5 000 | p99 7,5 ms, max 40 ms |
| D. **Rollback** `sha-8cab045` → `sha-9cab478` | 27 s | **0** / 5 000 | p99 6,8 ms, max 42 ms |
| E. Rolling update **sans arrêt propre** (`STOP_TIMEOUT=0`, SIGKILL immédiat) | 13 s | **8** / 5 000 | 6 timeouts à 2 s, 2 × 502, max 1 079 ms |
| F1. Release **cassée** (écoute sur 3999, jamais healthy), en rolling update | 55 s, code 1 | **0** / 7 000 | Le nouveau réplica est retiré au bout de 45 s, les anciens n'ont jamais été arrêtés |
| F2. La même release cassée, en déploiement **naïf** | 7 s, code 0 | **3 352** / 4 000 sur 34 s | 503 puis 404 jusqu'à la fin de la mesure : le service est **mort**, et la commande a réussi |
| F3. Réparation de F2 par rolling update | 27 s | 1 408 / 6 000 | Coupure qui continue celle de F2 : elle cesse dès que le premier réplica sain est healthy (9 s) |

Mises au point antérieures ([`diag/mesures-historique.txt`](diag/mesures-historique.txt)) : naïf avec le SIGTERM du TP01, **216**
échecs (HTTP 404) ; rolling update sans drain, **10** (8 timeouts, 2 × 502) ; changement de labels Traefik pendant le rolling,
**735** (section suivante) ; pipeline `main` complet sous charge (build, scan, signature, déploiement), **0**.

Le naïf est **pire avec le drain** (689 contre 216) : compose arrête les deux réplicas en même temps, chacun passe 5 s en drain
(`/ready` 503, Traefik les retire tous les deux), puis compose crée les nouveaux. Le drain n'apporte quelque chose que si un
autre réplica sain prend le relais, et c'est le rôle du rolling update.

### `rolling-update.sh`

1. **Préparation** : `.env` et présence du secret lus sur le serveur, `config/` et `db/` synchronisés.
2. **Signatures** : `verify-signature.sh`. En cas d'échec, arrêt avant tout changement sur le serveur.
3. `compose pull` (le temps de téléchargement ne tombe pas pendant la bascule), puis `up -d --wait` sur db, redis, traefik et le
   worker (recréés seulement si leur configuration change).
4. **Pour chaque ancien réplica, un à la fois** :
   1. `compose up -d --no-deps --no-recreate --scale api=N+1` : un nouveau conteneur démarre avec la nouvelle image, les anciens
      ne sont pas touchés ;
   2. attente de l'état `healthy` (`HEALTH_TIMEOUT`). En cas d'échec, le nouveau est supprimé et le script s'arrête : les anciens
      servent toujours ;
   3. `SETTLE` (3 s), le temps que Traefik traite l'événement `health_status` et ajoute le réplica ;
   4. `docker stop -t 15` de l'ancien (SIGTERM : drain de 5 s, puis fermeture), puis `docker rm`.
5. Retour au nombre de réplicas demandé, puis smoke test `/ready` via Traefik depuis le serveur.

`DOCKER_CONTEXT`, `REPLICAS`, `STOP_TIMEOUT`, `HEALTH_TIMEOUT`, `SETTLE`, `COMPOSE_FILES` et `VERIFY` sont réglables : la campagne
de mesures s'en sert pour retirer une brique à la fois.

### Rôle de chaque brique, et ce qui se passe sans elle

| Brique | Rôle | Sans elle |
|---|---|---|
| `HEALTHCHECK` de l'image (`wget /health`) | Docker sait quand le processus répond vraiment. C'est le seul signal « prêt » du conteneur, et il voyage avec l'image (porte de release : `HEALTHCHECK` obligatoire). | Docker déclare le conteneur `running` dès le `exec`, sans plus d'information. Traefik route alors dès la création, avant le `listen()` (502), et le script n'a rien à attendre. |
| `start_period` (30 s) + `start_interval` (1 s) | Pendant le démarrage, un échec ne compte pas ; une sonde par seconde, donc `healthy` en 1 à 2 s (colonne « healthy » des logs). | Avec un `start_period` trop court, une appli lente passe `unhealthy` et redémarre en boucle. Sans `start_interval`, il faut attendre l'`interval` (10 s) pour être `healthy`, et chaque bascule ralentit d'autant. |
| `--wait` / attente `healthy` | Le déploiement ne passe à l'étape suivante (arrêter un ancien) que quand le nouveau est sain. C'est la porte de sécurité. | F2 : une release cassée remplace la version saine et la commande réussit (code 0), avec 34 s de coupure totale. Avec l'attente (F1) : 0 échec, déploiement refusé, code 1. |
| SIGTERM géré (drain 5 s, puis `server.close()`) | Le réplica finit ses requêtes et se fait retirer par Traefik **avant** de fermer le port. | Sans drain (TP01) : 10 échecs. Avec SIGKILL (E) : 8 échecs. Les deux fois, Traefik envoie encore des requêtes à une IP disparue (timeouts). |
| `stop_grace_period: 15s` / `stop -t 15` | Laisse au drain (5 s) et à la fermeture le temps de finir avant le SIGKILL. | Docker tue au bout de 10 s par défaut, ce qui suffit ici mais pas pour une requête longue. À 0 s, c'est le scénario E. |
| Réplicas ≥ 2 et un réplica à la fois (surge de +1) | Il y a toujours au moins `REPLICAS` réplicas sains derrière Traefik ; on n'arrête un ancien qu'une fois son remplaçant ajouté. | Recréer tout d'un coup (B) fait 689 échecs. Avec 1 seul réplica, le surge (+1 avant −1) suffit encore, mais une panne du réplica pendant le drain n'aurait plus de secours. |
| Proxy (Traefik) : filtre `healthy`, healthcheck actif `/ready` toutes les 1 s | Point d'entrée stable. Il n'ajoute un conteneur qu'une fois `healthy` (événement `health_status`) et retire en 1 s un réplica dont `/ready` répond 503. | Sans proxy, les clients visent un conteneur précis : chaque recréation coupe. Avec un healthcheck Traefik à 5 s, le drain devrait durer plus de 5 s. Avec des labels qui changent entre versions : 735 × 404. |

### Deux pièges mesurés

**Le SIGTERM du TP01 ne suffit pas derrière Traefik** (10 échecs). Avec `server.close()` immédiat, le processus sort en quelques
millisecondes. Traefik ne retire un serveur qu'à l'événement Docker `die`, avec un délai de recalcul de l'ordre de la seconde.
Entre les deux, il envoie des requêtes à une IP qui n'existe plus : pas de RST, donc un timeout. Le drain inverse l'ordre :
le réplica reste joignable mais `/ready` répond 503. Le healthcheck actif Traefik (1 s) le retire, et il ne ferme qu'ensuite.
C'est l'équivalent du `preStop: sleep` de Kubernetes.

**Changer un label Traefik pendant un rolling update coupe tout le service** (735 HTTP 404 en 7 s). Lors du passage v1 → v2, le
nouveau réplica annonçait `healthcheck.interval=1s` et les anciens `5s`. Traefik a vu deux définitions contradictoires du service
`api` et l'a **retiré entièrement** tant que les deux versions coexistaient. Un rolling update ne protège que si la définition
du load balancer est la même avant et après. Pour changer cette configuration, il faut un service Traefik versionné
(`api-v2`, avec bascule du routeur), ou le provider fichier.

---

## 5. Rollback

```bash
VERSION=sha-9cab478 ./deploy/rolling-update.sh
```

Mesure D : **27 s** de bout en bout, **0 échec**. Le temps se répartit ainsi : 7 s de préparation (lecture du `.env` et des
fichiers, vérification des 2 signatures, `pull` des images déjà présentes, worker recréé), puis environ 10 s par réplica (1 à
2 s jusqu'à `healthy`, 3 s de `SETTLE`, 5 s de drain).
Le rollback peut aller plus vite (`SETTLE=1`, `SHUTDOWN_DRAIN_MS=2000`, ou plus de surge), au prix d'une marge plus faible
sur le délai de réaction de Traefik.

Ce qui rend le rollback possible :
- **Des tags immuables** : `sha-9cab478` désigne toujours le même digest, et c'est ce digest dont la signature est vérifiée. Avec un tag mobile
  (`latest`), « revenir en arrière » n'a pas de sens (TP03).
- **Des images conservées** : sur le registre (la rétention du TP03 garde les N derniers `sha-*` et toutes les releases), et sur
  l'hôte (aucun `image prune` agressif). Le `pull` du rollback a pris 2 s, sans couche à télécharger.
- **Une base compatible avec les deux versions** : le rollback ne touche qu'aux conteneurs, jamais au volume `pgdata`. Il faut donc que
  le schéma en place convienne aussi à l'ancienne version.
- **Le même script** dans les deux sens : le rollback est un déploiement comme un autre, avec signatures, drain et mesure.

**Migration de schéma non rétro-compatible** (renommer ou supprimer une colonne, ajouter un `NOT NULL` sans défaut) : pendant un
rolling update, les deux versions tournent en même temps sur la même base, et l'ancienne casse dès que la migration passe. Un rollback
du code sans rollback du schéma ne fonctionne pas non plus. La méthode est **expand / contract**, en plusieurs releases :
1. *expand* : ajouter sans casser (nouvelle colonne nullable ou avec défaut, nouvelle table, vue de compatibilité). Exemple :
   `002-add-sku.sql` du TP04 ;
2. déployer un code qui écrit les deux formes et lit la nouvelle, puis migrer les données par lots ;
3. *contract* : supprimer l'ancienne colonne une ou deux releases plus tard, quand plus aucune version déployable ne s'en sert.

Le rollback reste alors possible à chaque étape. Une migration vraiment irréversible demande une sauvegarde vérifiée juste
avant (restauration testée au TP05) et une fenêtre de maintenance assumée.

---

## État laissé

- **Serveurs simulés** : `tp09-preprod` (ssh 2222, http 8090) en `sha-9cab478`, et `tp09-prod` (ssh 2223, http 8091) en `1.5.0`.
  Contextes Docker `preprod` et `prod` ; volumes `tp09-{preprod,prod}-{docker,srv}`.
- **Arrêtées, sans suppression** : stacks `observability` (TP07), `incident` (TP06) et `shop` (dev du TP04) ; builders buildx `tp09` et
  `shop`. Pour relancer une stack : `docker compose -p <projet> start`.
- **Registre** : dépôts `shopapi` et `shop-worker` (tags `sha-*`, `1.5.0`, `1.5`, `1`, signatures), caches `cache/shopapi` et
  `cache/shop-worker`.
- **`act`** installé avec Homebrew ; image `catthehacker/ubuntu:act-24.04` (2,3 Go).
- Rien n'est commité.
