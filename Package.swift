// swift-tools-version:6.0

// iPod Pro Max: SwiftCrossUI application, portable libraries and command-line tool.
// See Docs/Architecture/Modules.md.
//
//   iPodKit     iTunesDB, ArtworkDB, PhotoDB, Play Counts, hash58, the sync engine. Foundation only.
//   MediaKit    tags, artwork decoding, transcoding: AVFoundation/ImageIO on macOS, pure Swift + ffmpeg elsewhere.
//   DeviceKit   finds, watches, identifies and ejects iPods (one implementation per OS).
//   ipodpromax  command-line tool: list, info, sync <folder>, eject, watch.
//
// The former SwiftUI app in Refs/SwiftUI/ consumes these libraries as a local package.

import PackageDescription

let package = Package(
    name: "iPodProMax",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "iPodProMaxApp", targets: ["iPodProMaxApp"]),
        .library(name: "iPodKit", targets: ["iPodKit"]),
        .library(name: "MediaKit", targets: ["MediaKit"]),
        .library(name: "DeviceKit", targets: ["DeviceKit"]),
        .executable(name: "ipodpromax", targets: ["ipodpromax"]),
    ],
    dependencies: [
        .package(url: "https://github.com/moreSwift/swift-cross-ui", exact: "0.10.0"),
        // JPEG/PNG/WebP decoding and JPEG encoding off macOS (ImageIO does it on the Mac).
        .package(url: "https://github.com/stackotter/swift-image-formats", from: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "iPodProMaxApp",
            dependencies: [
                "iPodKit", "DeviceKit",
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
            ],
            path: "iPod Pro Max",
            exclude: ["Resources"]
        ),
        .target(name: "iPodKit"),
        .target(
            name: "MediaKit",
            dependencies: [
                "iPodKit",
                .product(name: "ImageFormats", package: "swift-image-formats",
                         condition: .when(platforms: [.linux, .windows])),
            ]
        ),
        // Plug and Play (cfgmgr32) helpers in C for DeviceKit on Windows. Empty elsewhere.
        .target(name: "CWinDevices"),
        .target(
            name: "DeviceKit",
            dependencies: ["iPodKit", .target(name: "CWinDevices", condition: .when(platforms: [.windows]))],
            linkerSettings: [
                .linkedFramework("DiskArbitration", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedLibrary("cfgmgr32", .when(platforms: [.windows])),
            ]
        ),
        .executableTarget(name: "ipodpromax", dependencies: ["iPodKit", "MediaKit", "DeviceKit"]),
        .testTarget(name: "iPodKitTests", dependencies: ["iPodKit"]),
        .testTarget(name: "MediaKitTests", dependencies: ["MediaKit", "iPodKit"]),
    ],
    // Same language mode as the Xcode app; strict concurrency comes with the AppModel work (phase 3).
    swiftLanguageModes: [.v5]
)
