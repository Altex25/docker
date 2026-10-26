# TP03 : registre privé et chaîne d'approvisionnement

Environnement : Mac Apple Silicon, Colima (VM Linux), Docker Engine 29.5.2, containerd image store.
Sorties brutes : [`diag/`](diag/).

| Livrable | Fichier |
|---|---|
| Registre (TLS, htpasswd, volume, healthcheck, UI, mirror) | [`registry/compose.yml`](registry/compose.yml), [`config.yml`](registry/config.yml), [`mirror.yml`](registry/mirror.yml), [`init.sh`](registry/init.sh) (CA, certificat, htpasswd, secret HTTP), [`validate.sh`](registry/validate.sh) |
| API du registre | [`api/demo-api.sh`](api/demo-api.sh), [`retention.sh`](retention.sh), jeu de test [`api/seed-demo.sh`](api/seed-demo.sh) |
| Politique de tags | [`TAGGING.md`](TAGGING.md) |
| Porte de release | [`release-gate.sh`](release-gate.sh), clés dans `supply/` (`cosign.key` est gitignorée) |
| Bonus | [`scan/compose.yml`](scan/compose.yml) (B1), [`verified-run.sh`](verified-run.sh) (B3) |
| Outillage | [`tools/oci.sh`](tools/oci.sh) (crane, skopeo, syft, trivy, cosign en conteneur), [`tools/run.sh`](tools/run.sh) (curl + jq) |

```bash
cd registry && ./init.sh && docker compose up -d && ./validate.sh
```

## Adaptations au poste

- **Le Mac ne joint pas `registry.local:5000`** : le port 5000 est pris par AirPlay (`ControlCenter`). Le daemon Docker,
  lui, tourne dans la VM Colima, où le registre est joignable. Tous les clients (curl, crane, cosign…) tournent donc en
  conteneur `--network host` dans la VM, via `tools/run.sh` et `tools/oci.sh`. Sur un poste Linux ou en CI, ce sont les mêmes
  commandes, lancées en natif.
- **Configuration Colima** (avec ton accord) : `~/.colima/default/colima.yaml` déclare
  `docker.registry-mirrors: [http://localhost:5001]` et `network.dnsHosts.registry.local: 127.0.0.1`, puis Colima a été
  redémarré. Le CA est installé dans `/etc/docker/certs.d/registry.local:5000/ca.crt` de la VM.
  `dnsHosts` joue le rôle de l'entrée `/etc/hosts` côté daemon. Sauvegarde : `~/.colima/default/colima.yaml.bak-tp03`.
- **`docker login registry.local:5000 -u ci`** : l'identifiant de test est stocké dans le trousseau macOS. Pour le retirer :
  `docker logout registry.local:5000`.

---

## 1. Registre sécurisé

| Exigence | Mise en œuvre |
|---|---|
| TLS | CA interne RSA 4096 + certificat serveur (SAN `registry.local`, `localhost`, `127.0.0.1`, `serverAuth`), générés par `init.sh` |
| Authentification | `htpasswd` bcrypt (coût 10) : `ci` / `ci-push-2024`, `dev` / `dev-pull-2024` |
| Persistance, suppression | Volume nommé `registry-data`, `storage.delete.enabled: true` |
| Exploitation | `restart: unless-stopped`, `config.yml` monté, healthcheck sur `/debug/health` (port de debug 5002, non publié), `http.secret` dans `.env` |
| UI | `joxit/docker-registry-ui:2.5.7` sur http://localhost:8080, en proxy vers `https://registry:5000` (l'authentification reste exigée) |
| Mirror | 2e instance en `proxy.remoteurl: https://registry-1.docker.io` sur le port 5001, déclarée dans `registry-mirrors` |

**Version : `registry:3.0.0` au lieu de `registry:2`.** `registry:2.8.3` a un bug grave lié au garbage collection (étape 2),
corrigé en v3. La v3 demande deux réglages : `http.secret`, et `OTEL_TRACES_EXPORTER=none`, car l'export de traces
OpenTelemetry est activé par défaut et vise `localhost:4318`.

Validation ([`diag/etape1-registre.txt`](diag/etape1-registre.txt)) :

