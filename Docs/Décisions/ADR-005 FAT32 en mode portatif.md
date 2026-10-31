# ADR-005 FAT32 en mode portatif

- **Statut** : acceptée, le 2026-10-22
- **Contexte** : un iPod formaté Mac (HFS+) n'est pas lisible par Windows, ni proprement en écriture par Linux. Seul un iPod formaté Windows (FAT32) se monte partout.
- **Décision** : le **mode portatif exige FAT32**. Un iPod HFS+ reste pleinement utilisable en mode installé depuis un Mac. L'app détecte HFS+ et explique comment convertir.
- **Attention, la conversion n'est pas un simple reformatage.** Un iPod Mac utilise une table de partitions APM, et le Finder restaure toujours en format Mac. La conversion passe par une restauration avec iTunes sur Windows, ou par la réécriture de la table de partitions. Dans les deux cas, il faut d'abord sauvegarder la musique, ce que permet « Copier vers la bibliothèque » dans l'[[Onglet iPod]]. C'est un assistant à part, prévu plus tard, pas en phase 6.
- **Conséquences** :
  - limite de 4 Go par fichier (voir [[Risques]]) ;
  - pas de journal, donc des écritures sûres sont nécessaires (voir [[Sur l'iPod]]) ;
  - pas de bit d'exécution, réglé par le lanceur (voir [[Lancement portatif par OS]]).
