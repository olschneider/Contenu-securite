# Déroulement d'une application JS   

## Framework React  
J'ai pris un exemple simple d'application React avec le framework react-router. On peut retrouver la même logique avec le framework Next JS.  
### L'environnement de dev  
En lancant la commande ```npm run dev```, on lance en fait le script npm qui est décliné dans plusieurs environnement, bash/cmd/powershell.  
Ce script va au final lancer une commande du type ```node.exe <\node_modules\npm\bin\npm-cli.js> suivi des arguments passés à npm```. Dans notre cas, ```node.exe <\node_modules\npm\bin\npm-cli.js> run dev```   
Après plusieurs passage dans des fichiers JS, on lance au final le fichier bin.js provenant du répertoire react-router du projet de développement. Quelque chose comme ```<\@react-router\dev>\bin.js" dev```.
Qui lui même va lancer le JS <Projet>\node_modules\@react-router\dev\dist\cli\index.js.  On est enfin au coeur du lancement du composant maitre qui est le composant Vite qui sert de bundler et de serveur de dev.





