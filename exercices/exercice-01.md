Réaliser une image de conteneur compatible avec NGINX (serveur web):

Pour cela, suivre les étapes suivantes:

Créer un conteneur Ubuntu
Entrer dans le conteneur Ubuntu
```bash
docker run -it --name ubuntu-web ubuntu:latest bash
```

Mettre à jour les paquets dans le conteneur
```bash
apt update && apt upgrade -y
```

Installer NGINX dans le conteneur
```bash
DEBIAN_FRONTEND=noninteractive apt install -y nginx
```

Sortir du conteneur
```bash
exit
```

Sauvegarder l'état actuel du conteneur en tant que nouvelle image nommée par exemple "ubuntu-nginx"
```bash
docker commit \
  --change 'CMD ["nginx", "-g", "daemon off;"]' \
  --change 'EXPOSE 80' \
  ubuntu-web ubuntu-nginx
```

