# TP05 : données, persistance, sauvegarde, restauration, montée de version

Environnement : Mac Apple Silicon, Colima (VM Ubuntu, noyau 6.8), Docker Engine 29.5.2 (containerd image store), Compose v5.1.4.
Transcripts et preuves : [`diag/`](diag/). Aucun commentaire dans les scripts : les explications sont ici.

| Livrable | Fichier |
|---|---|
| Sauvegarde | [`backup.sh`](backup.sh) : dump logique `-Fc` horodaté et vérifié, rôles, copie brute optionnelle (`RAW=1`), sha256, rétention `KEEP` (7) |
| Restauration | [`restore.sh`](restore.sh) : `.dump` (pg_restore en une transaction) ou `.tar.gz` (volume recréé), avec contrôle sha256 |
| Montée de version | [`upgrade-pg.sh`](upgrade-pg.sh), [`compose.pg16.yml`](compose.pg16.yml) (16 sur un **nouveau** volume), [`compose.noports.yml`](compose.noports.yml) |
| Sidecar planifié | [`../tp04-compose-entreprise/compose.backup.yml`](../tp04-compose-entreprise/compose.backup.yml) |
| Transcripts | [`diag/etape2-transcript-restauration.txt`](diag/etape2-transcript-restauration.txt), [`diag/etape3-transcript-upgrade.txt`](diag/etape3-transcript-upgrade.txt) |
| Bonus | [`bonus/`](bonus/) : `b1-pg-upgrade.sh`, `b2-offsite.sh`, `b3-nfs.sh`, `b4-pitr.sh` |

Tous les scripts passent uniquement par des conteneurs : aucun client `psql` ni `pg_dump` sur l'hôte.

Le `starter/compose.yml` publie `5433:5432`, déjà utilisé par le port de debug du TP04. `compose.noports.yml` le retire
(`ports: !reset []`) sans toucher au starter.

Périmètre des destructions : uniquement les projets `shop-copy` (copie de la stack du TP04) et `shopdata`, et les ressources
`tp05-*`. Les `prune` ont toujours un filtre de label. Le volume `shop_pgdata` du TP04 n'a pas été touché.

---

## 1. Anatomie du stockage

### Couche du conteneur et volume ([`diag/etape1-anatomie.txt`](diag/etape1-anatomie.txt))

```
$ docker inspect db --format '{{json .Mounts}}'
volume shop_pgdata    /var/lib/docker/volumes/shop_pgdata/_data   -> /var/lib/postgresql/data
bind   …/db/init.sql                                              -> /docker-entrypoint-initdb.d/001-init.sql (ro)
bind   …/secrets/db_password.txt                                  -> /run/secrets/db_password (ro)

$ docker exec db touch /tmp/x && docker diff db
A /tmp/x    C /run/postgresql    A /run/postgresql/.s.PGSQL.5432 …
(rien sous /var/lib/postgresql/data, alors que PG_VERSION, base/, global/ y sont écrits en permanence)

/tmp/x physiquement : /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/4792/fs/tmp/x
données PostgreSQL  : /var/lib/docker/volumes/shop_pgdata/_data/{PG_VERSION,base,global,…}
```

- **La couche inscriptible** est un *snapshot* overlayfs de containerd, propre au conteneur. Elle disparaît avec lui (`docker rm`), et
  `docker diff` la montre. Avec Docker 29 et le containerd store, `docker inspect` n'a plus de champ `GraphDriver` mais `Storage.RootFS.Snapshot`.
- **Le volume** est un répertoire géré par Docker, hors du conteneur. Il est **invisible** pour `docker diff`, et sa durée de vie est
  indépendante de celle du conteneur.

### Cycle de vie de `pgdata` ([`diag/etape1-cycle-de-vie.txt`](diag/etape1-cycle-de-vie.txt), sur la copie `shop-copy`)

