# Risques

| Risque | Gravité | Parade |
|---|---|---|
| **Manques de SwiftCrossUI** (Table sans sélection ni tri, pas de glisser-déposer), framework en v0.x | Haute | Prototype P1 ; contribution en amont ; widget natif maison si ça bloque. Voir [[Manques SwiftCrossUI]]. |
| **Fidélité du thème Mac sous GTK** | Moyenne | Prototype P1 ; captures côte à côte ; on vise « Mac-like », pas l'identique. Voir [[Thème GTK Mac]]. |
| **Régression sur Mac** en passant de SwiftUI à AppKitBackend | Moyenne | L'app SwiftUI reste livrée jusqu'à la parité, écran par écran. Voir [[Un code, look Mac partout]]. |
| **Gatekeeper et translocation** sur un Mac hôte | Moyenne | Lanceur « shadow copy » qui retire la quarantaine ; `LISEZMOI`. Voir [[Lancement portatif par OS]]. |
| **FireWire GUID introuvable** hors Mac, donc pas de hash58 | Haute pour les Classic | Numéro de série USB par OS ; repli SCSI INQUIRY. Voir [[DeviceKit]]. |
| **Corruption** si l'iPod est débranché pendant une écriture (FAT32 sans journal) | Moyenne | Fichier temporaire, `fsync`, renommage, `.bak`. Voir [[Sur l'iPod]]. |
| **Limite de 4 Go par fichier** en FAT32 | Faible | Avertir pour les vidéos et livres audio fusionnés plus gros ; découper un livre audio en parties. |
| **Disque dur de l'iPod lent** et en veille | Faible | Rien de l'interface ne lit l'iPod ; écritures groupées. Voir [[ADR-001 Bibliothèque sur l'hôte, données de l'iPod sur l'iPod]]. |
| **yt-dlp qui vieillit** sur l'iPod ; YouTube qui exige un runtime JS | Moyenne | `-U` automatique ; suivre les exigences de yt-dlp. Voir [[CI et packaging]]. |
| **Licence ffmpeg** (GPL avec x264) | Moyenne | Build LGPL ou conformité GPL. Voir [[CI et packaging]]. |
| **Tests matériels** sans PC Windows ni Linux physiques | Moyenne | VM avec passage USB ; un vieux PC de test pour la phase 4. |
| **Licence des SF Symbols** hors des plateformes Apple : la police utilisée sous Linux et Windows est l'œuvre d'Apple, sans licence pour cet usage | Haute si distribuée | Choix de l'utilisateur (2026-10-25) : usage local seulement. Police dans `iPod Pro Max/Resources/Local/` (ignoré par Git), jamais commitée ni livrée. Avant toute distribution : jeu d'icônes libre (Phosphor, Lucide). |
| **Mesures faussées par les VM** (2 vCPU sous Fedora) | Faible | Comparer avec le même code GTK sur le Mac ; tester sur un vrai PC avant de conclure. |
| **Ampleur** : 21–24 semaines | — | Phases livrables séparément ; les phases 1 et 2 ont de la valeur seules. Voir [[Phases]]. |
