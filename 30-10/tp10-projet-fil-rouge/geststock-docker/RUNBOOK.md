# RUNBOOK GestStock

## Sauvegarder et restaurer

### Ce qui est sauvegardé

`make backup` (`scripts/backup.sh`) crée `backups/<AAAAMMJJ-HHMMSS>/` :

| Fichier | Contenu |
|---|---|
| `geststock.sql.gz` | `mariadb-dump --single-transaction --routines --events --triggers --databases geststock` : dump cohérent sans arrêter l'appli |
| `uploads.tar.gz` | Le volume `uploads` (photos), lu par un conteneur jetable de l'image de l'app |
| `manifest.json` | Date, nombre d'articles, photos référencées, fichiers du volume, image en service |
| `SHA256SUMS` | Empreintes des trois fichiers |

Les fichiers sont en 0600. Le dump ne contient que la base `geststock`, pas les comptes MariaDB, donc aucun mot de passe.
`KEEP` (7 par défaut) fixe le nombre de sauvegardes gardées sur le serveur.

Planification sur le serveur (cron de l'hôte, 2 h, avec la stack de prod) :

```cron
0 2 * * * deploy cd /srv/geststock && COMPOSE="docker compose -f compose.yml -f compose.prod.yml -f compose.hardened.yml" BACKUP_DIR=/srv/backups ./scripts/backup.sh >> /var/log/geststock-backup.log 2>&1
```

Une sauvegarde qui reste sur le serveur ne protège pas d'une perte du serveur. Il faut copier `/srv/backups` hors de
la machine (rsync vers un autre site ou un stockage objet, règle 3-2-1). C'est l'erreur du legacy : `/backup` sur le
même disque, plein depuis mars.

### Restaurer (incident : données effacées ou corrompues)

1. **Choisir la sauvegarde** : `ls backups/`, puis `cat backups/<horodatage>/manifest.json` (date, nombre d'articles).
2. **Sauvegarder l'état actuel** avant d'écraser quoi que ce soit : `make backup`. Il peut servir à récupérer les saisies
   faites depuis la sauvegarde choisie.
3. **Restaurer** :
   ```bash
   make restore B=backups/<horodatage>
   ```
   En prod, sur le serveur : `COMPOSE="docker compose -f compose.yml -f compose.prod.yml -f compose.hardened.yml" ./scripts/restore.sh /srv/backups/<horodatage>`.
   Le script :
   - vérifie `SHA256SUMS` et refuse une sauvegarde altérée ;
   - demande confirmation (`FORCE=1` pour s'en passer) ;
   - arrête `app` et `rapport`, ce qui évite toute écriture pendant l'opération ;
   - réimporte le dump et remplace le contenu du volume uploads ;
   - relance les services (`--wait`), puis compare le nombre d'articles et de fichiers au manifeste.
4. **Vérifier** : `make test` (smoke test complet), puis un contrôle visuel de la page.

Durée mesurée : **10 s d'interruption** pour 156 articles et 46 photos (`diag/incident-restauration.txt`). La
restauration est la seule opération avec coupure : elle remplace des données, il ne faut donc pas servir pendant ce temps.

### Tester une sauvegarde sans toucher à la prod

```bash
make test-restore            # dernière sauvegarde
./scripts/test-restore.sh backups/<horodatage>
```

Le script restaure dans un projet jetable `geststock-restoretest` (base et app neuves). Il vérifie le nombre d'articles, les
uploads octet par octet, `?health`, la page et le service d'une photo, puis supprime le projet. À lancer après chaque
changement de schéma ou d'image, et au moins une fois par mois : une sauvegarde jamais restaurée n'est pas une sauvegarde.

### Migrer depuis le serveur legacy

1. Sur le legacy, figer les écritures (page de maintenance), puis exporter :
   ```bash
   mysqldump --single-transaction --databases geststock > geststock-legacy.sql
   tar -czf uploads.tar.gz -C /var/www/html/uploads .
   sha256sum geststock-legacy.sql uploads.tar.gz > SHA256SUMS
   ```
2. Copier les trois fichiers sur le nouveau serveur, démarrer la stack, puis lancer :
   ```bash
   make migrate DUMP=geststock-legacy.sql UPLOADS=uploads.tar.gz
   ```
   Le script :
   - vérifie les empreintes, puis fait une sauvegarde de l'état actuel ;
   - importe le dump (MariaDB 10.3 vers 11.4 : dump logique, pas de copie du répertoire de données) ;
   - copie les photos dans le volume, sans changer les droits du dossier ;
   - contrôle que le nombre d'articles est égal au dump et que le contenu des photos est identique à l'export ;
   - liste les photos référencées mais absentes, et les fichiers orphelins (`STRICT=1` pour faire échouer la migration sur
     une photo manquante).
3. Basculer le DNS vers le nouveau Traefik, puis garder le legacy éteint mais intact quelques jours.