| Commande | Volume nommé | Ligne témoin |
|---|---|---|
| `docker compose down` | conservé | présente |
| `docker compose rm` | conservé | présente |
| `docker compose rm -v` | **conservé** (`-v` ne vise que les volumes anonymes) | présente |
| `docker volume prune` | **conservé** : depuis Docker 23, `prune` ne supprime que les volumes **anonymes** | présente |
| `docker volume prune -a` | **supprimé** s'il n'est utilisé par aucun conteneur | perdue |
| `docker compose down -v` | **supprimé** | perdue |

Le piège de l'incident : `down -v` supprime **les volumes nommés déclarés dans le fichier**, et pas seulement les volumes anonymes.
`prune -a` est encore plus large, puisqu'il touche tous les projets de la machine. Je ne l'ai lancé qu'avec un filtre de label.

### Volume anonyme ([`diag/etape1-volume-anonyme.txt`](diag/etape1-volume-anonyme.txt))

- **Les données vont dans un volume anonyme.** L'image `postgres` déclare `VOLUME /var/lib/postgresql/data`, donc `docker run -d postgres:16-alpine`
  sans `-v` crée un volume au nom aléatoire (`f738ac00…`), et les données sont dans son `_data`.
- **Il est créé même si le conteneur échoue.** Sans `POSTGRES_PASSWORD`, le conteneur s'arrête aussitôt (« superuser password is not
  specified »), mais le volume existe déjà.
- **`docker rm` le laisse orphelin** (« dangling ») : les données sont récupérables, à condition de retrouver le bon identifiant parmi les autres.
- **`docker rm -v` le supprime.**

**Pourquoi c'est un piège :**
- on croit les données « dans le conteneur » ;
- chaque `docker run` crée un nouveau volume vide, donc la base semble perdue au redémarrage alors qu'elle traîne dans un volume orphelin ;
- les orphelins s'accumulent et remplissent le disque ;
- un `prune`, ou un `rm -v` par réflexe, efface tout.

Il faut toujours nommer les volumes de données.

### Bind mount, volume nommé, tmpfs ([`diag/etape1-perf-montages.txt`](diag/etape1-perf-montages.txt))

| Montage | 256 Mo + fsync | 5000 petits fichiers | Lecture |
|---|---|---|---|
| Bind mount (virtiofs, fichiers du Mac) | 228 ms | **1091 ms** | 409 ms |
| Volume nommé (disque de la VM) | 174 ms | 113 ms | 43 ms |
| tmpfs (RAM) | 48 ms | 37 ms | 36 ms |
| Couche du conteneur (overlayfs) | 221 ms | 115 ms | 43 ms |

| Type | Quand l'utiliser |
|---|---|
| **Volume nommé** | Données d'un service (bases, files, uploads). Géré par Docker, performant, sauvegardable avec un conteneur. Par défaut pour tout ce qui doit survivre |
| **Bind mount** | Code source en dev, fichiers de configuration, secrets (Compose), sockets (`docker.sock`). Lié à un chemin de l'hôte et à ses droits |
| **tmpfs** | Données temporaires ou sensibles qui ne doivent jamais toucher le disque : `/tmp` d'un conteneur `read_only`, sockets, caches éphémères. Perdu à l'arrêt |

Sur Docker Desktop ou Colima (macOS/Windows), le bind mount traverse la frontière Mac ↔ VM (virtiofs, gRPC-FUSE, 9p) : **10 fois plus lent**
sur les petits fichiers (`node_modules`, `.git`, fichiers PHP…), sans compter les problèmes d'inotify vus au TP04. Il faut y mettre le
moins possible et garder les dépendances dans un volume ou dans l'image. Sous Linux natif, bind mount et volume ont les mêmes performances.

### Pourquoi `init.sql` n'est pas rejoué ([`diag/etape1-init-sql.txt`](diag/etape1-init-sql.txt))

```
1er démarrage : running /docker-entrypoint-initdb.d/001-init.sql            produits : 3
(suppression du produit 3, puis restart, puis down/up)
redémarrage   : PostgreSQL Database directory appears to contain a database; Skipping initialization   produits : 2
après down -v : running /docker-entrypoint-initdb.d/001-init.sql            produits : 3
```

