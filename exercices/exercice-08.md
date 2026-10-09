# Exercice Docker #8

Réaliser une API en Java (via Spring Boot) conteneurisée.

Cette API devra permettre la réalisation d'un CRUD de base sur une entité de votre choix (pour l'exemple, cela sera des chiens).

Elle offrira plusieurs endpoints, de type:
* `GET /api/v1/dogs`: Listing des chiens
* `GET /api/v1/dogs/{dogId}`: Récupération d'un chien et de ses détails
* `POST /api/v1/dogs`: Ajout d'un nouveau chien à notre base de données
* `PUT /api/v1/dogs/{dogId}`: Edition d'un chien via son ID
* `DELETE /api/v1/dogs/{dogId}`: Suppression d'un chien via son ID

Pour fonctionner, l'API utilisera Hibernate et sera connectée à une base de données de type MySQL / PostgresSQL.

La base de données sera également conteneurisée, de sorte à ne pas avoir à installer le moindre SGBD en local.

Pour réaliser cet exercice, il est conseillé de:

* Commencer par créer une base de données via Docker (en la rendant disponible à l'extérieur via le port forwarding)

```bash
docker network create reseau-ex08

docker run -d \
  --name dogs-db \
  --network reseau-ex08 \
  --restart unless-stopped \
  -p 3306:3306 \
  -v dogs-data:/var/lib/mysql \
  -e MYSQL_ROOT_PASSWORD=rootpass \
  -e MYSQL_DATABASE=dogsdb \
  -e MYSQL_USER=dogs \
  -e MYSQL_PASSWORD=dogspass \
  mysql:8.4

docker logs -f dogs-db
```

* Créer un projet de type Java / Spring Boot compatible avec notre système de données (attention au driver à choisir pour Hibernate / JPA)

```bash
curl https://start.spring.io/starter.zip \
  -d type=maven-project \
  -d language=java \
  -d javaVersion=21 \
  -d groupId=com.ynov \
  -d artifactId=dogs-api \
  -d name=dogs-api \
  -d packageName=com.ynov.dogsapi \
  -d dependencies=web,data-jpa,mysql,validation \
  -o dogs-api.zip

unzip dogs-api.zip -d dogs-api
cd dogs-api
```

* Développer une API en local

```bash
./mvnw spring-boot:run
```

```bash
curl -X POST http://localhost:8080/api/v1/dogs \
  -H "Content-Type: application/json" \
  -d '{"name":"Rex","birthDate":"2019-04-10","breed":"Berger allemand","sterilized":true}'

curl http://localhost:8080/api/v1/dogs
```

* Créer le Dockerfile de l'API

* Créer une image de notre API

```bash
docker build -t dogs-api .
docker images dogs-api
```

* Relancer l'API via Docker de sorte à en tester son fonctionnement et sa capacité à communiquer avec la BdD

```bash
docker run -d \
  --name dogs-api \
  --network reseau-ex08 \
  --restart unless-stopped \
  -p 8080:8080 \
  -e DB_HOST=dogs-db \
  -e DB_PORT=3306 \
  -e DB_NAME=dogsdb \
  -e DB_USER=dogs \
  -e DB_PASSWORD=dogspass \
  dogs-api

docker logs -f dogs-api
```

```bash
curl http://localhost:8080/api/v1/dogs

curl -X POST http://localhost:8080/api/v1/dogs \
  -H "Content-Type: application/json" \
  -d '{"name":"Filou","birthDate":"2021-06-02","breed":"Jack Russell","sterilized":false}'

curl http://localhost:8080/api/v1/dogs/1

curl -X PUT http://localhost:8080/api/v1/dogs/1 \
  -H "Content-Type: application/json" \
  -d '{"name":"Rex","birthDate":"2019-04-10","breed":"Berger allemand","sterilized":false}'

curl -i -X DELETE http://localhost:8080/api/v1/dogs/1

docker exec -it dogs-db mysql -udogs -pdogspass dogsdb -e "SELECT * FROM dogs;"
```