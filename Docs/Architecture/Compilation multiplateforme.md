# Compilation multiplateforme

But : **le même code se compile pour chaque OS avec `swift build`**, sans branche ni copie par plateforme.

## Compilation actuelle (2026-10-30)

L’application et les modules partagés sont réunis dans le `Package.swift` racine. La cible `iPodProMaxApp` prend ses sources dans `iPod Pro Max/` et utilise `DefaultBackend` : AppKit sur macOS, GTK 4 sur Linux et WinUI sur Windows. Les scripts dans `Tools/Build/` choisissent le backend, appliquent les correctifs et assemblent les livrables dans `Build/`.

```sh
Tools/Build/build.sh mac
Tools/Build/build.sh linux windows
```

L’ancien projet Xcode est conservé dans `Refs/SwiftUI/` et référence le package racine via `../..`. Les copies de compilation locales des VM sont conservées à leurs emplacements existants pour réutiliser les caches ; il n’y a plus de second package d’interface ni de copie séparée du noyau.

## Plan historique

Les sections ci-dessous décrivent la proposition initiale, notamment GTK sur Windows. Elles ne décrivent pas le backend Windows actuel (WinUI).

## Choix du backend d'interface dans `Package.swift`

```swift
.executableTarget(
    name: "App",
    dependencies: [
        "AppUI",
        .product(name: "AppKitBackend", package: "swift-cross-ui",
                 condition: .when(platforms: [.macOS])),
        .product(name: "GtkBackend", package: "swift-cross-ui",
                 condition: .when(platforms: [.linux, .windows])),
    ]
)
```

Dans le point d'entrée, `#if canImport(AppKitBackend)` choisit `AppKitBackend`, sinon `GtkBackend`. Les vues d'`AppUI` ne savent pas sur quel backend elles tournent. Voir [[Un code, look Mac partout]].

## Ce qui varie selon l'OS
- `MediaKitApple` ou `MediaKitPortable` : choisi par condition de plateforme. Voir [[MediaKit]].
- L'implémentation de [[DeviceKit]] : `#if os(macOS) / os(Linux) / os(Windows)`, chacune dans son fichier.
- Les intégrations Mac (Musique, Photos) : `#if os(macOS)`.

## Toolchains
| OS | Toolchain | Notes |
|---|---|---|
| macOS | Xcode / Swift 6.x | Binaire universel arm64 + x86_64, `.app` assemblé par script ou Swift Bundler |
| Linux | swift.org Swift 6.x, image Docker d'une vieille distro (glibc ancienne) | `--static-swift-stdlib` ; GTK4 lié dynamiquement |
| Windows | swift.org Swift 6.x pour Windows | GTK4 via MSYS2 ; DLL du runtime Swift et de GTK copiées à côté du `.exe` |

On développe depuis le Mac. Windows et Linux tournent dans des VM (UTM ou Parallels) avec passage USB de l'iPod pour les tests réels, et en CI pour chaque commit. Voir [[CI et packaging]].

## Transition
1. Phases 1 à 4 : `Package.swift` contient iPodKit, MediaKit, DeviceKit et AppModel. Le projet Xcode actuel les consomme comme package local.
2. Phase 5 : AppUI et App arrivent. Quand la parité est atteinte, l'app Mac livrée passe à la cible SwiftPM, et l'ancienne UI SwiftUI est retirée.

Voir [[Phases]].
