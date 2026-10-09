# Exercice Docker #9

Réaliser deux APIs en Java (via Spring Boot) et les conteneuriser.

## API Logs

L'objectif de cette API est de permettre le stockage et la récupération de logs dans un fichier / une base de données.

Elle possèdera plusieurs endpoints tels que:
* `GET /api/v1/logs`: Récupération de l'ensemble des logs
* `POST /api/v1/logs`: Ajout d'un nouveau log à notre listing

Un logs sera consistué de la sorte:

```json
{
  "message": "string",
  "source": "string",
  "timestamp": "string",
  "level": "string"
}
```

* Le message sera l'erreur retournée par l'API du CRUD
* La source sera une chaine de caractère de type `[CrudAPI] GET /api/v1/chemin/appelle`
* Le timestamp sera l'indicatif de temps du moment où le message d'erreur à été levé par l'API
* Le niveau sera un énum de type `INFO | WARN | ERR` permettant de savoir s'il s'agit d'une erreur ou d'un simple appel ayant retourné un 200

## API CRUD

Cette API devra permettre la réalisation d'un CRUD de base sur une entité de votre choix (pour l'exemple, cela sera des chiens).

Elle offrira plusieurs endpoints, de type:
* `GET /api/v1/dogs`: Listing des chiens
* `GET /api/v1/dogs/{dogId}`: Récupération d'un chien et de ses détails
* `POST /api/v1/dogs`: Ajout d'un nouveau chien à notre base de données
* `PUT /api/v1/dogs/{dogId}`: Edition d'un chien via son ID
* `DELETE /api/v1/dogs/{dogId}`: Suppression d'un chien via son ID

Pour fonctionner, l'API utilisera Hibernate et sera connectée à une base de données de type MySQL / PostgresSQL.

Lors de l'interaction de l'utilisateur avec cette API, des logs seront générés et seront transmis à l'API de logging via un client HTTP (de type RestTemplate en Java donc). Ces logs contiendront des informations, principalement les erreurs générés par l'API de Crud, dans le but de permettre par la suite le monitoring de notre environnement Dockerisé.

La base de données sera également conteneurisée, de sorte à ne pas avoir à installer le moindre SGBD en local.

Pour réaliser cet exercice, il est conseillé de:

* Commencer par créer une base de données via Docker (en la rendant disponible à l'extérieur via le port forwarding)

```bash
docker network create reseau-ex09

docker run -d \
  --name crud-db \
  --network reseau-ex09 \
  --restart unless-stopped \
  -p 3307:3306 \
  -v crud-data:/var/lib/mysql \
  -e MYSQL_ROOT_PASSWORD=rootpass \
  -e MYSQL_DATABASE=dogsdb \
  -e MYSQL_USER=dogs \
  -e MYSQL_PASSWORD=dogspass \
  mysql:8.4

docker run -d \
  --name logs-db \
  --network reseau-ex09 \
  --restart unless-stopped \
  -p 3308:3306 \
  -v logs-data:/var/lib/mysql \
  -e MYSQL_ROOT_PASSWORD=rootpass \
  -e MYSQL_DATABASE=logsdb \
  -e MYSQL_USER=logs \
  -e MYSQL_PASSWORD=logspass \
  mysql:8.4

docker logs -f crud-db
docker logs -f logs-db
```

* Créer un projet de type Java / Spring Boot compatible avec notre système de données (attention au driver à choisir pour Hibernate / JPA)

```bash
mkdir exercice09 && cd exercice09

curl https://start.spring.io/starter.zip \
  -d type=maven-project -d language=java -d javaVersion=21 \
  -d groupId=com.ynov -d artifactId=logs-api -d name=logs-api \
  -d packageName=com.ynov.logsapi \
  -d dependencies=web,data-jpa,mysql,validation \
  -o logs-api.zip

curl https://start.spring.io/starter.zip \
  -d type=maven-project -d language=java -d javaVersion=21 \
  -d groupId=com.ynov -d artifactId=crud-api -d name=crud-api \
  -d packageName=com.ynov.crudapi \
  -d dependencies=web,data-jpa,mysql,validation \
  -o crud-api.zip

unzip logs-api.zip -d logs-api
unzip crud-api.zip -d crud-api
```

* Développer une API en local

```bash
cd logs-api && ./mvnw spring-boot:run

cd crud-api && ./mvnw spring-boot:run
```

```bash
curl -X POST http://localhost:8080/api/v1/dogs \
  -H "Content-Type: application/json" \
  -d '{"name":"Rex","birthDate":"2019-04-10","breed":"Berger allemand","sterilized":true}'

curl http://localhost:8080/api/v1/dogs/999

curl http://localhost:8085/api/v1/logs
```

* Créer le Dockerfile de l'API

* Créer une image de notre API

```bash
docker build -t ex09-logs-api ./logs-api
docker build -t ex09-crud-api ./crud-api
docker images | grep ex09
```

* Relancer l'API via Docker de sorte à en tester son fonctionnement et sa capacité à communiquer avec la BdD

```bash
docker run -d \
  --name logs-api \
  --network reseau-ex09 \
  --restart unless-stopped \
  -p 8085:8085 \
  -e DB_HOST=logs-db \
  -e DB_PORT=3306 \
  ex09-logs-api

docker run -d \
  --name crud-api \
  --network reseau-ex09 \
  --restart unless-stopped \
  -p 8080:8080 \
  -e DB_HOST=crud-db \
  -e DB_PORT=3306 \
  -e LOGS_API_URL=http://logs-api:8085 \
  ex09-crud-api

docker logs -f crud-api
```

```bash
curl -X POST http://localhost:8080/api/v1/dogs \
  -H "Content-Type: application/json" \
  -d '{"name":"Filou","birthDate":"2021-06-02","breed":"Jack Russell","sterilized":false}'
curl http://localhost:8080/api/v1/dogs
curl http://localhost:8080/api/v1/dogs/1
curl -X PUT http://localhost:8080/api/v1/dogs/1 \
  -H "Content-Type: application/json" \
  -d '{"name":"Filou","birthDate":"2021-06-02","breed":"Jack Russell","sterilized":true}'
curl -i -X DELETE http://localhost:8080/api/v1/dogs/1

curl http://localhost:8080/api/v1/dogs/999
curl http://localhost:8080/api/v1/dogs/abc
curl -X POST http://localhost:8080/api/v1/dogs \
  -H "Content-Type: application/json" \
  -d '{"name":"","breed":"Beagle"}'

docker stop crud-db
curl http://localhost:8080/api/v1/dogs
docker start crud-db

curl http://localhost:8085/api/v1/logs
curl "http://localhost:8085/api/v1/logs?level=WARN"
curl "http://localhost:8085/api/v1/logs?level=ERR"

docker exec -it crud-db mysql -udogs -pdogspass dogsdb -e "SELECT * FROM dogs;"
docker exec -it logs-db mysql -ulogs -plogspass logsdb -e "SELECT id, level, source, message FROM logs;"
```