`docker-entrypoint.sh` n'exécute `initdb` et les scripts de `docker-entrypoint-initdb.d` **que si le répertoire de données est vide**
(il teste la présence de `PG_VERSION`). C'est voulu : rejouer l'initialisation sur une base en service écraserait ou dupliquerait des données.
Pour réinitialiser, il faut supprimer le volume (`down -v`, ou recréer `pgdata`), ou rejouer le script à la main
(`docker compose exec -T db psql -U shop -d shop < db/init.sql`). Les évolutions de schéma passent par des migrations (TP04, `make migrate`), pas par `init.sql`.

---

## 2. Sauvegarde et restauration

### `backup.sh`

```bash
PROJECT=shop ./backup.sh
RAW=1 KEEP=7 PROJECT=shop ./backup.sh
```

1. Le conteneur est retrouvé **par les labels Compose** (`com.docker.compose.project` et `service`), sans dépendre des fichiers Compose.
2. Il affiche l'empreinte, calculée avec la même requête que `seed.sh`.
3. `pg_dump -Fc -Z6` est exécuté **dans le conteneur de la base**. Le dump est écrit en `.part` puis renommé (jamais de dump tronqué
   présenté comme valide), **relu** avec `pg_restore --list`, et accompagné d'un `.sha256`.
4. `pg_dumpall --globals-only` sauvegarde les rôles, que `pg_dump` ne contient pas.
5. Avec `RAW=1`, il fait une copie brute du volume avec `alpine` et `tar` (`-v vol:/data:ro`), **base arrêtée** (2 à 3 s) puis redémarrée et attendue `healthy`.
6. La rétention garde les `KEEP` derniers fichiers de chaque type.

### Quand la copie brute est-elle incohérente ?

**Quand elle est faite base en marche.** `tar` copie les fichiers les uns après les autres pendant plusieurs secondes, alors que
PostgreSQL continue d'écrire dans les tables, les index, `pg_xact` et les WAL. La copie mélange des fichiers d'instants différents, et parfois
des pages à moitié écrites. Au redémarrage, la récupération part d'un checkpoint qui ne correspond pas aux fichiers copiés. Résultat
possible : un démarrage en échec, ou pire, une corruption silencieuse (index qui ne correspond plus à sa table).

Trois façons de la rendre cohérente :

