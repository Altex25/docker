# Exercice Docker #7

Via Docker, créer un conteneur de base de données (de type MySQL) possédant déjà plusieurs tables et données à son lancement.
* Ce conteneur devra être initialisé via un script de type sql contenant l'initialisation de la base de données
* Ce conteneur devra être instancié via une image construite par vos soins

Concernant le contenu de la base de données, celle-ci devra se nommer kennelDB et comporter:
* Des clients (nom, prénom, date de naissance, pseudonymme)
* Des adresses (numéro, rue, code postal, commune)
* Des associations clients-adresses
* Des chiens (nom, date de naissance, race, statut de stérilisation)
* Des chats (nom, date de naissance, race, statut de stérilisation)

```bash
mkdir exercice07
cd exercice07
```

```dockerfile
FROM mysql:8.4

COPY init.sql /docker-entrypoint-initdb.d/init.sql

EXPOSE 3306
```

```bash
docker build -t kennel-mysql .

docker run -d \
  --name kennel-db \
  -e MYSQL_ROOT_PASSWORD=rootpass \
  kennel-mysql

docker logs -f kennel-db
```

```bash
docker exec -it kennel-db mysql -uroot -prootpass kennelDB -e "SHOW TABLES;"

docker exec -it kennel-db mysql -uroot -prootpass kennelDB -e "
  SELECT c.pseudonyme, a.numero, a.rue, a.code_postal, a.commune
  FROM clients c
  JOIN clients_adresses ca ON ca.client_id = c.id
  JOIN adresses a ON a.id = ca.adresse_id;"

docker exec -it kennel-db mysql -uroot -prootpass kennelDB -e "
  SELECT nom, race, sterilise FROM chiens;
  SELECT nom, race, sterilise FROM chats;"
```