// swift-tools-version:6.0

// Prototype P1 (phase 0): Music view in SwiftCrossUI, run on macOS, Windows and Linux.
// Throwaway code: see docs/Feuille de route/Prototypes phase 0.md.
//
// The UI backend comes from SwiftCrossUI's DefaultBackend: AppKit on macOS, WinUI on Windows,
// GTK 4 on Linux. Set SCUI_DEFAULT_BACKEND=GtkBackend at build time to force GTK on any OS.
//
// iPods come from DeviceKit, the repo's portable core (../../Package.swift). The VMs build from a
// local copy of the prototype and point IPPM_CORE at their local copy of the core.

import PackageDescription

let core = Context.environment["IPPM_CORE"] ?? "../.."

let package = Package(
    name: "iPodProMaxProto",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/moreSwift/swift-cross-ui", exact: "0.10.0"),
        .package(name: "iPodProMax", path: core),
    ],
    targets: [
        .executableTarget(
            name: "iPodProMaxProto",
            dependencies: [
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
                .product(name: "DeviceKit", package: "iPodProMax"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
