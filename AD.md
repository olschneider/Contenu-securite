# Informations sur la securité AD

##Modele d'accès d'entreprise
ref https://learn.microsoft.com/en-us/security/privileged-access-workstations/privileged-access-access-model
Résumé de la relation avec l'ancien modèle de Tiering:
- le Niveau 0 devient le Control Plane et est étendu à tous les aspects du controle d'accès
- le niveau 1: Pour plus de clarté et de facilité d'action, ce qui était le niveau 1 est désormais divisé selon les domaines suivants :
    - Plan de gestion – pour les fonctions de gestion informatique à l’échelle de l’entreprise
    - Plan de données/charge de travail – pour la gestion de chaque charge de travail, qui est parfois effectuée par le personnel informatique et parfois par les unités commerciales
- le niveau 2 est aussi divisé en 2 partie:
    - Accès utilisateur – qui comprend tous les scénarios d’accès B2B, B2C et public
    - Accès aux applications – pour prendre en charge les voies d’accès aux API et la surface d’attaque qui en résulte

## T0
Privileged access security roles typically include:

Microsoft Entra administrator roles
Other identity management roles with administrative rights to an enterprise directory, identity synchronization systems, federation solution, virtual directory, privileged identity/access management system, or similar.
Roles with membership in these on-premises Active Directory groups
Enterprise Admins
Domain Admins
Schema Admin
BUILTIN\Administrators
Account Operators
Backup Operators
Print Operators
Server Operators
Domain Controllers
Read-only Domain Controllers
Group Policy Creator Owners
Cryptographic Operators
Distributed COM Users
Sensitive on-premises Exchange groups (including Exchange Windows Permissions and Exchange Trusted Subsystem)
Other Delegated Groups - Custom groups that may be created by your organization to manage directory operations.
Any local administrator for an underlying operating system or cloud service tenant that is hosting the above capabilities including
Members of local administrators group
Personnel who know the root or built in administrator password
Administrators of any management or security tool with agents installed on those systems