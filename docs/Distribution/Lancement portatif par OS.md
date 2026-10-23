# Lancement portatif par OS

## Le lanceur « shadow copy » (les trois OS)
L'app **ne s'exécute jamais directement depuis l'iPod**. Un petit lanceur :
1. compare `App/version.txt` sur l'iPod à la copie locale dans le cache de l'hôte ;
2. recopie l'app et ses outils si la version a changé (ça n'arrive qu'une fois par mise à jour) ;
3. lance la copie locale en lui passant le chemin du volume de l'iPod.

Ce que ça règle :
- **Éjection** : aucun binaire n'est ouvert sur l'iPod, donc l'OS accepte de l'éjecter (Windows et macOS refusent sinon).
- **Vitesse** : on démarre depuis le SSD, pas depuis le disque dur lent de l'iPod.
- **Linux** : `noexec` et `showexec` sur le FAT32 ne gênent plus.
- **macOS** : plus de translocation (voir plus bas).

## macOS
- `.app` universel (arm64 + x86_64), **signé ad hoc** (pas de certificat payant).
- **Piège :** un zip téléchargé depuis GitHub porte l'attribut de quarantaine. Copié sur FAT32, cet attribut survit dans les fichiers `._`. Sur un autre Mac, ça déclenche Gatekeeper et l'**App Translocation**, qui exécute l'app depuis un chemin aléatoire en lecture seule.
- **Réponse :**
  - le lanceur copie l'app en local et retire `com.apple.quarantine` de la copie (`xattr -dr`) ;
  - l'app trouve l'iPod par le volume monté, jamais par le chemin de son bundle ;
  - au tout premier lancement sur un Mac, l'utilisateur passe par Réglages › Confidentialité › « Ouvrir quand même ». C'est documenté dans un `LISEZMOI` à la racine du dossier.
- Les autorisations TCC (dossier Musique, volumes amovibles) sont redemandées après chaque mise à jour, parce que la signature ad hoc change.

## Windows
- `iPod Pro Max.exe` (sous-système GUI), DLL du runtime Swift et DLL GTK4 et dépendances à côté. Aucune installation requise.
- Pas de Mark-of-the-Web sur FAT32 (pas de flux NTFS alternatif), donc SmartScreen est peu probable une fois l'app sur l'iPod.
- Copie locale dans `%LOCALAPPDATA%\iPod Pro Max\App`.

## Linux
- Binaire avec la stdlib Swift statique. glibc et GTK4 sont liés dynamiquement. On compile sur une vieille distro pour couvrir les récentes.
- udisks2 monte le vfat avec `showexec` : seuls `.exe`, `.com` et `.bat` sont exécutables. On lance donc via `sh lancer.sh`, ou via un `.desktop` à marquer « Autoriser le lancement » la première fois.
- Copie locale dans `~/.cache/ipod-pro-max/app`.

## FAT32
Le mode portatif exige un iPod formaté Windows (FAT32). Voir [[ADR-005 FAT32 en mode portatif]].

Voir aussi [[CI et packaging]] et [[Risques]].
