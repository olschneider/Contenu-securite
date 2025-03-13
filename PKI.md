# Informations sur les PKI
## Elements/roles dans une PKI
- Autorité de certification (CA):  Elle est responsable de la génération, de la validation et de la signature numérique des certificats. Elle définit la politique de certification et les déclarations des pratiques de certification qui décrivent les obligations et les responsabilités des différentes entités de la PKI.
- Autorité d’enregistrement (RA) : L’autorité d’enregistrement est chargée de vérifier l’identité des personnes morales ou personnes physiques, ou personne physique associé à une personne morale ou des équipements informatiques avant de soumettre une demande de certificat à l’AC.
- Autorité de dépôt (Repository) : L’autorité de dépôt est responsable du stockage sécurisé des certificats numériques émis par l’AC. L’autorité de dépôt publie également les listes de révocation (CRL) qui répertorient les certificats révoqués.
- Autorité de séquestre (Key Escrow) : Optionnelle, elle peut être présente dans certains cas où la réglementation exige la rétention sécurisée des clés de chiffrement pour les besoins de déchiffrement ultérieur. L’autorité de séquestre stocke les clés de chiffrement de manière sécurisée. Puis, elle les met à disposition des autorités compétentes, le cas échéant, pour garantir la conformité légale.
- Autorité de validation (VA):
