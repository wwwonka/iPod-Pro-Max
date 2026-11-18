# ADR-007 — Plug-ins hors processus, rôles orchestrés par le cœur

- Statut : proposée, 2026-11-15, à valider par le propriétaire.
- Détails : [[feature-plugins]].

Tout service externe (Spotify, Soulseek, yt-dlp, et plus tard YouTube Music, Deezer, torrent…) est un plug-in. Un plug-in remplit un ou plusieurs **rôles** (`playlistSource`, `resolver`, `downloader`, `share`, `metadataProvider`, `lyricsProvider`). C'est le **cœur** qui les enchaîne (`SubscriptionEngine`). Spotify et Soulseek sont donc deux plug-ins découplés : n'importe quelle source peut utiliser n'importe quel résolveur.

Un plug-in externe est un dossier avec `plugin.json` et un exécutable par OS. Il dialogue en JSON-RPC 2.0, une ligne par message, sur stdin/stdout, et n'est lancé que le temps d'une opération. Les fournisseurs HTTP légers déjà présents dans MediaKit restent dans le processus, mais respectent les mêmes protocoles de rôle. Les plug-ins et leurs données vivent sur l'iPod (ADR-006). On les distribue sous forme d'archive zip renommée `.ippmplugin`. Un mode développeur charge un dossier non empaqueté.

Raisons : aucun chargement dynamique de bibliothèques à gérer sur 3 OS ; un plug-in qui plante ne fait pas tomber l'app ; les plug-ins peuvent être écrits en d'autres langages ; aucun coût au repos ; yt-dlp est de toute façon un processus externe.

Compromis : il faut sérialiser les échanges (négligeable face au réseau) et lancer un processus par opération (quelques dizaines de ms). Sur Windows, l'app partage ses DLL du runtime Swift avec les plug-ins par le `PATH` du processus enfant.
