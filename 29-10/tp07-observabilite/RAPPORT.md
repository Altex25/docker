# TP07 — Observabilité : logs, métriques, alertes

Environnement : Docker Engine 29.5.2 et Compose v5.1.4 dans une VM Colima (2 CPU, 2 Go, arm64), avec la stack du TP04 en mode dev (`compose.yml` + `compose.override.yml`, projet `shop`). Ni le code ni les images de l'API et du worker n'ont été modifiés.

## Livrables

| Élément | Fichier |
|---|---|
| Stack d'observabilité (projet `observability`) | [`compose.observability.yml`](compose.observability.yml) |
| Config Prometheus, règles d'alerte, tests | [`prometheus/prometheus.yml`](prometheus/prometheus.yml), [`prometheus/rules/shop.yml`](prometheus/rules/shop.yml), [`prometheus/tests/shop.test.yml`](prometheus/tests/shop.test.yml) |
| Config Loki et Promtail | [`loki/loki.yml`](loki/loki.yml), [`promtail/promtail.yml`](promtail/promtail.yml) |
| Grafana provisionné | [`grafana/provisioning/`](grafana/provisioning), dashboard [`grafana/dashboards/shop-overview.json`](grafana/dashboards/shop-overview.json) |
| Alertmanager (bonus B2) | [`alertmanager/alertmanager.yml`](alertmanager/alertmanager.yml) |
| Dashboard sous charge | [`captures/dashboard-sous-charge.png`](captures/dashboard-sous-charge.png) |
| Alertes en état `firing` | [`captures/alertes-firing.png`](captures/alertes-firing.png), [`captures/alertes-firing-prometheus-alerts.png`](captures/alertes-firing-prometheus-alerts.png), et les 4 captures `captures/correlation-*.png` |
| Scripts | [`load.sh`](load.sh) (charge), [`pannes.sh`](pannes.sh) (injection et restauration de pannes), [`captures.sh`](captures.sh) (rendu PNG), [`etape1-logs.sh`](etape1-logs.sh), [`etape2-metriques.sh`](etape2-metriques.sh), [`etape3-verifs.sh`](etape3-verifs.sh), [`alertes.sh`](alertes.sh), [`correlation.sh`](correlation.sh) |
| Transcripts | [`diag/`](diag) |

Lancement :

```bash
docker compose -f compose.observability.yml up -d --wait
./load.sh 1000
open http://localhost:9090/targets http://localhost:3001 http://localhost:9093
```

Accès :
- Grafana : `admin` / `admin` (surchargeable par `GRAFANA_ADMIN_PASSWORD`), aussi exposé via Traefik sur `http://grafana.localhost` ;
- Prometheus, Grafana, Alertmanager et webhook ne sont publiés que sur `127.0.0.1`.

## 1. Les logs côté Docker

Transcript complet : [`diag/etape1-logs.txt`](diag/etape1-logs.txt).

- **Ce que montre `docker logs | jq`.** Les logs pino de l'API sont du JSON par ligne : `{"level":30, "time":…, "req":{…}, "res":{"statusCode":200}, "responseTime":1, "msg":"request completed"}`.
- **Le fichier sur disque.** `docker inspect` donne `{"Type":"json-file","Config":{"max-file":"3","max-size":"10m"}}`, c'est la rotation posée au TP04. Le fichier `/var/lib/docker/containers/<id>/<id>-json.log` de la VM (`root:root`, `0640`) fait **9,0 Mo après 23 h**. Chaque ligne y est ré-encapsulée : `{"log":"{\"level\":30,…}\n","stream":"stdout","time":"…"}`.
- **Le driver `none`.** `docker run --rm --log-driver none alpine echo "pas loggé"` affiche quand même la ligne, car le terminal est attaché directement. En revanche, `docker logs` sur un conteneur `none` renvoie `configured logging driver does not support reading`.

