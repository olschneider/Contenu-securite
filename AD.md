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