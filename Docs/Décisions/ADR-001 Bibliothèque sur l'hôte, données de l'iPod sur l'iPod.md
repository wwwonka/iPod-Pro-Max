# ADR-001 Bibliothèque sur l'hôte, données de l'iPod sur l'iPod

> Remplacée le 2026-10-31 par [[ADR-006 Application entièrement portable]] : bibliothèque et caches sur l'iPod, aucune donnée persistante créée sur l'hôte.

- **Statut** : acceptée, le 2026-10-22
- **Contexte** : l'app doit être portable. Mettre toute la bibliothèque sur l'iPod obligerait à lire et écrire sur un disque dur lent et souvent en veille, et à gérer des chemins de fichiers sources qui n'existent que sur un ordi donné.
- **Décision** :
  - la **bibliothèque est liée à l'ordi hôte** et reste sur son disque (voir [[Sur l'hôte]]) ;
  - **sur l'iPod**, on met ce qui concerne l'iPod lui-même : l'app, les outils, les réglages portables, les options de sync, les abonnements podcast et le manifeste de propriété des pistes (voir [[Sur l'iPod]]) ;
  - l'[[Onglet iPod]] permet de voir et gérer le contenu de l'iPod depuis n'importe quel ordi.
- **Conséquences** :
  - réactivité identique à aujourd'hui ;
  - il faut un [[Manifeste et propriété des pistes]] et une [[Empreinte audio]] pour qu'un iPod partagé entre plusieurs ordis ne perde ni ne duplique rien ;
  - une bibliothèque ne suit pas l'utilisateur d'un ordi à l'autre : c'est voulu.
