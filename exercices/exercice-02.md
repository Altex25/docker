Déployer, au moyen de Docker, une image du jeu 2048:

* Trouver dans le registre d'images de conteneur public DockerHub, une image compatible du jeu 2048
```bash
docker seacrh 20248
```
* Récupérer l'image localement
```bash
docker pull blackicebird/2048 
```
* Lancer un conteneur basé sur l'image de l'application (faire en sorte que celle-ci soit disponible au port hôte 8080, ou 8090 si non disponible)
```bash
docker run -d -p 8090:80 --name jeu-2048 blackicebird/2048
```
* Naviguer, via le navigateur de l'ordinateur (pas via le conteneur) vers http://localhost:8080 et faire en sorte de voir l'application
