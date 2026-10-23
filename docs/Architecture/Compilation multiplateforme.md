# Compilation multiplateforme

But : **le même code se compile pour chaque OS avec `swift build`**, sans branche ni copie par plateforme.

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
