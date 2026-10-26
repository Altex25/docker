# Politique de tags : registre Shop SAS

## Tags autorisés

| Tag | Exemple | Produit par | Mutable ? | Rétention |
|---|---|---|---|---|
| Version semver | `1.4.3` | `release-gate.sh --push` | **Non, immuable** | Permanente |
| Version mineure / majeure | `1.4`, `1` | Retag après la release | Oui (pointeur vers le dernier patch) | Permanente |
| Build de branche | `main-85ced7e` | CI à chaque merge | **Non** (un commit = un build) | Les N images les plus récentes (`retention.sh`) |
| Pull request | `pr-42` | CI | Oui | Supprimé à la fermeture de la PR, sinon `retention.sh` |
| Signature / attestation | `sha256-<digest>.sig`, `.att` | cosign | Géré par cosign | **Jamais supprimés à la main** |
| `latest` | | | | **Interdit en production** |

Règles :
- Un tag semver publié n'est **jamais** réécrit. Une correction donne une nouvelle version (`1.4.2` → `1.4.3`).
  `release-gate.sh` refuse un push vers un tag semver existant dont le digest diffère. Ni `registry:3` ni
  l'authentification `htpasswd` n'empêchent la réécriture : c'est la porte qui fait respecter la règle (Harbor, ECR, ACR et GAR
  offrent une option « tag immutability » côté registre).
- Un tag de build (`main-<sha>`) et une release peuvent pointer sur le même digest. La rétention supprime alors
  **le tag seul**, jamais le manifeste (sinon la release disparaît).
- Les signatures cosign sont liées au **digest**. Copier une image vers un autre dépôt avec `crane` ou `skopeo` ne copie pas
  sa signature : il faut `cosign copy`.

## Pourquoi `latest` est interdit en production

- **Mobile** : `latest` désigne la dernière image poussée, pas la dernière version validée. Une image réécrite
  le vendredi soir arrive en production au prochain redémarrage de pod, sans changement de configuration.
- **Non traçable** : `docker ps` ou `kubectl describe` affichent `shopapi:latest`. On ne sait pas quel commit tourne, ni
  quand il a changé.
- **Rollback impossible** : « revenir à la version précédente de `latest` » n'a pas de sens.
- **Caches incohérents** : avec `imagePullPolicy: IfNotPresent`, deux nœuds peuvent faire tourner deux `latest` différents.
- **Signature** : on signe un digest. `latest` change de digest à chaque push, donc la vérification échoue
  (ou, pire, porte sur une autre image que celle qui a été auditée).

## Référencer une image par digest

```yaml
services:
  api:
    image: registry.local:5000/shopapi:1.4.3@sha256:e724fbb5406fdb5ee89a782cea7094f6971d9319bcf06adf2d2d6857f7302b3a
```

Quand un digest est présent, il **prime** et le tag n'est plus qu'une indication lisible. Le pull échoue si le contenu
ne correspond pas au digest. Pour obtenir le digest :

```bash
tools/oci.sh gcr.io/go-containerregistry/crane:v0.20.3 digest registry.local:5000/shopapi:1.4.3
```

Les mises à jour se font alors par une modification explicite du fichier (revue, historique git), par exemple via Renovate.

## Retaguer sans pull

```bash
crane tag registry.local:5000/shopapi:1.4.3 1.4
skopeo copy --all --preserve-digests docker://registry.local:5000/shopapi:1.4.3 docker://registry.local:5000/prod/shopapi:1.4.3
cosign copy registry.local:5000/shopapi@sha256:<digest> registry.local:5000/prod/shopapi:1.4.3
```

`crane tag` envoie seulement le manifeste existant sous un nouveau nom (`PUT /v2/<repo>/manifests/<tag>`) : le digest
est inchangé et aucune couche ne transite par le client. Entre deux dépôts du même registre, `skopeo copy` monte les blobs
au lieu de les retélécharger.
