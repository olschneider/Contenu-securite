Un JWT (JSON Web Token) est un format de jeton utilisé pour authentifier et échanger des informations de manière sécurisée entre deux parties (client et serveur, par exemple). 
Il est souvent utilisé dans l’authentification des API.
# Structure d’un JWT
Un JWT est composé de trois parties, séparées par des points (.) :

## Header (En-tête)
Contient des informations sur l’algorithme de signature et le type de jeton. Exemple :
json
{
  "alg": "HS256",
  "typ": "JWT"
}
## Payload (Corps du jeton) 
Contient les données (claims) comme l’ID utilisateur, le rôle, l’expiration du jeton, etc. Exemple :
json
{
  "sub": "1234567890",
  "name": "John Doe",
  "iat": 1710636800,
  "exp": 1710640400
}
## Signature 
Permet de vérifier l’authenticité du JWT. Elle est générée avec un algorithme de hachage (HS256, RS256, etc.), une clé secrète et les deux premières parties du JWT.

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

# Les exploitations

## Attaque par modification du JWT (None Algorithm Attack)
Exploit : Certains serveurs mal configurés acceptent un JWT signé avec "alg": "none" (ce qui signifie "pas de signature"). Un attaquant peut donc modifier le payload et créer un JWT valide sans signature.
Exemple :
Un JWT original signé :
json
{
  "alg": "HS256",
  "typ": "JWT"
}
Un attaquant change "alg": "none" et envoie un JWT falsifié qui sera accepté par un serveur mal configuré.

✅ Solution : Toujours refuser les JWT avec "alg": "none" et spécifier explicitement les algorithmes autorisés.  

## Attaque par force brute sur la clé secrète (HS256 Brute Force)
Exploit : Si l’algorithme HS256 (HMAC) est utilisé avec une clé trop simple (123456, secret), un attaquant peut la retrouver par force brute.

Outil : JWT Cracker (ex : jwt_tool, John the Ripper)

✅ Solution :  

Utiliser une clé secrète longue et aléatoire (au moins 256 bits).  
Préférer des algorithmes asymétriques comme RS256 qui nécessitent une clé privée.  

## Attaque par substitution de clé publique (RS256 -> HS256 Switching)  
Exploit : Si le serveur accepte RS256 (clé publique/privée) mais ne valide pas correctement la signature, un attaquant peut leurrer le serveur en lui faisant croire que la clé publique est une clé secrète HMAC.  

Processus :
Le serveur accepte RS256 mais laisse l’attaquant choisir l’algorithme.
L’attaquant change RS256 en HS256 et utilise la clé publique du serveur comme clé HMAC.
Le serveur valide le JWT avec sa propre clé publique et accepte une signature malveillante.
✅ Solution :

Ne jamais permettre de changer l’algorithme d’un JWT une fois configuré.
Stocker la clé publique en dehors du JWT.

## Attaque par réutilisation d’un JWT expiré
Exploit : Si un JWT expiré n’est pas correctement vérifié, un attaquant peut l’utiliser pour accéder à une API.

✅ Solution :

Toujours vérifier le champ "exp" dans le JWT.
Implémenter un mécanisme de liste noire pour invalider un JWT avant expiration (ex : revocation list, stockage en base).

## Vol de JWT via XSS (Cross-Site Scripting)
Exploit : Si un site stocke un JWT dans localStorage, un attaquant peut injecter du code JavaScript malveillant pour voler le JWT et l’utiliser ailleurs.

✅ Solution :

Stocker le JWT dans un cookie sécurisé (HttpOnly, Secure, SameSite=Strict) plutôt qu’en localStorage.
Protéger l’application contre les XSS (ex : Content Security Policy, encodage des entrées utilisateur).

## Vol de JWT via CSRF (Cross-Site Request Forgery)
Exploit : Si un JWT est stocké dans un cookie sans protection, une attaque CSRF peut forcer un utilisateur à envoyer une requête authentifiée à son insu.  

✅ Solution :    

Utiliser le SameSite=Strict sur les cookies.   
Mettre en place des tokens CSRF pour protéger les requêtes critiques.    

