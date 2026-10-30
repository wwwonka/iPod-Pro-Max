# iPod Pro Max — portable et multiplateforme

Plan directeur pour faire d'iPod Pro Max une app qui **vit sur l'iPod**, se lance depuis **n'importe quel Mac, PC Windows ou Linux**, garde un **look Mac partout**, et reste aussi rapide qu'aujourd'hui. Une seule base de code Swift qui sait se compiler pour les trois OS.

> Statut : plan approuvé le 2026-10-22 ; phase 0 en cours (prototype dans `prototypes/swiftcrossui/`) ; noyau portable et CLI en place depuis le 2026-10-30 (voir [[Package Swift]]). Avancement : [GitHub Project](https://github.com/users/wwwonka/projects/5). Ce vault s'ouvre dans Obsidian via « Open folder as vault » sur `docs/`.

## Commencer ici
- [[Vision]] : objectifs, contraintes, principes de performance
- [[Phases]] : la feuille de route, avec estimation et critères de sortie
- [[Risques]] : ce qui peut faire dérailler le projet
- [[Historique des décisions]] : du plan d'origine au plan actuel, et les options écartées

## Architecture
- [[Modules]] : découpage du code en packages
- [[Compilation multiplateforme]] : un `Package.swift`, trois OS
- [[MediaKit]] : tags, pochettes, transcodage (rapide sur Mac, portable ailleurs)
- [[DeviceKit]] : détection d'iPod, numéro de série USB, éjection
- [[Package Swift]] : ce qui est en place, comment compiler et tester sur les 3 OS, mesures
- [[CLI ipodpromax]] : synchroniser un iPod en ligne de commande, sur les 3 OS

## Données
- [[Sur l'hôte]] : la bibliothèque et les caches restent sur l'ordi
- [[Sur l'iPod]] : l'app, ses outils, les réglages et le manifeste voyagent avec l'iPod
- [[Migration]] : passage depuis Application Support et UserDefaults

## Multi-hôte
- [[Manifeste et propriété des pistes]] : un iPod, plusieurs ordis, aucune piste perdue
- [[Empreinte audio]] : reconnaître la même chanson d'un ordi à l'autre

## Fonctionnalités
- [[Onglet iPod]] : parcourir, modifier, supprimer ce qui est sur l'iPod, façon iTunes

## Interface
- [[Un code, look Mac partout]] : SwiftCrossUI avec AppKit sur Mac et GTK4 ailleurs
- [[Thème GTK Mac]] : la feuille de style qui donne le look Mac sur Windows et Linux
- [[Manques SwiftCrossUI]] : ce qu'il faut ajouter au framework, et ce que le prototype a découvert
- [[Composants natifs par plateforme]] : tableau, sidebar, icônes et fenêtre natifs, derrière une même vue Swift
- [[Sidebar translucide sous Linux]] : sidebar floutée via Blur my Shell ou Hyprland, sans coût pour l'app

## Distribution
- [[Lancement portatif par OS]] : lanceur « shadow copy », Gatekeeper, FAT32
- [[CI et packaging]] : GitHub Actions et assemblage du dossier pour l'iPod
- [[ffmpeg embarqué]] : notre ffmpeg minimal (5 à 12 Mo), livré avec l'app, jamais à installer

## Décisions
- [[ADR-001 Bibliothèque sur l'hôte, données de l'iPod sur l'iPod]]
- [[ADR-002 SwiftCrossUI comme code d'interface unique]]
- [[ADR-003 GTK et thème Mac sur Windows et Linux]]
- [[ADR-004 Caches sur l'hôte]]
- [[ADR-005 FAT32 en mode portatif]]
- [[ADR-006 Noyau portable sans dépendance Apple]]
