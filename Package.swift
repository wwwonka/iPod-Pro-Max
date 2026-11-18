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
    platforms: [.macOS("10.15.4")],
    products: [
        .executable(name: "iPodProMaxApp", targets: ["iPodProMaxApp"]),
        .library(name: "iPodKit", targets: ["iPodKit"]),
        .library(name: "PluginKit", targets: ["PluginKit"]),
        .library(name: "MediaKit", targets: ["MediaKit"]),
        .library(name: "DeviceKit", targets: ["DeviceKit"]),
        .executable(name: "ipodpromax", targets: ["ipodpromax"]),
        .executable(name: "SpotifyPlugin", targets: ["SpotifyPlugin"]),
        .executable(name: "SoulseekPlugin", targets: ["SoulseekPlugin"]),
        .executable(name: "YtDlpPlugin", targets: ["YtDlpPlugin"]),
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
                "iPodKit", "PluginKit", "DeviceKit", "MediaKit",
                .target(name: "CGStreamerPlayback", condition: .when(platforms: [.linux])),
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
            ],
            path: "iPod Pro Max",
            exclude: ["Resources"]
        ),
        .systemLibrary(name: "GStreamer", pkgConfig: "gstreamer-1.0", providers: [.apt(["libgstreamer1.0-dev"])]),
        .target(name: "CGStreamerPlayback", dependencies: ["GStreamer"]),
        .target(name: "iPodKit"),
        .target(name: "PluginKit"),
        .target(
            name: "MediaKit",
            dependencies: [
                "iPodKit",
                "PluginKit",
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
                // SwiftCrossUI lays views out recursively on the main thread: Windows gives it 1 MB
                // of stack (macOS and Linux 8 MB), which the iPod page overflows.
                .unsafeFlags(["-Xlinker", "/STACK:8388608"], .when(platforms: [.windows])),
            ]
        ),
        .executableTarget(name: "ipodpromax", dependencies: ["iPodKit", "PluginKit", "MediaKit", "DeviceKit"]),
        .target(name: "CSockets", linkerSettings: [
            .linkedLibrary("ws2_32", .when(platforms: [.windows])),
        ]),
        .target(name: "CZlib"),
        .executableTarget(
            name: "SpotifyPlugin",
            dependencies: ["PluginKit"],
            path: "Plug-ins/Spotify/Sources/SpotifyPlugin"
        ),
        .executableTarget(
            name: "SoulseekPlugin",
            dependencies: ["PluginKit", "CSockets", "CZlib"],
            path: "Plug-ins/Soulseek/Sources/SoulseekPlugin"
        ),
        .executableTarget(
            name: "YtDlpPlugin",
            dependencies: ["PluginKit"],
            path: "Plug-ins/yt-dlp/Sources/YtDlpPlugin"
        ),
        .testTarget(name: "iPodKitTests", dependencies: ["iPodKit"]),
        .testTarget(name: "PluginKitTests", dependencies: ["PluginKit", "SpotifyPlugin", "SoulseekPlugin", "YtDlpPlugin"]),
        .testTarget(name: "MediaKitTests", dependencies: ["MediaKit", "PluginKit", "iPodKit"]),
    ],
    // Same language mode as the Xcode app; strict concurrency comes with the AppModel work (phase 3).
    swiftLanguageModes: [.v5]
)
