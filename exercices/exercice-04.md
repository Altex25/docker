# Exercice Docker #4

Réaliser, via Docker, le déploiement de deux conteneurs pouvant communiquer entre eux: 

* Pour cela, vous créerez dans un premier temps un réseau qui sera utilisé par les deux conteneurs
```bash
docker network create reseau-ex04
```

* Vous créerez ensuite un conteneur sur lequel vous devrez installer la commande servant à la réalisation du ping
```bash
docker run -it --name conteneur1 --network reseau-ex04 ubuntu bash
apt update && apt install -y iputils-ping
ping -V
exit
```

* Sauvegardez ensuite l'image issue de cette installation pour pouvoir créer un second conteneur directement pourvu de ping
```bash
docker commit conteneur1 ubuntu-ping
```

Création du second conteneur
```bash
docker run -dit --name conteneur2 --network reseau-ex04 ubuntu-ping
```

* Vérifier / connecter les deux conteneurs au même réseau virtuel
```bash
docker start conteneur1
docker start conteneur2
```
* Dans chacun des conteneurs, vérifier la capacité de communiquer avec son voisin via le nom du conteneur (tester la résolution DNS interne à Docker)

```bash
docker network inspect reseau-ex04
```

```bash
docker exec -it conteneur1 ping -c 3 conteneur2
```
```bash
docker exec -it conteneur2 ping -c 3 conteneur1
```