| Méthode | Principe |
|---|---|
| Arrêt de la base (`RAW=1` de `backup.sh`) | Arrêt propre, donc tout est écrit sur disque et l'arrêt est marqué dans `pg_control`. Simple et sûr, avec une courte indisponibilité |
| `pg_backup_start()` / `pg_backup_stop()` (PG ≥ 15) | Copie à chaud dans une même session : `pg_backup_start` force un checkpoint, la copie peut être incohérente, et `pg_backup_stop` renvoie le contenu de `backup_label` (à poser dans l'archive) ainsi que la position WAL de fin. Il faut **aussi** les WAL générés pendant la copie. C'est exactement ce que fait `pg_basebackup` (bonus B4) |
| Instantané atomique du système de fichiers (LVM, ZFS, EBS) | Copie équivalente à un crash, rejouée correctement par la récupération de PostgreSQL |

### Preuve de restauration ([`diag/etape2-transcript-restauration.txt`](diag/etape2-transcript-restauration.txt))

```
$ bash starter/seed.sh                         ->  100000 | 609135be0f9e38254aacdc7cf2e75395
$ RAW=1 ./backup.sh                            ->  dump 1.5M (3 tables), rôles, copie brute 16M (base arrêtée 3 s)
$ docker compose down -v                       ->  Volume shop-copy_pgdata Removed
$ docker compose up -d --wait db               ->  base vide : 0 commande
$ ./restore.sh backups/shop-copy-shop-….dump   ->  sha256 vérifié ; empreinte 100000 609135be0f9e38254aacdc7cf2e75395
```

**Empreinte identique avant destruction et après restauration.** La copie brute a aussi été testée (`down -v`, puis `restore.sh` sur le
`.tar.gz`, puis `up`) : « Skipping initialization », et une empreinte identique. La rétention a été vérifiée avec `KEEP=3` (seuls les 3 derniers sont conservés).

`restore.sh` utilise `pg_restore --clean --if-exists --single-transaction --exit-on-error` : soit toute la restauration réussit, soit rien
ne change. Une erreur ne laisse pas une base à moitié restaurée.

### Sidecar planifié ([`diag/etape2-sidecar.txt`](diag/etape2-sidecar.txt))

[`compose.backup.yml`](../tp04-compose-entreprise/compose.backup.yml) ajoute `prodrigestivill/postgres-backup-local:16-alpine` (épinglée
par digest) à la stack du TP04. Il est sur le réseau `back`, lit le mot de passe par `POSTGRES_PASSWORD_FILE` (le même secret), produit des dumps
`custom`, et applique une rétention de 7 jours, 4 semaines et 6 mois.

```bash
BACKUP_SCHEDULE="@every 1m" docker compose -f compose.yml -f compose.override.yml -f compose.backup.yml up -d --wait backup
```

```
backups/last/shop-20261029-102747.dump … shop-20261029-103247.dump   (un par minute)
backups/daily/shop-20261029.dump  weekly/shop-202644.dump  monthly/shop-202610.dump
pg_restore --list sur le dernier dump -> 3 tables
```

Le sidecar a ensuite été remis sur `@daily`, la valeur par défaut. Constat : son image définit un healthcheck **toutes les 5 minutes**, si bien
que `up --wait` attendait près de 5 minutes. Un `start_interval: 2s` (sonde rapide pendant le démarrage seulement) ramène `--wait` à **3 s**.

---

## 3. Montée de version PostgreSQL 14 → 16

### Changer seulement le tag ne marche pas ([`diag/etape3-tag-naif.txt`](diag/etape3-tag-naif.txt))

```
FATAL:  database files are incompatible with server
DETAIL: The data directory was initialized by PostgreSQL version 14, which is not compatible with this version 16.4.
```

**Pourquoi :**
- le format des fichiers (catalogue système, `pg_control`, parfois le format des pages) change à chaque version **majeure** ;
- un serveur 16 ne sait pas lire un répertoire initialisé par une 14, et vérifie `PG_VERSION` au démarrage ;
- les versions mineures (16.3 → 16.4), elles, gardent le même format et ne demandent qu'un changement d'image.

Le refus est sans dommage : `PG_VERSION` vaut toujours 14, et revenir au tag 14 redonne la même empreinte.

### `upgrade-pg.sh` ([`diag/etape3-transcript-upgrade.txt`](diag/etape3-transcript-upgrade.txt))

```
== 1. État initial        version 14.13 ; 500 produits, 100000 commandes, md5 b6f351eae21b13e4cc1a773b8991bb2c
== 2. Sauvegardes         pg14-dumpall (4.9M), pg14-globals (4K), pg14-shop.dump (1.5M), chacun avec un .sha256
== 3. Arrêt PG14          shopdata_pgdata conservé
== 4. PG16 sur un nouveau volume shopdata_pgdata16    version 16.4
== 5. Restauration        rôles (globals) + pg_restore --single-transaction + vacuumdb --analyze-only
                          500 produits, 100000 commandes, md5 b6f351eae21b13e4cc1a773b8991bb2c
== 6. Verdict             indisponibilité 7 s ; OK : données identiques
```

**Le retour arrière a été réellement testé** : on arrête la 16 et on relance la 14 sur `shopdata_pgdata`, intact. On retrouve PostgreSQL 14.13
et la même empreinte, puis on repasse en 16. Le script refuse de recommencer si `shopdata_pgdata16` existe déjà (`FORCE=1` pour forcer).

- **Début de l'indisponibilité** : il est compté à partir du dump. Toute écriture faite après le dump serait perdue, donc l'application doit
  être en maintenance avant l'étape 2.
- **Statistiques** : `vacuumdb --analyze-only` est indispensable, car un dump ne contient pas les statistiques du planificateur. Sans lui, les
  premières requêtes après la bascule seraient lentes.

### Réponses

- **`pg_dumpall` ou `pg_dump` ?**
  - `pg_dumpall` exporte **tout le cluster** en SQL texte : rôles, tablespaces, toutes les bases avec leurs `CREATE DATABASE`. Il se rejoue
    avec `psql`, en séquentiel et sans sélection.
  - `pg_dump` exporte **une base**, sans les rôles. Au format `-Fc` (ou `-Fd`), il est compressé, restaurable en parallèle (`pg_restore -j`
    avec `-Fd`), et sélectif (une table, le schéma seul, les données seules).
  - D'où la combinaison utilisée : `--globals-only` pour les rôles, plus `pg_dump -Fc` par base. Le `pg_dumpall` complet est gardé en filet de sécurité.
- **Pourquoi un nouveau volume ?**
  - Le volume 14 reste **intact**, ce qui fait **le retour arrière** : il suffit de relancer l'ancienne image.
  - Écraser le volume obligerait à le vider avant la restauration : plus de chemin de retour si la restauration échoue ou si l'application
    a un souci avec la 16.
  - On peut aussi comparer les deux bases.
  - On ne supprime l'ancien volume qu'après une période de validation.
- **Réduire l'indisponibilité** (7 s ici, proportionnelle au volume de données avec dump/restore) :
  - **`pg_upgrade --link`** (bonus B1) : migre le catalogue et crée des **liens physiques** vers les fichiers de données, au lieu de les
    réécrire. La durée est quasi indépendante de la taille de la base. En contrepartie, l'ancien cluster n'est plus utilisable dès que le
    nouveau a démarré : il faut un retour arrière par sauvegarde ou snapshot.
  - **Réplication logique** (`CREATE PUBLICATION` en 14, `CREATE SUBSCRIPTION` en 16) : la 16 se synchronise pendant que la 14 tourne,
    puis on bascule (DNS ou alias réseau). L'indisponibilité tombe à quelques secondes, mais il faut gérer les séquences et les DDL.
  - **`pg_dump -Fd -j N` et `pg_restore -j N`** : du parallélisme sur les grosses bases.

---

## 4. Redis ([`diag/etape4-redis.txt`](diag/etape4-redis.txt))

Test : 1000 clés écrites, 2 s d'attente, puis `docker kill -s KILL` (pas d'arrêt propre, donc pas de sauvegarde à l'arrêt), redémarrage.

| Configuration | Clés après redémarrage | Perte maximale |
|---|---|---|
| `--save 60 1` (RDB seul) | **0 / 1000** | Tout ce qui a été écrit depuis le dernier instantané : **jusqu'à 60 s** dès qu'il y a eu une écriture, et bien plus si les seuils ne sont pas atteints. Un `fork` impossible (mémoire) fait aussi échouer l'instantané |
| `--appendonly yes --appendfsync everysec` | 1000 / 1000 | **Environ 1 s** (fsync une fois par seconde) |
| `--appendonly yes --appendfsync always` | 1000 / 1000 | Rien, au prix d'un fsync à chaque écriture (débit bien plus faible) |

**Dans notre stack (TP04)** : `appendonly yes`, donc fsync toutes les secondes, plus les instantanés RDB par défaut.

| Clé | Type | Rôle | Si elle est perdue |
|---|---|---|---|
| `products` | string, TTL 30 s | Cache du catalogue | Sans conséquence : régénéré depuis PostgreSQL au prochain `MISS` |
| `orders:queue` | list | File des commandes à valider | La commande existe déjà dans PostgreSQL en `pending`, mais **plus personne ne la traitera** |

Le cache seul ne justifierait aucune persistance. La file, si : une perte silencieuse laisse des commandes bloquées en `pending`. L'AOF
`everysec` est le bon compromis (au plus une seconde de file perdue, coût négligeable).

Pour garantir qu'aucune commande ne reste bloquée, la vraie solution n'est pas dans Redis : il faudrait une tâche qui reprend
périodiquement les commandes `pending` anciennes (PostgreSQL est la source de vérité), ou passer à Redis Streams avec acquittement
(`XREADGROUP` / `XACK`) au lieu de `BRPOP`, qui retire l'élément avant son traitement.

---

## Bonus

### B1 : `pg_upgrade --link` ([`bonus/b1-pg-upgrade.sh`](bonus/b1-pg-upgrade.sh), [`diag/bonus-b1-pg-upgrade.txt`](diag/bonus-b1-pg-upgrade.txt))

`tianon/postgres-upgrade:14-to-16` **n'existe pas pour arm64** (« no matching manifest for linux/arm64 »), et l'émulation amd64 aurait
faussé la mesure. [`bonus/pg-upgrade/Dockerfile`](bonus/pg-upgrade/Dockerfile) construit l'équivalent : alpine 3.20 avec `postgresql14`
(14.17) et `postgresql16` (16.14) côte à côte. C'est la même famille musl que l'image d'origine, donc les mêmes locales `en_US.utf8`.
Le script travaille sur une **copie** du volume 14.

| Méthode (74 Mo de données) | Durée | Résultat |
|---|---|---|
| dump/restore (`upgrade-pg.sh`) | 7 s d'indisponibilité | Empreinte identique |
| `pg_upgrade --copy` | 1,67 s | Empreinte identique, 0 fichier lié |
| `pg_upgrade --link` | 1,55 s | Empreinte identique, 17 fichiers de données liés (liens physiques) |

À 74 Mo, l'écart entre copie et lien est minime. La différence apparaît à grande échelle : `--copy` réécrit chaque octet (environ 1 h pour
1 To), alors que `--link` ne crée que des liens (quelques secondes, quelle que soit la taille). La contrepartie de `--link` : les deux clusters
partagent les fichiers, et l'ancien est **inutilisable** dès que le nouveau a écrit. Il faut donc un snapshot ou une sauvegarde avant, et
les deux répertoires doivent être sur le même système de fichiers (même volume).

