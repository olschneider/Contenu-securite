Un JWT (JSON Web Token) est un format de jeton utilisé pour authentifier et échanger des informations de manière sécurisée entre deux parties (client et serveur, par exemple). 
Il est souvent utilisé dans l’authentification des API.
## Structure d’un JWT
Un JWT est composé de trois parties, séparées par des points (.) :

# Header (En-tête) : Contient des informations sur l’algorithme de signature et le type de jeton. Exemple :
json
{
  "alg": "HS256",
  "typ": "JWT"
}
# Payload (Corps du jeton) : Contient les données (claims) comme l’ID utilisateur, le rôle, l’expiration du jeton, etc. Exemple :
json
{
  "sub": "1234567890",
  "name": "John Doe",
  "iat": 1710636800,
  "exp": 1710640400
}
# Signature : Permet de vérifier l’authenticité du JWT. Elle est générée avec un algorithme de hachage (HS256, RS256, etc.), une clé secrète et les deux premières parties du JWT.

Un JWT ressemble à ceci :

eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNzEwNjM2ODAwLCJleHAiOjE3MTA2NDA0MDB9.Qthp0Xg3W8TVPtO2dxE5yV1VPuWFSrR_UyyfwKH17Rk

## Comment fonctionne un JWT ?
Un utilisateur s’authentifie (ex. via un login/mot de passe).
Le serveur génère un JWT signé et le renvoie au client.
Le client stocke ce JWT (généralement dans le stockage local ou un cookie sécurisé).
Pour accéder à une ressource protégée, le client envoie ce JWT dans l’en-tête Authorization de la requête (Bearer <JWT>).
Le serveur vérifie la signature et la validité du JWT avant d’accorder l’accès.
Avantages et inconvénients
✅ Avantages :
Stateless : pas besoin de stocker la session sur le serveur.
Sécurisé (si bien implémenté).
Portable et lisible (base64).
❌ Inconvénients :
Impossible de révoquer un JWT (sauf via une liste noire).
Si mal sécurisé, peut être intercepté et utilisé frauduleusement.
Taille plus grande qu’un simple identifiant de session.