```
curl -k https://registry.local:5000/v2/                       -> HTTP/2 401, www-authenticate: Basic realm="Shop SAS Registry"
curl --cacert ca.crt https://registry.local:5000/v2/          -> HTTP 401, vérification TLS = 0 (OK, sans -k)
curl -u dev:dev-pull-2024 .../v2/_catalog                     -> {"repositories":[]}
curl -u dev:mauvais .../v2/_catalog                           -> HTTP 401
docker login registry.local:5000 -u ci                         -> Login Succeeded
docker push registry.local:5000/shopapi:1.4.2                 -> digest: sha256:e9cc6195…
```

| Mirror (`busybox:1.36.0`, absente du cache) | Durée du pull | Stockage du mirror |
|---|---|---|
| 1er pull : le mirror va chercher l'image sur Docker Hub | 1,57 s | 2,2 Mo → 4,2 Mo |
| 2e pull (après `docker image rm`) : servi depuis le cache | **0,44 s** | 4,2 Mo (inchangé) |

Dans les deux cas, le daemon passe par le mirror (`HEAD manifests/1.36.0`, puis le `GET` des blobs). Au premier pull, le mirror
va chercher le contenu sur Docker Hub ; au second, il le sert depuis son disque. Le `HEAD` du tag est toujours revalidé auprès de
Docker Hub (un tag peut changer), mais les couches non. Avec `registry:2.8`, les logs détaillaient les durées : environ 330 ms par
blob au premier pull, 2 à 10 ms au second.

**UI vérifiée dans un navigateur** ([`diag/ui-depots.jpg`](diag/ui-depots.jpg), [`diag/ui-tags-shopapi.jpg`](diag/ui-tags-shopapi.jpg)) :
- **sans identifiants**, `GET /v2/_catalog?n=1000` renvoie 401 et la page affiche « 0 images in 0 repositories » ;
- **authentifiée avec `dev`**, elle liste `demo`, `prod/shopapi` et `shopapi`. Le dépôt `shopapi` montre 8 tags : `1`, `1.4`, `1.4.2`, `1.4.3`
  (arm64, avec taille et date) et les 4 artefacts cosign `sha256-….sig` / `.att`. Ces derniers s'affichent « 2055 years ago » :
  cosign ne renseigne pas de date de création ;
- avec `DELETE_IMAGES=true`, le bouton de suppression est proposé à `dev`. Faute de RBAC, `dev` pourrait donc aussi supprimer des tags
  depuis l'UI (même limite que le push ci-dessous).

### `htpasswd` suffit-il en entreprise ?