### B2 : dump chiffré envoyé sur un S3 compatible ([`bonus/b2-offsite.sh`](bonus/b2-offsite.sh), [`diag/bonus-b2-offsite.txt`](diag/bonus-b2-offsite.txt))

**MinIO n'est plus disponible** : `minio/minio` et `minio/mc` ont disparu de Docker Hub (fin de la distribution d'images
communautaires), et `quay.io` ne répond pas. Je l'ai remplacé par **Garage** v2.1.0, un S3 compatible auto-hébergé, sans port publié, sur un réseau
dédié, et par **rclone** 1.75.1 comme client.

```
chiffrement age (clé X25519, en-tête age-encryption.org/v1) -> envoi s3://pg-backups -> retéléchargement -> déchiffrement
sha256 original : c94c60cc52d378f59a1190a6bd9ac03d27fee52c3ad5097f9b7b8ef38d478e74
sha256 restauré : c94c60cc52d378f59a1190a6bd9ac03d27fee52c3ad5097f9b7b8ef38d478e74   == OK
pg_restore --list sur le .age -> input file does not appear to be a valid archive
```

Le stockage distant ne voit que du chiffré. Seule la clé publique `age` est nécessaire pour chiffrer : le serveur de sauvegarde n'a pas
besoin de la clé privée, qu'il faut garder ailleurs (coffre, papier). Perdre `age.key`, c'est perdre toutes les sauvegardes chiffrées.

