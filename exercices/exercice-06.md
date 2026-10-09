# Exercice Docker #6

Via Docker, créer un conteneur utilitaire basé sur une image d'un serveur web.

```bash
docker pull nginx:alpine
```

Ce conteneur aura pour but de permettre le développement d'un site internet sans avoir à installer localement de dépendances ou de librairies.

Il sera possible, via un dossier placé sur notre ordinateur, de coder directement un site web desservi par NGINX (qui lui sera exécuté dans un conteneur).

```bash
mkdir -p exercice06/site
cd exercice06
```

Pour cela, il vous faudra utiliser un type de volume (via l'option de lancement `-v`).

```bash
docker run -d \
  --name dev-nginx \
  -p 8081:80 \
  -v "$(pwd)/site":/usr/share/nginx/html \
  nginx:alpine
```

```bash
docker inspect dev-nginx --format '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}}{{end}}'

curl http://localhost:8081

echo '<p>Modification en direct depuis l hôte</p>' >> site/index.html
curl http://localhost:8081
```