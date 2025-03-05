# Microsoft Identité

## Protocoles
Protocoles d'authentification et d'autorisation conforme à OAUTH v2 et OIDC
Généralement, implique 4 partie:
- Client
- Serveur d'autorisation (= IdP ou fournisseur d'identité)
- Propriétaire de la ressource
- Ressource

## Endpoints 
### OAUTH Autorité
https://login.microsoftonline.com/<tenant_id>
### Authorization endpoint - used by client to obtain authorization from the resource owner.
https://login.microsoftonline.com/<tenant_id>/oauth2/v2.0/authorize
### Token endpoint - used by client to exchange an authorization grant or refresh token for an access token.
https://login.microsoftonline.com/<tenant_id>/oauth2/v2.0/token