### B3 : volume NFS ([`bonus/b3-nfs.sh`](bonus/b3-nfs.sh), [`diag/bonus-b3-nfs.txt`](diag/bonus-b3-nfs.txt))

Un serveur NFS tourne en conteneur privilégié (le noyau de la VM a `nfsd`). Le volume Docker est déclaré
`--driver local --opt type=nfs --opt o=addr=…,rw,nfsvers=4 --opt device=:/` (l'équivalent Compose de `driver_opts`). Un fichier écrit
par un conteneur est lu par un autre. PostgreSQL 16 tourne dessus (`nfs4`), et ses fichiers apparaissent côté serveur.

| Volume | 100 000 lignes + CHECKPOINT |
|---|---|
| local (ext4) | 212 ms |
| NFS v4 | 236 ms |

L'écart est faible parce que le serveur est dans la même VM, et surtout parce que l'export de cette image est en **`async`** : le serveur
acquitte avant d'avoir écrit sur disque. C'est **inacceptable pour une base** (perte de transactions confirmées si le serveur NFS tombe). Il
faut `sync`, avec une latence réseau réelle à chaque `fsync`.

**Ce qui change :**
- **Sauvegarde** : les données sont sur le NAS, qu'on peut sauvegarder par snapshots du NAS sans passer par l'hôte Docker. Mais pour
  PostgreSQL, la règle ne change pas : un snapshot du NAS base en marche n'est cohérent que s'il est atomique, et le dump logique reste le
  seul format portable entre versions.
- **Haute disponibilité** : le volume est joignable depuis n'importe quel nœud, donc le conteneur peut redémarrer ailleurs (Swarm,
  Kubernetes, avec un PV en RWX). Mais le NAS devient lui-même un point de défaillance unique.