| Expérience (2 000 000 lignes, 130 Mo de texte) | Espace disque | Lignes lisibles par `docker logs` |
|---|---|---|
| `json-file` **sans** `max-size` | **271 768 211 octets** (272 Mo, soit ×2,1 avec l'encapsulation JSON) | 2 000 000 |
| `json-file`, `max-size=1m`, `max-file=3` | 2 747 507 octets (`.log`, `.log.1`, `.log.2`) | 20 219 |
| `local`, `max-size=1m`, `max-file=3` | 1 068 015 octets (`container.log` + 2 `.gz` de 36 Ko) | 32 201 |

| 300 000 lignes, aussi vite que possible | Lignes conservées | Durée |
|---|---|---|
| `mode=blocking` (défaut) | 300 000 / 300 000 | 0,44 s |
| `mode=non-blocking`, `max-buffer-size=4k` | **11 212 / 300 000** | 0,30 s |

**Sans `max-size`, au bout de 6 mois.**
- **Le disque se remplit.** Le fichier `json-file` grossit sans fin. Même au repos, les healthchecks de l'API (Traefik sur `/ready` toutes les 5 s, Docker sur `/health` toutes les 10 s) produisent environ 9 Mo par jour, soit **≈ 1,7 Go en 6 mois** pour ce seul conteneur. Sous trafic réel, on parle de dizaines de Go par conteneur.
- **Tout casse en même temps.** Quand la partition de `/var/lib/docker` est pleine, PostgreSQL ne peut plus écrire son WAL, Redis ne peut plus faire son AOF, et le daemon ne peut plus créer de conteneur ni écrire d'état.
- **`docker logs` devient inutilisable** : il relit tout le fichier.
- **Purger est dangereux.** Supprimer le fichier pendant que le conteneur tourne ne libère rien, car il reste ouvert. Le tronquer avec `truncate -s 0` est un bricolage.
- **La bonne pratique** : une rotation par défaut dans `/etc/docker/daemon.json` (`"log-opts": {"max-size":"10m","max-file":"3"}`), ou le driver `local`, qui tourne par défaut (20 Mo × 5).

**Pourquoi écrire sur stdout/stderr plutôt que dans un fichier.**
- **C'est le contrat 12-factor.** L'application émet un flux, et la plateforme se charge de l'acheminer, de le faire tourner et de l'expédier.
- **Un fichier dans le conteneur pose quatre problèmes** :
  - il grossit la couche inscriptible, ou il faut un volume ;
  - il disparaît avec `docker rm` ;
  - il est invisible pour `docker logs` et pour les collecteurs génériques (Promtail, drivers) ;
  - il oblige à gérer la rotation dans chaque image (`logrotate` + signal), ce qu'une image minimale ne sait pas faire.
- **Sur stdout, tout s'aligne** : la rotation, le format et l'expédition se règlent au même endroit pour tous les conteneurs, et Promtail les collecte tous sans rien connaître des applications.

**Comparaison des drivers.**

| Driver | Stockage / destination | `docker logs` | Points clés |
|---|---|---|---|
| `json-file` | Fichier JSON par ligne sur l'hôte | Oui | Défaut. **Pas de rotation par défaut.** Verbeux (×2,1 mesuré) mais lisible par tous les outils |
| `local` | Fichier binaire (protobuf), rotation compressée | Oui | Rotation par défaut (20 Mo × 5), **2,6× moins de disque** que `json-file` ici, et plus de lignes conservées pour la même taille. Format interne : à ne pas lire directement |
| `journald` | journal systemd de l'hôte | Oui | `journalctl CONTAINER_NAME=…`, métadonnées indexées, rotation gérée par journald. Suppose un hôte systemd |
| `fluentd` | Protocole forward vers Fluentd ou Fluent Bit | Oui, via le cache local (dual logging, Docker ≥ 20.10) | Réseau. Si le collecteur est absent, **le conteneur ne démarre pas**, sauf avec `fluentd-async=true` (prouvé au bonus B1) |
| `awslogs` | CloudWatch Logs | Oui, via le cache local | Identifiants IAM sur l'hôte du **daemon** (pas du conteneur), quotas et coût d'API, région. Pertinent sur EC2 ou ECS |

**`mode: non-blocking` et `max-buffer-size`.**
- **En mode `blocking` (défaut)**, un `write()` sur stdout attend que le driver ait accepté la ligne. Si le driver ralentit (réseau vers Fluentd ou CloudWatch, disque saturé), **l'application est ralentie, voire bloquée** : latence, timeouts, healthchecks en échec.
- **En mode `non-blocking`**, Docker intercale un tampon circulaire en mémoire de `max-buffer-size` (1 Mo par défaut). L'application n'attend jamais, mais **quand le tampon est plein, les lignes sont jetées sans prévenir**. Mesuré ici : 96 % de pertes avec 4 Ko de tampon.
- **Le compromis** est donc entre disponibilité et exhaustivité :
  - `blocking` pour `json-file` et `local`, qui sont locaux et rapides ;
  - `non-blocking` avec un tampon dimensionné (quelques Mo) pour les drivers réseau, en surveillant les pertes ;
  - jamais `non-blocking` pour des logs d'audit.

## 2. Métriques côté Docker

Transcript complet : [`diag/etape2-metriques.txt`](diag/etape2-metriques.txt).

- **`docker stats`** donne, par conteneur, le CPU, la mémoire et la limite, les entrées-sorties réseau et disque, et le nombre de PID. L'usage mémoire affiché est `memory.current − inactive_file` du cgroup v2.
- **`docker system df -v`** :
  - au total : 125 images (23,6 Go, dont 10,5 récupérables), 46 volumes (9,8 Go) et 9,1 Go de cache de build ;
  - `shop_pgdata` occupe 67 Mo ;
  - la couche inscriptible d'`shop-api-1` ne fait que 20,5 Ko : les données sont bien dans les volumes ;
  - en revanche, `shop-adminer-1` écrit **56,8 Mo** dans sa couche (sessions PHP).
- **`docker events --filter type=container`** trace toute la vie d'un conteneur : `oom`, `die`, `start`, `health_status: healthy`, et même la séquence de recréation par Compose (`create 4a2df04bcf1f_shop-api-1`, `stop`, `destroy`, `rename`).
- **Limite mémoire et `load.sh`** : la limite est posée par [`compose.api-64m.yml`](compose.api-64m.yml) (`deploy.resources.limits.memory`). [`load.sh`](load.sh) envoie 70 % de `GET /products`, 15 % de commandes valides, 7 % de commandes avec plus de 100 articles (rejetées par le worker), 4 % de produits inconnus (500, violation de clé étrangère) et 4 % de 404.

| Scénario (6 000 requêtes, 200 en parallèle) | Au repos | Pendant la charge | État final |
|---|---|---|---|
| A. dev (`node --watch`), **64 Mo** | 32,8 / 64 Mio (51 %) | Aucun événement, `memory.events max 0` | Pas d'OOM |
| B. dev (`node --watch`), 40 Mo | 32,3 / 40 Mio (81 %) | Événement `oom`, `max 24`, `oom_kill 1`, et en sortie `Failed running 'src/server.js'` | **`OOMKilled=true` mais `running`, `RestartCount=0`** : l'API est morte, le conteneur ne le sait pas |
| C. image seule (`node src/server.js` en PID 1), **64 Mo** | 21,9 / 64 Mio (34 %) | Aucun événement | Pas d'OOM |
| D. image seule, 24 Mo | 21,9 / 24 Mio (91 %) | `oom`, `die exitCode=137`, `start`, plusieurs fois de suite | `OOMKilled=true`, **`RestartCount=5`**, boucle de redémarrage (`unless-stopped`) |

**À retenir.**
- **64 Mo ne suffisent pas à provoquer d'OOM** avec cette API sous `load.sh`. Node 20 dimensionne son heap d'après la limite du cgroup, et le noyau récupère le cache de pages avant de tuer : `max` peut monter, avec `oom_kill` à 0. Il a fallu descendre à 40 Mo, puis à 24 Mo.
- **L'OOMKill n'a pas le même effet selon le PID 1.**
  - Avec `node src/server.js` en PID 1 (image de prod), le noyau tue le processus principal : `exit 137`, `OOMKilled=true`, et la politique `unless-stopped` relance. C'est le comportement attendu.
  - En dev, le PID 1 est le **superviseur** `node --watch`. C'est l'enfant qui est tué, et le PID 1 survit : le conteneur reste `running`, `RestartCount` reste à 0, et seul le healthcheck finit par le voir. Un PID 1 qui supervise des enfants (watch, `sh -c`, supervisord) masque les crashs à Docker. C'est un argument de plus pour un processus unique en PID 1 en prod.
- **Pendant la boucle, la façade casse aussi.** Traefik répond `404 page not found` (routeur retiré, aucun backend sain) ou 502.

## 3. Stack d'observabilité

```
                     ┌────────────── projet observability ──────────────┐
 shop_back (internal)│ prometheus ──scrape──► cadvisor, loki, promtail,  │
  api ◄── dns_sd ────┤      │                 grafana, alertmanager       │
  worker ◄─ dns_sd ──┤      └─ alertes ─► alertmanager ─► webhook-echo    │
                     │ promtail ── socket Docker ── tous les conteneurs   │
                     │      └─ push ─► loki ◄── grafana ──► prometheus    │
 shop_front ─────────┤ grafana (Host: grafana.localhost via Traefik)      │
                     └───────────────── réseau obs ───────────────────────┘
```

| Service | Image (épinglée par digest) | Rôle |
|---|---|---|
| prometheus | `prom/prometheus:v2.54.1` | Sur les réseaux `obs` et `shop_back`, rétention 7 j, `--web.enable-lifecycle` pour recharger à chaud |
| cadvisor | `ghcr.io/google/cadvisor:v0.60.6` | Métriques CPU, mémoire, réseau, IO et OOM par conteneur, avec les labels `service` et `project` |
| loki | `grafana/loki:3.5.5` | Stockage des logs (TSDB v13 sur disque, rétention 7 j) |
| promtail | `grafana/promtail:3.5.5` | Collecte de **tous** les logs via la socket Docker |
| grafana | `grafana/grafana:11.2.0` | Datasources et dashboard provisionnés, port `127.0.0.1:3001` |
| alertmanager, webhook-echo | `prom/alertmanager:v0.28.1`, `mendhak/http-https-echo:36` | Notifications (bonus B2) |
| renderer (profil `captures`) | `grafana/grafana-image-renderer:3.12.9` | Rendu PNG du dashboard pour les captures |

Tous les services ont un healthcheck, une rotation de logs et `restart: unless-stopped`. `docker compose up --wait` les ramène tous à `healthy`.

**Prometheus.** Le scrape se fait toutes les 10 s.
- **API et worker** sont découverts par `dns_sd_configs` sur `api:3000` et `worker:9100`, avec un rafraîchissement toutes les 10 s.
- **Preuve avec 2 réplicas d'API** :
  - `nslookup -type=a api` renvoie `172.22.0.4` et `172.22.0.9` ;
  - les deux cibles sont `up` ;
  - Traefik les voit toutes deux `UP` ;
  - après 200 appels, Prometheus compte **70 et 73** requêtes `/products` par réplica ([`diag/etape3-verifs.txt`](diag/etape3-verifs.txt)).
- **Un seul réseau commun avec l'API.** Prometheus ne rejoint que `shop_back` parmi les réseaux de la stack. S'il était aussi sur `shop_front`, le DNS embarqué renverrait les IP des deux réseaux, et chaque réplica serait scrapé deux fois.
- **cAdvisor.** Ses labels Compose sont recopiés en `service` et `project` par `metric_relabel_configs`, puis supprimés.

**Pourquoi pas `docker_sd_configs` dans Prometheus ?**
- **Ça ne peut pas marcher tel quel.** `docker exec prometheus id` renvoie `uid=65534(nobody)`, alors que la socket est `srw-rw---- root docker`. Un Prometheus de test avec la socket montée échoue : `permission denied while trying to connect to the Docker daemon socket`.
- **Et il ne faut pas le forcer.** Il faudrait le lancer en root ou dans le groupe `docker`. Or l'accès à la socket équivaut à **root sur l'hôte** : on pourrait lancer un conteneur `--privileged` qui monte `/`. Le donner à un service web exposé (port 9090, API d'administration) multiplie la surface d'attaque.
- **La découverte DNS suffit** : elle suit naturellement les réplicas Compose, sans aucun privilège.
- **Promtail fait l'inverse, en connaissance de cause.** Il tourne en root avec la socket en lecture seule, mais il n'est publié sur aucun port. Le bonus B1 montre une alternative sans socket.

**cAdvisor sur Docker 29.**
- **Le problème.** Les versions habituelles `gcr.io/cadvisor/cadvisor:v0.49.1` et `v0.53.0` ne voient aucun conteneur nommé : `failed to identify the read-write layer ID … /var/lib/docker/image/overlayfs/layerdb/mounts/…`. Docker 29 utilise le stockage d'images containerd (snapshotter), qui n'a plus de `layerdb`.
- **La solution.** La v0.60.6, publiée sur `ghcr.io/google/cadvisor` (plus sur gcr.io), gère ce cas : 56 séries `container_memory_working_set_bytes` nommées, avec les labels Compose.
- **Réglages** :
  - `--store_container_labels=false` et `--whitelisted_container_labels=com.docker.compose.project,com.docker.compose.service` évitent d'exporter tous les labels ;
  - `--enable_metrics=cpu,memory,network,diskIO,oom_event` limite la cardinalité.

**Loki et Promtail.**
- **Collecte.** `docker_sd_configs` découvre tous les conteneurs (19 services et 7 projets vus). Les labels `container`, `service`, `project` et `stream` sont posés depuis les labels Compose.
- **Pour `api` et `worker`** :
  - un étage `json` extrait `level` (`30`/`50` chez pino, `INFO`/`ERROR` côté worker) ;
  - un `template` le normalise en `severity` (`debug`, `info`, `warn`, `error`, `fatal`, et `unknown` pour les lignes non JSON comme une stack trace ou `Failed running`).
- **Pour Traefik**, `DownstreamStatus` devient `status_class` (2xx, 4xx, 5xx).
- **Ingestion.** Au premier démarrage, Promtail relit tout l'historique des conteneurs : Loki a répondu `429 Ingestion rate limit exceeded`. Les limites ont été relevées (`ingestion_rate_mb: 16`, `per_stream_rate_limit: 8MB`).
- **Requêtes du sujet** :
  - `{service="api"} | json | level="50"` renvoie `erreur non gérée : insert or update on table "orders" violates foreign key constraint "orders_product_id_fkey"` ;
  - `{service="worker"} |= "rejected"` renvoie `commande 1793349637849 -> rejected` ;
  - `sum(rate(http_request_duration_seconds_count[1m])) by (status)` renvoie `200 ≈ 4,07`, `201 ≈ 0,73` et `500 ≈ 0,21` req/s.

**Grafana, entièrement provisionné par fichiers.**
- **Datasources** : Prometheus et Loki, avec des `uid` fixes et `readOnly=true`. Les deux répondent `OK` à leur test de santé.
- **Dashboard.** [`shop-overview.json`](grafana/dashboards/shop-overview.json) est provisionné (`provisioned=true`, 22 panneaux, dossier « Shop SAS ») et sert de page d'accueil.
- **Contenu du dashboard** :
  - **stats** : réplicas `up`, req/s, taux de 5xx, p95, alertes en firing, commandes par minute ;
  - **graphiques** : requêtes par statut, latence p50/p95 par route, CPU, mémoire avec la limite en pointillés, réseau, disque, redémarrages et OOM, commandes du worker par statut ;
  - **tableau** des alertes ;
  - **Loki** : volume de logs par service et sévérité, erreurs applicatives (JSON reformaté et stderr brut), 5xx de Traefik reformatés en `POST /orders -> 500 en 19 ms`, logs bruts du service choisi ;
  - **annotations** des redémarrages de conteneurs.
- **Variables** : `$project` et `$service`.

**Alertes** ([`prometheus/rules/shop.yml`](prometheus/rules/shop.yml)). Trois règles d'enregistrement (débit, ratio de 5xx, p95) et sept alertes. Les tests [`promtool test rules`](prometheus/tests/shop.test.yml) passent (`SUCCESS`).

| Alerte | Expression | `for` | Vue `firing` dans |
|---|---|---|---|
| ApiDown | `up{job="api"} == 0 or absent(up{job="api"})` | 30 s | `correlation-memoire-api.png`, et le crash du pool `pg` |
| WorkerDown (ajoutée) | même chose sur `job="worker"` | 30 s | bonus B2 |
| ApiHigh5xxRate | `job:http_5xx_ratio:rate2m > 0.05` | 1 min | `correlation-redis.png` (28 %), `correlation-db-password.png` (44 %) |
| ApiHighLatencyP95 | `job:http_latency_p95:rate2m > 0.5` (hors `/health`, `/ready`, `/metrics`) | 1 min | `alertes-firing*.png` (975 ms), `correlation-latence-db.png` |
| ContainerRestarting | `changes(container_start_time_seconds{name!=""}[10m]) > 0` | — | phase 1 d'`alertes.sh` (worker tué) |
| ContainerOomKilled | `increase(container_oom_events_total{name!=""}[10m]) > 0` | — | `alertes-firing*.png`, `correlation-memoire-api.png` |
| ContainerMemoryNearLimit | `working_set / (limit > 0) > 0.9` | 30 s | `alertes-firing*.png` (`shop-api-1` à 94,9 %) |

**Ce que les essais ont appris sur ces règles.**
- **Le `/ on (id)` de la première version de `ContainerMemoryNearLimit` ne gardait que le label `id`**, donc le nom du conteneur disparaissait. La division sans `on` conserve tous les labels.
- **Le working set redescend sous la limite** dès que la mémoire est récupérable :
  - abaisser une limite juste au-dessus de l'usage affiché par `docker stats` ne déclenche rien, car le noyau reprend le cache de fichiers (adminer redescend à 75 %, l'API à 55 %) ;
  - l'alerte à 90 % ne se déclenche que sur de la mémoire **anonyme** qui grossit ;
  - d'où la panne `fuite-memoire` de [`pannes.sh`](pannes.sh) : un `node -e` lancé par `docker exec` dans le conteneur alloue 1 Mo toutes les 500 ms, et il est gelé par `SIGSTOP` à 95 %.
- **Avec la découverte DNS, une cible arrêtée disparaît au lieu de passer à `up == 0`.** C'est `absent()` qui déclenche, sans label `instance`. Le résumé affiche alors « aucune cible découverte par DNS ».
- **`ContainerRestarting` ne voit que les redémarrages d'un même conteneur.** Une recréation par Compose produit un nouvel `id`, donc une nouvelle série.

**Captures.**
- [`dashboard-sous-charge.png`](captures/dashboard-sous-charge.png) : **313,6 req/s**, 3,9 % de 5xx (les `produit inconnu` de `load.sh`), p95 à 9,9 ms, 2 567 commandes par minute, et l'API à 30 % de CPU.
- [`alertes-firing.png`](captures/alertes-firing.png) et [`alertes-firing-prometheus-alerts.png`](captures/alertes-firing-prometheus-alerts.png) : `ApiHighLatencyP95` (975 ms), `ContainerMemoryNearLimit` (94,9 %) et `ContainerOomKilled` en `firing`, `ApiHigh5xxRate` en `pending`. La séquence est dans [`diag/alertes-firing.txt`](diag/alertes-firing.txt).
- **Fenêtre des captures.** Les PNG sont rendus juste après l'arrêt de la charge, avec une fenêtre de temps qui se termine à cet instant. Sous charge, la VM n'a plus assez de mémoire pour le Chromium du renderer (`Page crashed`).

## 4. Exercice de corrélation

[`correlation.sh <panne>`](correlation.sh) déroule l'exercice en quatre temps :
1. il injecte la panne avec [`pannes.sh`](pannes.sh) et maintient une charge légère pendant 120 s ;
2. il relève ce que Grafana montre (alertes, cibles, statuts, logs par sévérité, mémoire par rapport à la limite, OOM) et fait la capture ;
3. il vérifie avec `docker` ;
4. il restaure.

`./pannes.sh mystere` injecte une panne tirée au hasard, sans l'afficher (la réponse est dans `.panne-mystere`), pour s'entraîner à l'aveugle.

| Panne injectée | Ce que Grafana montre en premier | Hypothèse | Vérification `docker` |
|---|---|---|---|
| **Redis arrêté** (`docker stop`) | `ApiHigh5xxRate` à **28,5 %**, 23 714 réponses 5xx chez Traefik en 2 min. `redis` disparaît de la liste des conteneurs vus par cAdvisor. Logs : `[worker] Error -3 connecting to redis:6379` et `[api] [ioredis] Unhandled error event: getaddrinfo ENOTFOUND redis` | Redis ne tourne plus : son nom DNS n'existe plus. `/ready` répond 503, Traefik retire l'API | `shop-redis-1 Exited (0)`, code 0 : un `docker stop` volontaire, que `unless-stopped` ne relance pas |
| **Mot de passe BDD changé** (`ALTER ROLE`) | `ApiHigh5xxRate` à **44 %**. `[api] erreur non gérée password authentication failed for user "shop"`, et côté `[db]`, `FATAL: password authentication failed` toutes les 5 s | Le secret côté client ne correspond plus au rôle | `docker logs shop-db-1` : mêmes `FATAL` |
| **Limite mémoire abaissée** (`docker update --memory 40m`, puis charge) | `ApiDown`, **0 réplica `up`**. Mémoire de l'API à 13 Mio avec une limite de **40 Mio** (ligne pointillée), barre OOM, `ContainerOomKilled`. stderr : `Failed running 'src/server.js'` | L'enfant de `node --watch` a été tué par le noyau | `OOMKilled=true`, état `running`, `RestartCount=0`, `docker top` n'affiche plus que `node --watch` (le cas B de l'étape 2) |
| **Latence réseau sur la base** (`tc netem delay 600ms`) | `ApiHighLatencyP95` à **972 ms**, sans nouvelle erreur applicative (seulement les 500 habituels de `load.sh`). Le p95 de `/orders` monte à plusieurs secondes (4,3 s sur la capture des alertes), alors que `/products` reste rapide (cache Redis) | Lenteur sur le chemin vers PostgreSQL, puisque seules les routes qui interrogent la base sont touchées | `tc qdisc` montre `netem delay 600ms` sur `eth0`/`eth1` de `shop-db-1`. Connexion TCP de l'API à la base : **610 ms** |