Non, et c'est démontré : `dev`, censé être en lecture seule, a **pu pousser** `shopapi:dev-push-test`.
`htpasswd` sait seulement *qui* se connecte, pas *ce qu'il a le droit de faire*. Ses autres limites : comptes dans un fichier
(pas de SSO/LDAP, pas de révocation centralisée, pas d'expiration), aucune journalisation des accès par utilisateur.

| Besoin | Harbor / Nexus / Artifactory / ECR, ACR, GAR |
|---|---|
| RBAC | Rôles par projet (pull, push, admin), comptes robots pour la CI, SSO OIDC/LDAP, IAM cloud |
| Scan intégré | Trivy ou Clair à chaque push, blocage du pull d'une image vulnérable |
| Signature | Vérification cosign/Notation à l'entrée, politique « signée obligatoire » |
| Immutabilité des tags | Règles par motif (`v*`, semver) : un push sur un tag existant est refusé côté registre |
| Rétention et quotas | Règles déclaratives (« garder les 10 derniers `main-*` »), quotas par projet, GC planifié |
| Réplication | Push ou pull entre sites et régions, mirror de Docker Hub, plusieurs registres amont |
| Audit | Qui a poussé, tiré ou supprimé quoi, et quand |

---

## 2. API du registre (curl + jq)

Sorties : [`diag/etape2-api.txt`](diag/etape2-api.txt), [`diag/etape2-retention-gc.txt`](diag/etape2-retention-gc.txt).

| Action | Requête | Résultat |
|---|---|---|
| Dépôts | `GET /v2/_catalog` | `{"repositories":["demo","shopapi"]}` |
| Tags | `GET /v2/demo/tags/list` | 12 tags |
| Digest d'un tag **avec `Accept`** (index OCI, manifeste OCI, liste et manifeste Docker v2) | `HEAD /v2/demo/manifests/latest` | 200, `content-type: application/vnd.oci.image.index.v1+json`, `Docker-Content-Digest: sha256:…` |
| Même requête **sans `Accept`** | idem | `registry:3` : 200, même index. `registry:2.8` : **404** sans `Docker-Content-Digest` (il tente une conversion vers l'ancien format *schema 1*, impossible pour un index OCI). Il faut donc toujours envoyer l'`Accept` : c'est le seul moyen d'obtenir à coup sûr le digest du bon objet |
| Suppression d'un tag | `DELETE /v2/demo/manifests/latest` | 202 en v3 : **seul ce tag** disparaît, `main-5f6a7b8` (même digest) reste. En v2.8, cette requête renvoie 400 (non supporté). |
| Retag sans pull | `GET` du manifeste par tag, puis `PUT /v2/demo/manifests/latest` avec le même contenu | 201 |
| Suppression par digest | `DELETE /v2/demo/manifests/sha256:…` | 202 : **tous les tags** pointant sur ce manifeste (`latest` **et** `main-5f6a7b8`) disparaissent |

**Deux tags sur le même manifeste** : un `DELETE` par digest supprime le manifeste, donc tous ses tags. C'est un piège pour
la rétention quand une release (`2.0.0`) et un build (`main-9a8b7c6`) partagent un digest : supprimer le build par digest efface la
release.

### `retention.sh`

```bash
REGISTRY_USER=ci REGISTRY_PASSWORD=ci-push-2024 tools/run.sh -c 'DRY_RUN=0 ./retention.sh demo 3'
```

Règles :
- les tags semver et les artefacts cosign (`sha256-*.sig/.att`) sont toujours conservés ;
- parmi le reste, ce sont les **N images** (digests) les plus récentes, d'après la date `created` de leur config, qui sont gardées, avec tous leurs tags.
  Un alias comme `latest` ne prend donc pas la place d'un build ;
- une image supprimée qui est aussi publiée sous un tag semver perd **son tag seul** (`DELETE` par tag). Les autres sont supprimées par digest ;
- `DRY_RUN=1` par défaut.

```
garde     latest main-5f6a7b8 (2026-10-22)
garde     main-4e5f6a7 (2026-10-20)
garde     main-3d4e5f6 (2026-10-18)
supprime  main-2c3d4e5 (sha256:b6f62074…) -> HTTP 202
supprime  main-1b2c3d4 pr-42 (sha256:3466215e…) -> HTTP 202
supprime  main-0a1b2c3 (sha256:d1168dcc…) -> HTTP 202
supprime  main-9a8b7c6 : tag seul, l'image reste publiée sous 2.0.0 -> HTTP 202
```

### Garbage collection : un bug grave de `registry:2.8`

`DELETE` ne libère pas d'espace : il faut ensuite lancer
`docker compose exec registry registry garbage-collect [--delete-untagged] /etc/distribution/config.yml`. Dans l'idéal, on le fait registre arrêté
ou en lecture seule, car un push en parallèle peut perdre des blobs.

| | `registry:2.8.3` | `registry:3.0.0` |
|---|---|---|
| GC simple | Sûr, mais ne libère que les blobs des index supprimés. Les manifestes enfants et les couches restent | Idem |
| GC `--delete-untagged` | **Corrompt toutes les images multi-plateformes et les index OCI** : les manifestes enfants (un par plateforme) sont considérés comme « non tagués » et supprimés. Les blobs passent de 54 Mo à 420 Ko, et `docker pull` échoue (`short read`) | Correct : 102 blobs et 47 manifestes orphelins supprimés, toutes les images restantes sont intactes et récupérables |

Preuve : [`diag/etape2-gc-delete-untagged-bug.txt`](diag/etape2-gc-delete-untagged-bug.txt). Avec Docker 29 et le containerd store,
*toutes* les images poussées sont des index OCI, attestation de provenance comprise. Sur `registry:2`, `--delete-untagged` est donc inutilisable :
c'est ce qui a motivé le passage à `registry:3.0.0`. Le gain d'espace reste faible ici, parce que les images `demo` partagent toutes la même
couche alpine.

---

## 3. Politique de tags

Voir [`TAGGING.md`](TAGGING.md). Retags réalisés ([`diag/etape3-retag.txt`](diag/etape3-retag.txt)) :

```
crane tag registry.local:5000/shopapi:1.4.2 1.4 && crane tag … 1     -> 1.4.2, 1.4, 1 : même digest sha256:e9cc6195…
skopeo copy --all --preserve-digests docker://…/shopapi:1.4.2 docker://…/prod/shopapi:1.4.2   -> même digest
docker image ls | grep -c registry.local:5000/prod                    -> 0 (aucun pull local)
```

---

## 4. SBOM, scan, signature

Sorties : [`diag/etape4-sbom-scan.txt`](diag/etape4-sbom-scan.txt), [`diag/etape4-signature.txt`](diag/etape4-signature.txt).
Outils, épinglés et lancés en conteneur : syft v1.54.1, trivy 0.69.1, cosign v2.6.1, crane v0.20.3, skopeo v1.17.0.

| Commande | Résultat |
|---|---|
| `syft shopapi:1.4.2 -o spdx-json` | **340 paquets** : 320 npm, 18 apk, 1 generic (node), 1 oci |
| `trivy image --severity HIGH,CRITICAL --ignore-unfixed shopapi:1.4.2` | **26 CVE corrigeables** : 22 dans le **CLI npm** livré avec l'image `node` (`tar` ×9 dont 1 CRITICAL, `minimatch`, `brace-expansion`, `glob`, `cross-spawn`…) et 4 dans OpenSSL d'alpine |
| idem `shopapi:1.4.2-distroless` (TP01) | 7 (OpenSSL Debian 12) |
| `trivy image --scanners secret shopapi:legacy` | **Oui, la clé AWS du TP01 est retrouvée** : `/app/.env` ligne 4, `aws-access-key-id` (CRITICAL) |

**Signature.** `cosign generate-key-pair` (mot de passe vide), puis signature **par digest** :

```bash
cosign sign --key supply/cosign.key --tlog-upload=false registry.local:5000/shopapi@sha256:e9cc6195…
cosign verify --key supply/cosign.pub --insecure-ignore-tlog registry.local:5000/shopapi:1.4.2
cosign attest --key supply/cosign.key --tlog-upload=false --type spdxjson --predicate supply/sbom.json registry.local:5000/shopapi@sha256:e9cc6195…
```

`--tlog-upload=false` : sans cette option, cosign v2 publie la signature sur **Rekor, le journal de transparence public de Sigstore**,
ce qui rendrait publics le nom du registre interne et les digests. Avec une clé locale et un registre privé, on n'envoie rien.
La vérification passe alors `--insecure-ignore-tlog`. En entreprise, on utiliserait une instance Rekor privée, ou KMS + Notation.

**Ce que la signature crée dans le registre** : aucun nouveau dépôt (`_catalog` inchangé), mais deux tags dans `shopapi`,
`sha256-e9cc6195….sig` (signature) et `sha256-e9cc6195….att` (attestation SBOM). Ce sont des artefacts OCI ordinaires, nommés d'après le
digest signé.

**Retag puis re-push d'une image modifiée sous le même tag** : le tag `1.4.2` pointe sur un nouveau digest (`0969821e…`).

| Vérification | Résultat |
|---|---|
| `cosign verify …/shopapi:1.4.2` (tag réécrit) | **REFUSÉ** : no signatures found |
| `cosign verify …/shopapi@sha256:e9cc6195…` (ancien digest) | Valide |
| `cosign verify …/prod/shopapi:1.4.2` (copie skopeo, même digest) | **REFUSÉ** : la signature n'a pas été copiée |
| après `cosign copy` | Valide |

**La signature suit le digest, pas le tag.** Elle porte sur le contenu, et un tag n'est qu'un pointeur. Pour cette raison, il
faut toujours déployer `image@sha256:…` vérifié (voir B3).

---

## 5. La porte de release

```bash
./release-gate.sh IMAGE [--push REGISTRY/REPO:TAG]     # exit 0 accepté, 1 refusé, 2 erreur d'outillage
```

| Contrôle | Méthode |
|---|---|
| Labels OCI `version`, `revision`, `source` | `docker image inspect`. `version` doit être semver, ce qui détecte un label hérité de l'image de base (`22.04` d'Ubuntu dans legacy) |
| Utilisateur non-root | `Config.User` différent de vide, `root` et `0` |
| `HEALTHCHECK` | `Config.Healthcheck.Test` différent de `NONE` |
| CVE HIGH/CRITICAL corrigeables | `trivy --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed` |
| Secrets | `trivy --scanners secret --image-config-scanners secret`, plus les identifiants dans les variables `ENV` (noms `*PASS*`, `*SECRET*`, `*TOKEN*`… ou URL `scheme://user:pass@`). trivy **ne détecte pas** `DATABASE_URL=postgres://shop:S3cret!@…` |
| Si `--push` | Refus si un tag semver existe déjà avec un autre digest (immutabilité). Puis push, SBOM SPDX (syft) **et** CycloneDX (trivy) du digest publié, signature, deux attestations, vérification. Idempotent : une relance sur une image déjà publiée et signée ne republie rien |

Tous les contrôles sont exécutés et rapportés avant le verdict, pour donner une liste complète à corriger. Une erreur d'outil
(scan impossible) **refuse** la publication (exit 2) : la porte refuse en cas de doute, elle ne laisse rien passer par défaut.

Sortie : [`diag/etape5-release-gate.txt`](diag/etape5-release-gate.txt).

| Image | Verdict | Détail |
|---|---|---|
| `shopapi:legacy` | **REFUSÉ** (8 échecs) | `version=22.04` non semver, `revision` et `source` absents, root, pas de healthcheck, 22 CVE corrigeables, `DATABASE_URL` en ENV, 2 secrets (`.env`) |
| `shopapi:1.4.2` (TP01) | **REFUSÉ** (1 échec) | 26 CVE HIGH/CRITICAL corrigeables |
| `shopapi:1.4.3` | **ACCEPTÉ, PUBLIÉ** | Poussé, SBOM SPDX (132 paquets) et CycloneDX, signé, attesté, vérifié |
| `shopapi:1.4.3-rebuild` vers `…/shopapi:1.4.3` | **REFUSÉ** | Le tag semver existe déjà avec un autre digest |

### Pourquoi 1.4.2 est refusée, et ce qu'est 1.4.3

Le README attend que `1.4.2` soit acceptée. Elle l'aurait été au moment de l'écriture du TP, mais plus aujourd'hui : **Node 20 est en fin de vie
depuis le 30 avril 2026**. Les images `node:20-alpine` et `distroless/nodejs20` ne sont plus reconstruites (le digest de
`node:20-alpine` n'a pas changé depuis le TP01) et accumulent les CVE. La porte fait exactement son travail. Le correctif n'est pas de baisser
le seuil, mais de passer à une LTS maintenue :

| Image de base candidate | CVE HIGH/CRITICAL corrigeables |
|---|---|
| `node:22-alpine` | 10 |
| `node:24-alpine` | 4 |
| `distroless/nodejs22-debian12` | 7 |
| **`distroless/nodejs24-debian13`** | **0** |

`shopapi:1.4.3` est une **reconstruction de sécurité** : même code applicatif que 1.4.2, tests sur `node:24-alpine`, exécution sur
`distroless/nodejs24-debian13`, toutes deux épinglées par digest. Comme les tags semver sont immuables, elle a un nouveau numéro de version.
Elle est `healthy`, s'arrête en 0,09 s avec le code 0, et `GET /` renvoie `{"version":"1.4.3"}`.

Deux modifications au TP01 ont été nécessaires (et rien d'autre) :
1. **`Dockerfile`** : `ARG DISTROLESS_IMAGE` pour choisir la base distroless, et le label `base.name` reprend les `ARG`. Les valeurs par défaut sont inchangées.
2. **`package.json`** : `"test": "node --test test/"` devient `"node --test"`. Depuis Node 21, `node --test` n'accepte plus un répertoire en argument
   (`Cannot find module '/app/test'`). La découverte automatique fonctionne sous Node 20 comme sous 24. Une migration de version majeure n'est donc
   jamais une simple mise à jour de l'image de base.

```bash
cd ../../tp01-optimisation-image/starter/shopapi
docker build --target runtime-distroless \
  --build-arg NODE_IMAGE=node:24.22.1-alpine3.24@sha256:06d7adf3… \
  --build-arg DISTROLESS_IMAGE=gcr.io/distroless/nodejs24-debian13:nonroot@sha256:cb606325… \
  --build-arg APP_VERSION=1.4.3 --build-arg GIT_SHA=$(git rev-parse --short HEAD) -t shopapi:1.4.3 .
```

---

## Bonus

### B1 : scan continu avec un serveur trivy partagé

[`scan/compose.yml`](scan/compose.yml) : `trivy server` (port 4954, jeton dans `scan/.env`), base dans un volume, service
`db-update` (`trivy image --download-db-only`) à planifier. Sortie : [`diag/bonus-b1-trivy-server.txt`](diag/bonus-b1-trivy-server.txt).

| Runner CI neuf (sans cache) | Durée | Résultat |
|---|---|---|
| Mode autonome : télécharge la base (1,5 Go une fois décompressée) | 7,1 s | 26 CVE |
| Mode client : `--server http://localhost:4954 --token …` | **1,0 s** | 26 CVE |
| Client sans jeton | refusé | `invalid token` |

Le client analyse l'image (liste des paquets), le serveur fait la correspondance avec la base. On a une seule base à jour pour toute
l'équipe, pas de téléchargement par job (ni de limitation de débit sur `ghcr.io`), et des résultats cohérents entre runners. En production, il faut :
mettre le serveur derrière TLS, faire tourner le jeton, et planifier `db-update` toutes les 6 h, suivi d'un `restart`.

### B2 : signature keyless (Fulcio + Rekor)

Signature lancée par Alexandre (connexion GitHub dans le navigateur), vérifiée ensuite. Sortie :
[`diag/bonus-b2-keyless.txt`](diag/bonus-b2-keyless.txt) (e-mail masqué).

```bash
tools/oci.sh ghcr.io/sigstore/cosign/cosign:v2.6.1 sign --fulcio-auth-flow device registry.local:5000/shopapi@sha256:e724fbb5…
tools/oci.sh ghcr.io/sigstore/cosign/cosign:v2.6.1 verify --certificate-identity <e-mail GitHub> \
  --certificate-oidc-issuer https://github.com/login/oauth registry.local:5000/shopapi:1.4.3
```

`--fulcio-auth-flow device` : cosign tourne en conteneur et ne peut pas ouvrir de navigateur. Il affiche donc un lien et un code à
valider sur `oauth2.sigstore.dev`, comme pour se connecter à une TV.

| Vérification | Résultat |
|---|---|
| Identité GitHub attendue, émetteur `https://github.com/login/oauth` | Valide : signature, certificat Fulcio et présence dans le journal Rekor vérifiés |
| Autre identité (`autre@exemple.com`) | **REFUSÉ** (exit 12) : `none of the expected identities matched … got subjects [a***@free.fr]` |
| `--key supply/cosign.pub` | Toujours valide : les deux signatures cohabitent dans le même tag `sha256-e724fbb5….sig` |

Entrée publique Rekor n° **3487377014** (https://search.sigstore.dev/?logIndex=3487377014) :

| Champ | Valeur |
|---|---|
| Type | `hashedrekord` : Rekor stocke l'**empreinte** du contenu signé (`sha256:381b006a…`), la signature et le certificat |
| Horodatage | 2026-10-26 14:10:39 UTC, avec une preuve d'inclusion et un horodatage signé par Rekor |
| Certificat | Émis par `sigstore-intermediate`, **valable 10 minutes** (14:10:39 → 14:20:39), SAN `email:a***@free.fr`, émetteur OIDC `https://github.com/login/oauth` |
| `registry.local:5000` présent dans l'entrée ? | **Non** : le nom de l'image est dans le contenu signé, dont seule l'empreinte est publiée |

Le certificat expire 10 minutes après sa création, et la signature reste pourtant vérifiable des mois plus tard. C'est Rekor qui
rend cela possible : il prouve que la signature a été faite *pendant* la validité du certificat. Plus de clé à protéger ni à révoquer,
mais l'**adresse e-mail est publiée définitivement** dans un journal public impossible à effacer.

| | Clé (`cosign.key`) | Keyless (Fulcio + Rekor) |
|---|---|---|
| Secret à protéger | Une clé privée longue durée (fuite = tout signer) ; rotation et révocation manuelles | Aucun : certificat de 10 minutes, lié à une identité OIDC |
| Vérification | « Signé par cette clé » | « Signé par `ci@shop` via GitHub Actions, workflow X, dépôt Y » (identité vérifiable) |
| Traçabilité | Aucune hors du registre | Journal de transparence public et infalsifiable (horodatage, preuve d'inclusion) |
| Confidentialité | Rien ne sort de l'entreprise | Identité, digest et nom d'image **publiés** dans Rekor (sauf Sigstore privé) |
| Dépendances | Hors ligne possible | Fulcio, Rekor et l'IdP doivent être joignables ; il faut faire confiance à la racine Sigstore |
| Cas idéal | Registre interne, zone isolée, KMS (`--key awskms://…`) | CI publique (GitHub Actions avec `id-token: write`), projets open source |

### B3 : `verified-run.sh`

```bash
./verified-run.sh -d --name api -p 3003:3000 registry.local:5000/shopapi:1.4.3
```

Le script résout le digest, vérifie la signature de **ce digest**, puis lance `docker run …@sha256:…` (pas le tag). Une réécriture du
tag entre la vérification et l'exécution est donc sans effet. Sortie : [`diag/bonus-b3-verified-run.txt`](diag/bonus-b3-verified-run.txt).

| Image | Résultat |
|---|---|
| `shopapi:1.4.3` (signée par la porte) | Lancée, `docker inspect` : `Config.Image = …/shopapi@sha256:e724fbb5…` |
| `prod/shopapi:1.4.2` (signature recopiée par `cosign copy`) | Lancée |
| `demo:1.0.0` (jamais signée) | **REFUSÉ**, exit 1 |
| `demo:tampered` (image modifiée puis poussée) | **REFUSÉ**, exit 1 |
| `shopapi:inexistant` | **REFUSÉ** (introuvable), exit 1 |

Limite : un wrapper se contourne avec `docker run` directement. La vraie mise en œuvre se fait côté orchestrateur : admission
Kubernetes (Sigstore policy-controller, Kyverno `verifyImages`, Connaisseur), ou plugin d'autorisation Docker.

### B4 : `trivy sbom` : scanner le SBOM plutôt que l'image

Sortie : [`diag/bonus-b4-trivy-sbom.txt`](diag/bonus-b4-trivy-sbom.txt). Les SBOM sont relus **depuis les attestations signées**
(`cosign verify-attestation … | jq -r .payload | base64 -d | jq .predicate`), sans accès aux couches de l'image.

| Source scannée (`shopapi:1.4.3`) | Résultat | OS détecté |
|---|---|---|
| `trivy image` (référence) | LOW=8 MEDIUM=23 | debian 13.7 |
| SBOM **SPDX de syft** | **aucune** : faux négatif | **none** |
| SBOM **CycloneDX de trivy** | LOW=8 MEDIUM=23, identique | debian 13.7 |
| idem, via le serveur partagé (runner sans base) | LOW=8 MEDIUM=23 | |

Sur `1.4.2`, le SPDX de syft donne 22 HIGH au lieu de 26 (les 4 CVE OpenSSL d'alpine manquent). Avec le CycloneDX 1.5 de syft, trivy reconnaît
bien l'OS, mais rate quand même les paquets système (identifiants de paquets différents). Le CycloneDX 1.6+ de syft 1.54 est refusé par trivy 0.69
(« invalid specification version »).

**Conséquence : un SBOM destiné à être rescanné doit être produit par le scanner qui fera le rescan, et ce point doit être testé.**
J'ai donc fait attester par `release-gate.sh` les deux formats : le SPDX de syft, comme demandé, et le CycloneDX de trivy, pour les rescans.

**Intérêt pour une CVE publiée 6 mois après le build** : l'image ne change pas, mais la base de vulnérabilités, si. Rescanner chaque
jour les SBOM attestés de toutes les images en production détecte la nouvelle CVE en quelques secondes, sans tirer ni décompresser
les images (et même si l'image a été supprimée du registre ou n'est plus accessible). Le SBOM signé garantit en plus qu'on
scanne bien ce qui a été publié. C'est le principe du « continuous monitoring » de Harbor, Dependency-Track ou Docker Scout.

---

## État laissé sur le poste

| Élément | Pour revenir en arrière |
|---|---|
| Stack `shop-registry` (registry, mirror, ui) et `shop-scan` (trivy) | `docker compose down -v` dans `registry/` et `scan/` |
| `colima.yaml` modifié | `cp ~/.colima/default/colima.yaml.bak-tp03 ~/.colima/default/colima.yaml && colima restart` |
| CA dans la VM | `colima ssh -- sudo rm -r '/etc/docker/certs.d/registry.local:5000'` |
| Identifiant `ci` dans le trousseau | `docker logout registry.local:5000` |
| Registre `tp02-registry` (port 5050) et builder `shop` du TP02 | `docker rm -f tp02-registry && docker buildx rm shop` |