- **Danger** : **deux instances PostgreSQL sur le même répertoire** corrompent la base, et le verrouillage NFS ne l'empêche pas de façon
  fiable. La haute disponibilité d'une base passe plutôt par la réplication (primaire et secondaire, chacun sur son disque local) que par
  un stockage partagé.
- **Plugins** (rexray, local-persist, CSI) : le même principe, avec en plus la gestion du cycle de vie (création ou attachement de
  disques EBS/Ceph). Dans ce cas, c'est le stockage qui suit le conteneur.

### B4 : *Point-in-time recovery* ([`bonus/b4-pitr.sh`](bonus/b4-pitr.sh), [`diag/bonus-b4-pitr.txt`](diag/bonus-b4-pitr.txt))

```
archive_mode=on, archive_command=test ! -f /archive/%f && cp %p /archive/%f   (volume tp05-pitr-wal)
1000 commandes -> pg_basebackup -Ft -z -X stream (base.tar.gz + pg_wal.tar.gz + backup_manifest)
+500 commandes -> T = 2026-10-29 10:50:51.472525+00 ; état à T : 1500 commandes, total 74269.03
incident : DELETE FROM commandes -> 1 commande ; pg_switch_wal() ; 5 WAL archivés
restauration : base1 + recovery.signal + restore_command + recovery_target_time = T
LOG: starting point-in-time recovery to 2026-10-29 10:50:51.472525+00
LOG: recovery stopping before commit of transaction 734, time 2026-10-29 10:50:53.6063+00   (le DELETE)
LOG: selected new timeline ID: 2
état restauré : 1500 commandes, total 74269.03   -> OK : identique à T
```

Le dump ne peut ramener qu'à l'heure du dump. Une sauvegarde de base plus l'archivage continu des WAL permet de revenir **à n'importe quelle
seconde** entre la sauvegarde de base et le dernier WAL archivé (RPO de l'ordre de `archive_timeout`). La nouvelle *timeline* (2) évite de
mélanger l'historique restauré avec les WAL de la branche abandonnée. En prod, on utiliserait pgBackRest, WAL-G ou Barman, avec archivage
vers un S3 (voir B2) et des restaurations testées régulièrement.

---

## État laissé sur le poste

| Élément | Commande pour le retirer |
|---|---|
| `shopdata` en PostgreSQL 16 (`shopdata_pgdata16`) et l'ancien volume 14 (`shopdata_pgdata`) conservé pour le retour arrière | `docker compose -f starter/compose.yml -f compose.noports.yml -f compose.pg16.yml down`, puis `docker volume rm shopdata_pgdata` une fois validé |
| Sidecar `backup` dans la stack TP04 (`@daily`) | `docker compose -f compose.yml -f compose.override.yml -f compose.backup.yml rm -sf backup` (dans le TP04) |
| Sauvegardes : `backups/` (TP05) et `../tp04-compose-entreprise/backups/` | Gitignorés. `backups/offsite/age.key` est la clé privée de test |

Les ressources de test (`shop-copy`, `tp05-*` : NFS, Garage, PITR, upgrade, benchmarks) ont toutes été supprimées.
