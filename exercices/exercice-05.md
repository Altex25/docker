# Exercice Docker #5 — MySQL et Adminer

## Objectif

Déployer une base de données MySQL et une interface d'administration web (Adminer) à l'aide de Docker, en utilisant deux conteneurs distincts.

## Travail demandé

1. Créer un réseau Docker dédié à l'exercice.

   ```bash
   docker network create reseau-ex05
   docker volume create mysql-data
   ```

2. Déployer un conteneur **MySQL** avec une base de données et un utilisateur dédiés.

   ```bash
   docker run -d \
     --name mysql-ex05 \
     --network reseau-ex05 \
     --restart unless-stopped \
     -v mysql-data:/var/lib/mysql \
     -e MYSQL_ROOT_PASSWORD=rootpass \
     -e MYSQL_DATABASE=ecole \
     -e MYSQL_USER=alexandre \
     -e MYSQL_PASSWORD=userpass \
     mysql:8.4

   docker logs -f mysql-ex05
   ```

3. Déployer un conteneur **Adminer** permettant d'administrer MySQL depuis un navigateur.

   ```bash
   docker run -d \
     --name adminer-ex05 \
     --network reseau-ex05 \
     --restart unless-stopped \
     -p 8080:8080 \
     adminer
   ```

4. Faire communiquer les deux conteneurs via le réseau Docker.

   ```bash
   docker network inspect reseau-ex05
   ```

5. Se connecter à MySQL depuis Adminer, créer une table et y insérer quelques enregistrements.

   ```sql
   CREATE TABLE etudiants (
     id INT AUTO_INCREMENT PRIMARY KEY,
     nom VARCHAR(50) NOT NULL,
     formation VARCHAR(50)
   );

   INSERT INTO etudiants (nom, formation) VALUES
     ('Alexandre', 'Cloud'),
     ('Camille', 'Dev'),
     ('Lucas', 'Cybersécurité');
   ```

## Contraintes

- Les conteneurs doivent communiquer par leur nom, sans adresse IP fixe.

  ```bash
  docker network inspect reseau-ex05 --format '{{range .Containers}}{{.Name}} {{end}}'
  ```

- Les données MySQL doivent être conservées même après la suppression et la recréation du conteneur.

  ```bash
  docker inspect mysql-ex05 --format '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{end}}'
  ```

- Les conteneurs doivent redémarrer automatiquement en cas d'arrêt inattendu ou de redémarrage de Docker.

  ```bash
  docker inspect mysql-ex05 adminer-ex05 --format '{{.Name}} {{.HostConfig.RestartPolicy.Name}}'
  ```

- Seule l'interface Adminer doit être accessible depuis la machine hôte.

  ```bash
  docker port mysql-ex05     # aucune sortie : MySQL n'est pas exposé
  docker port adminer-ex05
  ```

## Vérifications

- Consulter les enregistrements depuis Adminer.

  ```sql
  SELECT * FROM etudiants;
  ```

- Supprimer puis recréer le conteneur MySQL.

  ```bash
  docker rm -f mysql-ex05

  docker run -d \
    --name mysql-ex05 \
    --network reseau-ex05 \
    --restart unless-stopped \
    -v mysql-data:/var/lib/mysql \
    -e MYSQL_ROOT_PASSWORD=rootpass \
    -e MYSQL_DATABASE=ecole \
    -e MYSQL_USER=alexandre \
    -e MYSQL_PASSWORD=userpass \
    mysql:8.4
  ```

- Vérifier que la table et ses enregistrements sont toujours présents.

  ```bash
  docker volume ls
  ```

  ```sql
  SELECT * FROM etudiants;
  ```

- Simuler une panne d'un conteneur et vérifier son redémarrage automatique.

  ```bash
  docker exec mysql-ex05 kill 1

  docker ps
  docker inspect -f '{{.RestartCount}}' mysql-ex05
  ```

## Bonus

Reproduire le déploiement à l'aide d'un fichier `compose.yaml` pour démarrer les deux services avec une seule commande.

```bash
docker rm -f mysql-ex05 adminer-ex05
```

```yaml
services:
  mysql:
    image: mysql:8.4
    container_name: mysql-ex05
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
      MYSQL_DATABASE: ecole
      MYSQL_USER: alexandre
      MYSQL_PASSWORD: userpass
    volumes:
      - mysql-data:/var/lib/mysql
    networks:
      - reseau-ex05

  adminer:
    image: adminer
    container_name: adminer-ex05
    restart: unless-stopped
    ports:
      - "8080:8080"
    depends_on:
      - mysql
    networks:
      - reseau-ex05

volumes:
  mysql-data:
    external: true

networks:
  reseau-ex05:
    external: true
```

```bash
docker compose up -d
docker compose down
```