Dans chaque cas, la panne se lit **en moins de deux minutes** sur le dashboard : une alerte, puis le panneau qui la confirme, puis la ligne de log qui la nomme. Les transcripts sont dans [`diag/etape4-correlation-*.txt`](diag), et les captures dans [`captures/correlation-*.png`](captures).

**Bug applicatif découvert.** Avec la première version de la panne mot de passe, qui fermait aussi les connexions existantes par `pg_terminate_backend`, **l'API a planté**. Le `Pool` de `pg` émet un événement `error` quand le serveur coupe une connexion inactive, et l'API n'installe pas de `pool.on('error')` : l'exception non gérée tue le processus. L'enchaînement a été repéré par corrélation :
- `ApiDown` ;
- la sortie stderr de Node (l'objet `Client` affiché) ;
- `Failed running 'src/server.js'`.

Transcript : [`diag/etape4-crash-pool-pg.txt`](diag/etape4-crash-pool-pg.txt), capture : [`crash-pool-pg.png`](captures/crash-pool-pg.png). Une simple bascule ou un redémarrage de PostgreSQL ferait donc tomber l'API. Ce correctif est à remonter aux développeurs : il touche le code, que ce TP ne modifie pas.

**Autre défaut applicatif révélé par l'observabilité.** Le label `route` vaut `req.path` quand aucune route ne correspond. Chaque URL 404 crée donc une nouvelle série Prometheus (`/inconnu-1`, `/inconnu-2`…), soit une **cardinalité non bornée**. Le dashboard filtre les routes connues, mais la correction doit se faire dans l'API : `route="unmatched"` pour les 404.

## Bonus

### B1 — driver de logs `fluentd` vers Fluent Bit, puis Loki

[`bonus/b1-fluentbit.sh`](bonus/b1-fluentbit.sh), [`bonus/compose.b1-fluentbit.yml`](bonus/compose.b1-fluentbit.yml), [`bonus/b1-fluentbit/fluent-bit.conf`](bonus/b1-fluentbit/fluent-bit.conf). Sortie : [`diag/bonus-b1-fluentbit.txt`](diag/bonus-b1-fluentbit.txt).

J'ai choisi Fluent Bit plutôt que le plugin `grafana/loki-docker-driver`. Le plugin s'installe dans le daemon (`docker plugin install --grant-all-permissions`), ce qui modifie le moteur de façon persistante. Fluent Bit est un simple conteneur, et le principe est le même : c'est le daemon qui pousse les logs.

**Ce que montre la démonstration.**
- Un conteneur lancé avec `--log-driver fluentd --log-opt fluentd-address=127.0.0.1:24224 --log-opt labels=com.docker.compose.service,…` voit ses lignes arriver dans Loki. Elles portent les labels `container_name`, `service`, `project` et `source` (stdout ou stderr), plus `detected_level`, que Loki déduit seul.
- `docker logs` fonctionne encore grâce au cache local (dual logging).
- **Collecteur arrêté** : `docker run` échoue avec `failed to initialize logging driver: dial tcp 127.0.0.1:24224: connect: connection refused`.
- **Avec `fluentd-async=true`**, le conteneur démarre, sa ligne « écrite pendant la panne du collecteur » est gardée en mémoire, puis arrive dans Loki quand Fluent Bit revient.

| | Promtail + socket (`docker_sd_configs`) | Driver de logs (Loki ou fluentd) |
|---|---|---|
| Privilèges | Socket Docker en lecture, donc **équivalent root** | Aucun accès à la socket pour le collecteur |
| Configuration | Centralisée, aucun conteneur à modifier | Par conteneur (`--log-driver`, `logging:`) ou dans `daemon.json` (redémarrage du daemon) |
| Panne du collecteur | Les logs restent sur disque (`json-file`), Promtail reprend à sa position | Le conteneur **refuse de démarrer** (synchrone), ou les logs sont gardés en mémoire avec risque de perte (async / `non-blocking`) |
| Couplage | Faible : on peut changer de collecteur à chaud | Le daemon et chaque conteneur dépendent de la destination. Le plugin Loki est réputé bloquer `docker stop` quand Loki est injoignable |
| Logs locaux | Toujours là | Via le cache dual logging uniquement (taille limitée) |
| Enrichissement | Labels Docker, pipeline (json, template, labels) | Ce que le driver transmet (labels choisis). Le pipeline passe dans Fluent Bit |

Pour cette stack, Promtail (ou Grafana Alloy, son successeur) reste le meilleur choix. Le driver se justifie là où l'accès à la socket est interdit, ou pour pousser directement vers un service géré.

Promtail est en fin de vie depuis 2025 au profit de **Grafana Alloy**. La version 3.5.5 est utilisée ici parce que le sujet le demande, mais une migration serait à prévoir (`alloy convert`).

### B2 — Alertmanager et webhook local

Config [`alertmanager/alertmanager.yml`](alertmanager/alertmanager.yml) (intégrée à la stack). Script [`bonus/b2-alertmanager.sh`](bonus/b2-alertmanager.sh), sortie : [`diag/bonus-b2-alertmanager.txt`](diag/bonus-b2-alertmanager.txt).

**Configuration.**
- Prometheus envoie ses alertes à `http://alertmanager:9093/api/v2/alerts`.
- Elles sont regroupées par `alertname` et `service` (`group_wait 10s`, `group_interval 30s`, `repeat_interval 1h`), avec `send_resolved: true`.
- **Règle d'inhibition** : `ApiDown` masque `ApiHigh5xxRate` et `ApiHighLatencyP95` pour le même `job`, pour ne pas recevoir trois notifications pour une seule cause.

**Démonstration.**
1. `docker stop shop-worker-1`. `WorkerDown` passe en `firing`, et le webhook `mendhak/http-https-echo` (sur `127.0.0.1:8085`) reçoit `{"status":"firing","groupLabels":{"alertname":"WorkerDown"}}`.
2. `docker start shop-worker-1`. Il reçoit `{"status":"resolved",…}`.

La charge utile complète contient `receiver`, `groupLabels`, les labels et annotations de l'alerte (« Worker injoignable (aucune cible découverte par DNS) »), `startsAt` et un `generatorURL` qui renvoie vers la requête dans Prometheus.

### B3 — traces OpenTelemetry vers Jaeger, sans changer le code ni l'image

[`bonus/compose.b3-otel.yml`](bonus/compose.b3-otel.yml) (override du projet `shop`), [`bonus/compose.b3-jaeger.yml`](bonus/compose.b3-jaeger.yml), [`bonus/b3-otel.sh`](bonus/b3-otel.sh). Sortie : [`diag/bonus-b3-otel.txt`](diag/bonus-b3-otel.txt), capture : [`b3-trace-jaeger.png`](captures/b3-trace-jaeger.png).

**Le SDK est ajouté sans toucher à l'image.**
- Un conteneur d'initialisation `otel-sdk` (image `node` épinglée) fait `npm install --prefix /otel @opentelemetry/auto-instrumentations-node@0.81.1` dans un volume.
- L'API, toujours `shop/shopapi:dev`, monte ce volume en lecture seule et démarre après lui (`service_completed_successfully`).
- Elle reçoit `NODE_OPTIONS=--require /etc/shop/db-url.cjs --require /otel/node_modules/@opentelemetry/auto-instrumentations-node/build/src/register.js`.
- La configuration passe uniquement par des variables `OTEL_*` : `OTEL_SERVICE_NAME=shopapi`, `OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger:4318`, `OTEL_NODE_ENABLED_INSTRUMENTATIONS=http,express,pg,ioredis,pino`, `OTEL_METRICS_EXPORTER=none`…
- **Jaeger** (`jaegertracing/jaeger:2.10.0`, OTLP natif) rejoint `shop_back` pour être joignable par l'API.

**Résultat.**
- **Une trace `POST /orders` (201)** : `POST /orders` 61 ms, dont `pg-pool.connect` / `pg.connect` 55 ms (ouverture d'une nouvelle connexion du pool), puis `pg.query:INSERT shop` 3 ms et `lpush` 0 ms.
- **Une trace en 500** :
  - `POST /orders` porte `http.response.status_code=500` et `otel.status_code=ERROR` ;
  - `pg.query:INSERT shop` porte `db.query.text=INSERT INTO orders(product_id, quantity, status) VALUES ($1,$2,$3)` et `otel.status_description=… violates foreign key constraint "orders_product_id_fkey"`. La cause est lisible sans ouvrir les logs.
- **Corrélation logs ↔ traces.** L'instrumentation pino ajoute `trace_id` et `span_id` à chaque ligne de log (`{"msg":"request completed","trace_id":"4edc41c8…","status":201}`). Dans Loki, on retrouve donc la trace d'une ligne d'erreur, et inversement.

**Donc, « sans changer le code ? »** Oui, et sans reconstruire l'image : un volume et des variables d'environnement suffisent. Il y a trois limites :
- le SDK est chargé au démarrage, ce qui ajoute une dépendance (le volume) et du temps de démarrage ;
- l'auto-instrumentation ne voit que les bibliothèques connues ;
- en prod, mieux vaut ajouter le SDK à l'image, de façon versionnée et scannée, que de le télécharger au runtime.

Le script remet ensuite l'API sans instrumentation et supprime Jaeger.

### B4 — alerte minimale sans Prometheus

[`bonus/b4-alerte-minimale.sh`](bonus/b4-alerte-minimale.sh), sortie : [`diag/bonus-b4-alerte-minimale.txt`](diag/bonus-b4-alerte-minimale.txt).

À chaque tour (`INTERVAL`), le script surveille quatre choses :
- **`docker stats --no-stream --format json`** : mémoire au-dessus de 90 % de la limite (seulement si une limite existe) et CPU au-dessus de 80 % ;
- **`docker compose top <service>`** : la présence du processus attendu (`node`, `python`, `postgres`, `redis-server`, `traefik`) ;
- **`docker inspect`** : `RestartCount`, `OOMKilled` et `Health.Status` ;
- **ses propres alertes** : chacune est dédupliquée (fichier d'état), notifiée une seule fois, et marquée « RÉSOLU » au retour à la normale. Les notifications partent sur le webhook si `WEBHOOK` est défini.

```text
12:05:29 ALERTE shop-api-1 : mémoire à 95 % de sa limite (153.6MiB / 160MiB)
12:05:45 ALERTE shop-worker-1 : 1 redémarrage(s)
12:05:52 ALERTE service redis : aucun processus redis-server (docker compose top)
12:06:23 RÉSOLU mem-shop-api-1
12:06:23 RÉSOLU proc-redis
```

Les trois alertes ont été reçues par le webhook. Deux pièges ont été rencontrés :
- le bash de macOS est en 3.2, donc sans `declare -A` ;
- `cmd | grep -q` sous `pipefail` donne un faux échec (`SIGPIPE`).

**Limites.** C'est une photo instantanée :
- pas d'historique ni de tendance, donc pas de p95, de taux ou de `for:` ;
- `docker stats` coûte 1 à 2 s par appel ;
- pas de haute disponibilité ni de silences.

Utile comme filet de sécurité sur un hôte isolé, pas comme supervision.

## Écarts et incidents rencontrés

- **Contexte Docker.** La CLI était passée sur le contexte `desktop-linux` (Docker Desktop arrêté). Elle a été remise sur `colima` avec ton accord : `docker context use colima`.
- **Bug Docker : conteneur fantôme `Dead`.** Recréer avec Compose une API en boucle d'OOM (`restart: unless-stopped` + `--force-recreate`) a laissé deux fois un conteneur à l'état `Dead`, ni supprimable ni inspectable (`No such container`). Il bloquait `compose up --wait`.
  - **Remède** : redémarrage du daemon dans la VM, avec ton accord, puis relance manuelle des 4 conteneurs sans politique de redémarrage (`shopdata-db-1`, `avis-stades-*`).
  - **Conséquence** : `ContainerRestarting` s'est déclenché pour tous les conteneurs pendant 10 min. C'est une vraie détection, mais elle a encombré les captures.
  - **Prévention** : [`pannes.sh`](pannes.sh) et [`etape2-metriques.sh`](etape2-metriques.sh) désactivent la politique de redémarrage et arrêtent le conteneur avant de le recréer, et la panne « boucle d'OOM » a été remplacée par `crash` (`kill -9` du PID 1).
- **Images.** cAdvisor vient de `ghcr.io` en v0.60.6 (voir l'étape 3). Le renderer s'appelle `3.12.9`, sans `v`. MinIO n'a pas été nécessaire.
- **Captures.** Elles sont faites par `grafana-image-renderer` (rendu côté serveur, `shm_size: 512m` contre les `Page crashed`) et par `zenika/alpine-chrome` pour la page d'alertes de Prometheus. Cette image n'a pas toutes les polices : certains chiffres de cette page s'affichent mal.
- **État laissé.**
  - La stack `observability` tourne : Prometheus, cAdvisor, Loki, Promtail, Grafana, Alertmanager et le webhook.
  - Le renderer, Jaeger et Fluent Bit sont supprimés.
  - La stack du TP04 est revenue à sa configuration dev : 1 réplica, sans limite mémoire ni `netem`, mot de passe restauré.
  - Pour arrêter l'observabilité : `docker compose -f compose.observability.yml down`. Pour supprimer aussi ses volumes : `down -v`.
