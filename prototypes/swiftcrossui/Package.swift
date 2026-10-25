// swift-tools-version:5.10

// Prototype P1 (phase 0): Music view in SwiftCrossUI, run on macOS, Windows and Linux.
// Throwaway code: see docs/Feuille de route/Prototypes phase 0.md.
//
// The UI backend comes from SwiftCrossUI's DefaultBackend: AppKit on macOS, WinUI on Windows,
// GTK 4 on Linux. Set SCUI_DEFAULT_BACKEND=GtkBackend at build time to force GTK on any OS.

import PackageDescription

let package = Package(
    name: "iPodProMaxProto",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/moreSwift/swift-cross-ui", exact: "0.10.0"),
        // Same version as swift-cross-ui's; needed to hand `Image` the sidebar icons as pixels.
        .package(url: "https://github.com/stackotter/swift-image-formats", exact: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "iPodProMaxProto",
            dependencies: [
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
                .product(name: "ImageFormats", package: "swift-image-formats"),
            ]
        ),
    ]
)
