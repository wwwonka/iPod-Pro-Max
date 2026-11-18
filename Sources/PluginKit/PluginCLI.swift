import Foundation

// MARK: - CLI Verification Runner (PLG-15)

public struct PluginTestCheckResult: Sendable {
    public var name: String
    public var passed: Bool
    public var detail: String

    public init(name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

public struct PluginTestReport: Sendable {
    public var results: [PluginTestCheckResult]

    public var passedCount: Int { results.filter(\.passed).count }
    public var totalCount: Int { results.count }
    public var allPassed: Bool { passedCount == totalCount && totalCount > 0 }

    public init(results: [PluginTestCheckResult]) {
        self.results = results
    }
}

public enum PluginCLI {
    /// Generates a new plug-in skeleton at `folderURL` (`ipodpromax plugin new`).
    public static func createSkeleton(
        name rawName: String,
        id explicitID: String? = nil,
        roles: [PluginRole],
        at folderURL: URL
    ) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: folderURL.path) {
            throw PluginInstallError.io("Directory already exists: \(folderURL.path)")
        }
        guard !roles.isEmpty else {
            throw PluginInstallError.io("At least one --role is required.")
        }

        let cleanName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw PluginInstallError.io("Plug-in name must not be empty.")
        }

        let id = explicitID ?? defaultID(from: cleanName)
        guard ManifestValidator.isValidID(id) else {
            throw PluginInstallError.io("Invalid plug-in id '\(id)': use lowercase letters, digits, and hyphens.")
        }

        let typePrefix = swiftIdentifier(from: cleanName)
        let targetName = "\(typePrefix)Plugin"

        let sourcesDir = folderURL.appendingPathComponent("Sources/\(targetName)", isDirectory: true)
        let testsDir = folderURL.appendingPathComponent("Tests", isDirectory: true)
        try fm.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: testsDir, withIntermediateDirectories: true)

        let manifest = PluginManifest(
            id: id,
            name: cleanName,
            version: "1.0.0",
            apiVersion: 1,
            description: "\(cleanName) plug-in for iPod Pro Max.",
            author: "iPod Pro Max",
            license: "MIT",
            roles: roles.map(\.rawValue),
            executable: [
                "macos": "bin/macos/\(id)-plugin",
                "windows-x64": "bin/windows-x64/\(id)-plugin.exe",
                "windows-arm64": "bin/windows-arm64/\(id)-plugin.exe",
                "linux-x86_64": "bin/linux-x86_64/\(id)-plugin",
                "linux-aarch64": "bin/linux-aarch64/\(id)-plugin",
            ],
            urlPatterns: roles.contains(.playlistSource) ? ["^https?://example\\.com/(playlist|album)/[A-Za-z0-9]+"] : [],
            badge: "badge.svg",
            requiresConsent: roles.contains(.share) ? .p2p : nil,
            settings: [],
            config: [:]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: folderURL.appendingPathComponent("plugin.json"))

        try defaultBadgeSVG.write(to: folderURL.appendingPathComponent("badge.svg"), atomically: true, encoding: .utf8)
        try readmeText(name: cleanName, id: id, targetName: targetName, roles: roles)
            .write(to: folderURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let fixturesData = try buildFixturesJSON(pluginID: id, roles: roles)
        try fixturesData.write(to: testsDir.appendingPathComponent("fixtures.json"))

        let roleSource = buildRoleSwiftSource(typePrefix: typePrefix, pluginID: id, roles: roles)
        try roleSource.write(to: sourcesDir.appendingPathComponent("\(typePrefix)Handler.swift"), atomically: true, encoding: .utf8)

        let mainSource = """
        import Foundation
        import PluginKit

        await PluginMain.run(roles: [\(typePrefix)Handler()], pluginID: "\(id)", version: "1.0.0")
        """
        try mainSource.write(to: sourcesDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
    }

    /// Runs the 8 conformance checks of `ipodpromax plugin test <folder> [--offline]`.
    public static func runConformanceTests(
        folderURL: URL,
        offline: Bool = false,
        platform: PluginPlatform = .current,
        ffmpegPath: String? = nil
    ) async -> PluginTestReport {
        var results: [PluginTestCheckResult] = []
        let fm = FileManager.default

        // 1. Valid manifest
        let manifestURL = folderURL.appendingPathComponent("plugin.json")
        let validated: ValidatedManifest
        do {
            validated = try ManifestValidator.loadAndValidate(from: manifestURL, platform: platform)
            results.append(.init(name: "Manifest valid", passed: true, detail: "\(validated.manifest.id) v\(validated.manifest.version)"))
        } catch {
            results.append(.init(name: "Manifest valid", passed: false, detail: error.localizedDescription))
            return PluginTestReport(results: appendSkipped(to: results, from: 2))
        }
        let manifest = validated.manifest

        // 2. Executable present for current OS
        guard let execRel = validated.executableRelativePath else {
            results.append(.init(
                name: "Executable for \(PluginPlatform.osDisplayName)",
                passed: false,
                detail: "No executable declared for \(PluginPlatform.osDisplayName)"
            ))
            return PluginTestReport(results: appendSkipped(to: results, from: 3))
        }
        let execURL = folderURL.appendingPathComponent(execRel)
        guard fm.fileExists(atPath: execURL.path), fm.isExecutableFile(atPath: execURL.path) else {
            results.append(.init(
                name: "Executable for \(PluginPlatform.osDisplayName)",
                passed: false,
                detail: "Missing or not executable at \(execRel)"
            ))
            return PluginTestReport(results: appendSkipped(to: results, from: 3))
        }
        results.append(.init(name: "Executable for \(PluginPlatform.osDisplayName)", passed: true, detail: execRel))

        let fixturesURL = folderURL.appendingPathComponent("Tests/fixtures.json")
        let fixtures = (try? Data(contentsOf: fixturesURL)).flatMap { try? JSONDecoder().decode(PluginTestFixtures.self, from: $0) }

        let tempRoot = fm.temporaryDirectory.appendingPathComponent("ippm-plugin-test-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        // 3. initialize < 10 s
        let paths = PluginPaths(
            data: tempRoot.appendingPathComponent("data").path,
            cache: tempRoot.appendingPathComponent("cache").path,
            temp: tempRoot.appendingPathComponent("temp").path,
            ffmpeg: ffmpegPath
        )
        let session = TestRPCClient(
            executableURL: execURL,
            workingDir: folderURL,
            extraEnvironment: offline ? [
                "IPPM_PLUGIN_OFFLINE": "1",
                "IPPM_PLUGIN_FIXTURES": fixturesURL.path,
            ] : [:]
        )

        do {
            try session.launch()
            let initParams = try JsonRpcCodec.encodeValue(PluginInitializeParams(
                apiVersion: PluginContract.supportedAPIVersion,
                host: .current(appVersion: "0.1", onIPod: false),
                paths: paths,
                settings: [:],
                config: manifest.config ?? [:]
            ))
            var initObj = initParams.objectValue ?? [:]
            initObj["pluginID"] = .string(manifest.id)
            let start = Date()
            let rawInit = try await session.call(method: "initialize", params: .object(initObj), timeoutSeconds: 10.0)
            let initResult = try JsonRpcCodec.decodeValue(PluginInitializeResult.self, from: rawInit)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            results.append(.init(name: "initialize (< 10 s)", passed: true, detail: "\(ms) ms, roles: \(initResult.roles.joined(separator: ", "))"))
        } catch {
            session.terminate()
            results.append(.init(name: "initialize (< 10 s)", passed: false, detail: error.localizedDescription))
            return PluginTestReport(results: appendSkipped(to: results, from: 4))
        }

        // 4. Role calls with Tests/fixtures.json
        do {
            let summary = try await verifyDeclaredRoles(
                manifest: manifest,
                fixtures: fixtures,
                session: session,
                tempDir: tempRoot.appendingPathComponent("downloads", isDirectory: true)
            )
            results.append(.init(name: "Role checks (fixtures.json)", passed: true, detail: summary))
        } catch {
            results.append(.init(name: "Role checks (fixtures.json)", passed: false, detail: error.localizedDescription))
        }

        // 5. Cancel request returns `cancelled` in < 2 s
        do {
            let cancelResult = try await verifyCancellation(
                manifest: manifest,
                fixtures: fixtures,
                execURL: execURL,
                folderURL: folderURL,
                fixturesURL: fixturesURL,
                paths: paths,
                offline: offline
            )
            results.append(.init(name: "Cancel returns 'cancelled' (< 2 s)", passed: true, detail: cancelResult))
        } catch {
            results.append(.init(name: "Cancel returns 'cancelled' (< 2 s)", passed: false, detail: error.localizedDescription))
        }

        // 6. Badge SVG readable by CustomSymbol / SVGBadgeParser
        if let badgeRel = manifest.badge, !badgeRel.isEmpty {
            let badgeURL = folderURL.appendingPathComponent(badgeRel)
            do {
                let data = try Data(contentsOf: badgeURL)
                let parsed = try SVGBadgeParser.parse(data: data)
                results.append(.init(name: "Badge SVG valid", passed: true, detail: "\(parsed.steps.count) path steps"))
            } catch {
                results.append(.init(name: "Badge SVG valid", passed: false, detail: error.localizedDescription))
            }
        } else {
            results.append(.init(name: "Badge SVG valid", passed: true, detail: "no badge declared"))
        }

        // 7. Clean shutdown
        do {
            _ = try await session.call(method: "shutdown", params: .object([:]), timeoutSeconds: 5.0)
            let code = await session.waitForExit(timeoutSeconds: 2.0)
            if code == 0 {
                results.append(.init(name: "Clean shutdown", passed: true, detail: "exit code 0"))
            } else {
                results.append(.init(name: "Clean shutdown", passed: false, detail: "exit code \(code ?? -1)"))
            }
        } catch {
            session.terminate()
            results.append(.init(name: "Clean shutdown", passed: false, detail: error.localizedDescription))
        }

        // 8. Exits when stdin closes (EOF)
        do {
            let eofSession = TestRPCClient(executableURL: execURL, workingDir: folderURL)
            try eofSession.launch()
            let initParams = try JsonRpcCodec.encodeValue(PluginInitializeParams(
                apiVersion: PluginContract.supportedAPIVersion,
                host: .current(appVersion: "0.1", onIPod: false),
                paths: paths,
                settings: [:],
                config: manifest.config ?? [:]
            ))
            _ = try await eofSession.call(method: "initialize", params: initParams, timeoutSeconds: 5.0)
            eofSession.closeStdin()
            let exited = await eofSession.waitForExit(timeoutSeconds: 3.0)
            if exited != nil {
                results.append(.init(name: "Exits on stdin EOF", passed: true, detail: "exited cleanly"))
            } else {
                eofSession.terminate()
                results.append(.init(name: "Exits on stdin EOF", passed: false, detail: "process stayed alive after stdin closed"))
            }
        } catch {
            results.append(.init(name: "Exits on stdin EOF", passed: false, detail: error.localizedDescription))
        }

        return PluginTestReport(results: results)
    }

    private static func appendSkipped(to current: [PluginTestCheckResult], from step: Int) -> [PluginTestCheckResult] {
        let names = [
            1: "Manifest valid",
            2: "Executable for \(PluginPlatform.osDisplayName)",
            3: "initialize (< 10 s)",
            4: "Role checks (fixtures.json)",
            5: "Cancel returns 'cancelled' (< 2 s)",
            6: "Badge SVG valid",
            7: "Clean shutdown",
            8: "Exits on stdin EOF",
        ]
        var out = current
        for idx in step...8 {
            out.append(.init(name: names[idx] ?? "Check \(idx)", passed: false, detail: "skipped due to earlier failure"))
        }
        return out
    }

    private static func verifyDeclaredRoles(
        manifest: PluginManifest,
        fixtures: PluginTestFixtures?,
        session: TestRPCClient,
        tempDir: URL
    ) async throws -> String {
        guard let fixtures else {
            throw PluginInstallError.io("Missing or invalid Tests/fixtures.json")
        }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        var verified: [String] = []
        var producedCandidate: Candidate?

        for role in manifest.knownRoles {
            switch role {
            case .playlistSource:
                guard let urlStr = fixtures.playlistSource?.url else {
                    throw PluginInstallError.io("fixtures.json missing playlistSource.url")
                }
                let raw = try await session.call(method: "source/fetch", params: .object(["url": .string(urlStr)]), timeoutSeconds: 15.0)
                let decoded = try JsonRpcCodec.decodeValue(PlaylistFetchResult.self, from: raw)
                guard !decoded.playlist.title.isEmpty, !decoded.playlist.revision.isEmpty else {
                    throw PluginInstallError.io("source/fetch returned empty playlist title or revision")
                }
                verified.append("playlistSource(\(decoded.tracks.count) tracks)")

            case .resolver:
                guard let resFix = fixtures.resolver else {
                    throw PluginInstallError.io("fixtures.json missing resolver.track")
                }
                let params = try JsonRpcCodec.encodeValue(ResolverSearchParams(track: resFix.track, policy: resFix.policy ?? QualityPolicy()))
                let raw = try await session.call(method: "resolver/search", params: params, timeoutSeconds: 20.0)
                let decoded = try JsonRpcCodec.decodeValue(ResolverSearchResult.self, from: raw)
                if let first = decoded.candidates.first {
                    producedCandidate = first
                }
                verified.append("resolver(\(decoded.candidates.count) candidates)")

            case .downloader:
                guard let candidate = fixtures.downloader?.candidate ?? producedCandidate else {
                    throw PluginInstallError.io("fixtures.json missing downloader.candidate")
                }
                let params = try JsonRpcCodec.encodeValue(DownloaderDownloadParams(candidate: candidate, destinationDir: tempDir.path))
                let raw = try await session.call(method: "downloader/download", params: params, timeoutSeconds: 30.0)
                let decoded = try JsonRpcCodec.decodeValue(DownloaderDownloadResult.self, from: raw)
                guard FileManager.default.fileExists(atPath: decoded.path) else {
                    throw PluginInstallError.io("downloader/download returned non-existent file '\(decoded.path)'")
                }
                verified.append("downloader")

            case .share:
                let shareFix = fixtures.share ?? ShareFixture(entries: [], uploadSlots: 2)
                let params = try JsonRpcCodec.encodeValue(ShareSetIndexParams(
                    part: 0, lastPart: true, entries: shareFix.entries, uploadSlots: shareFix.uploadSlots ?? 2
                ))
                _ = try await session.call(method: "share/setIndex", params: params, timeoutSeconds: 10.0)
                _ = try await session.call(method: "share/stop", params: .object([:]), timeoutSeconds: 5.0)
                verified.append("share")

            case .metadataProvider:
                guard let query = fixtures.metadataProvider?.query else {
                    throw PluginInstallError.io("fixtures.json missing metadataProvider.query")
                }
                let params = try JsonRpcCodec.encodeValue(query)
                let raw = try await session.call(method: "metadata/search", params: params, timeoutSeconds: 15.0)
                let decoded = try JsonRpcCodec.decodeValue(MetadataSearchResult.self, from: raw)
                verified.append("metadataProvider(\(decoded.matches.count) matches)")

            case .lyricsProvider:
                guard let query = fixtures.lyricsProvider?.query else {
                    throw PluginInstallError.io("fixtures.json missing lyricsProvider.query")
                }
                let params = try JsonRpcCodec.encodeValue(query)
                let raw = try await session.call(method: "lyrics/fetch", params: params, timeoutSeconds: 15.0)
                _ = try JsonRpcCodec.decodeValue(LyricsFetchResult.self, from: raw)
                verified.append("lyricsProvider")
            }
        }
        return verified.joined(separator: ", ")
    }

    private static func verifyCancellation(
        manifest: PluginManifest,
        fixtures: PluginTestFixtures?,
        execURL: URL,
        folderURL: URL,
        fixturesURL: URL,
        paths: PluginPaths,
        offline: Bool
    ) async throws -> String {
        var env: [String: String] = ["IPPM_PLUGIN_TEST_CANCEL": "1"]
        if offline {
            env["IPPM_PLUGIN_OFFLINE"] = "1"
            env["IPPM_PLUGIN_FIXTURES"] = fixturesURL.path
        }
        let client = TestRPCClient(executableURL: execURL, workingDir: folderURL, extraEnvironment: env)
        try client.launch()
        defer { client.terminate() }

        let initParams = try JsonRpcCodec.encodeValue(PluginInitializeParams(
            apiVersion: PluginContract.supportedAPIVersion,
            host: .current(appVersion: "0.1", onIPod: false),
            paths: paths,
            settings: [:],
            config: manifest.config ?? [:]
        ))
        _ = try await client.call(method: "initialize", params: initParams, timeoutSeconds: 5.0)

        let (method, params): (String, JSONValue) = {
            if manifest.knownRoles.contains(.playlistSource), let url = fixtures?.playlistSource?.url {
                return ("source/fetch", .object(["url": .string(url)]))
            }
            if manifest.knownRoles.contains(.resolver), let res = fixtures?.resolver {
                return ("resolver/search", (try? JsonRpcCodec.encodeValue(ResolverSearchParams(track: res.track, policy: res.policy))) ?? .object([:]))
            }
            if manifest.knownRoles.contains(.downloader), let cand = fixtures?.downloader?.candidate {
                return ("downloader/download", (try? JsonRpcCodec.encodeValue(DownloaderDownloadParams(candidate: cand, destinationDir: paths.temp))) ?? .object([:]))
            }
            if manifest.knownRoles.contains(.metadataProvider), let q = fixtures?.metadataProvider?.query {
                return ("metadata/search", (try? JsonRpcCodec.encodeValue(q)) ?? .object([:]))
            }
            if manifest.knownRoles.contains(.lyricsProvider), let q = fixtures?.lyricsProvider?.query {
                return ("lyrics/fetch", (try? JsonRpcCodec.encodeValue(q)) ?? .object([:]))
            }
            return ("share/setIndex", (try? JsonRpcCodec.encodeValue(ShareSetIndexParams(part: 0, lastPart: true, entries: [], uploadSlots: 1))) ?? .object([:]))
        }()

        let start = Date()
        let reqID = client.sendRequest(method: method, params: params)
        try? await Task.sleep(nanoseconds: 20_000_000)
        client.sendCancel(id: reqID)
        let response = try await client.awaitResponse(id: reqID, timeoutSeconds: 2.0)
        let ms = Int(Date().timeIntervalSince(start) * 1000)

        if let err = response.error, err.data?.code == PluginErrorCode.cancelled.rawValue {
            return "\(ms) ms"
        }
        if let err = response.error {
            throw PluginInstallError.io("Expected error code 'cancelled', got '\(err.data?.code ?? "none")' (\(err.message))")
        }
        throw PluginInstallError.io("Request completed normally instead of returning 'cancelled'")
    }

    // MARK: - Skeleton Templates

    private static func defaultID(from name: String) -> String {
        let lower = name.lowercased()
        var out = ""
        var lastHyphen = false
        for scalar in lower.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                out.append(Character(scalar))
                lastHyphen = false
            } else if !lastHyphen && !out.isEmpty {
                out.append("-")
                lastHyphen = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func swiftIdentifier(from name: String) -> String {
        let parts = name.split { !$0.isLetter && !$0.isNumber }
        let joined = parts.map { part in
            guard let first = part.first else { return "" }
            return first.uppercased() + part.dropFirst()
        }.joined()
        return joined.isEmpty ? "Custom" : joined
    }

    private static let defaultBadgeSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
      <path d="M 12 3 L 21 12 L 12 21 L 3 12 Z"/>
    </svg>
    """

    private static func readmeText(name: String, id: String, targetName: String, roles: [PluginRole]) -> String {
        """
        # \(name) Plug-in

        ID: `\(id)`
        Roles: \(roles.map(\.rawValue).joined(separator: ", "))

        ## Development

        1. Implement the role method(s) in `Sources/\(targetName)/\(typePrefix(name))Handler.swift`.
        2. Update `urlPatterns`, `badge.svg`, and `Tests/fixtures.json`.
        3. Add the executable target `\(targetName)` to the root `Package.swift`.
        4. Build and verify:

        ```sh
        swift build --product \(targetName)
        mkdir -p Plug-ins/\(name)/bin/macos
        cp .build/debug/\(targetName) Plug-ins/\(name)/bin/macos/\(id)-plugin
        swift run ipodpromax plugin test Plug-ins/\(name) --offline
        swift run ipodpromax plugin pack Plug-ins/\(name)
        ```
        """
    }

    private static func typePrefix(_ name: String) -> String { swiftIdentifier(from: name) }

    private static func buildFixturesJSON(pluginID: String, roles: [PluginRole]) throws -> Data {
        var fixtures = PluginTestFixtures()
        if roles.contains(.playlistSource) {
            fixtures.playlistSource = PlaylistSourceFixture(
                url: "https://example.com/playlist/123",
                offlineResponse: PlaylistFetchResult(
                    playlist: Playlist(source: pluginID, sourceID: "123", title: "Sample Playlist", owner: "Tester", revision: "rev-1"),
                    tracks: [
                        TrackRef(source: pluginID, sourceID: "t1", title: "Sample Track", artists: ["Sample Artist"], album: "Sample Album", durationMs: 180_000)
                    ]
                )
            )
        }
        if roles.contains(.resolver) {
            fixtures.resolver = ResolverFixture(
                track: TrackRef(source: "spotify", sourceID: "t1", title: "Sample Track", artists: ["Sample Artist"], album: "Sample Album", durationMs: 180_000),
                policy: QualityPolicy(),
                offlineResponse: [
                    Candidate(resolver: pluginID, token: "tok-1", displayName: "Sample Artist - Sample Track.flac", title: "Sample Track", artist: "Sample Artist", album: "Sample Album", durationMs: 180_000, container: "flac", bitrateKbps: 1000, hint: 0.9)
                ]
            )
        }
        if roles.contains(.downloader) {
            fixtures.downloader = DownloaderFixture(
                candidate: Candidate(resolver: pluginID, token: "tok-1", displayName: "Sample Artist - Sample Track.flac", container: "flac")
            )
        }
        if roles.contains(.share) {
            fixtures.share = ShareFixture(entries: [], uploadSlots: 2)
        }
        if roles.contains(.metadataProvider) {
            fixtures.metadataProvider = MetadataFixture(query: MetadataQuery(title: "Sample Track", artist: "Sample Artist"))
        }
        if roles.contains(.lyricsProvider) {
            fixtures.lyricsProvider = LyricsFixture(query: LyricsQuery(title: "Sample Track", artist: "Sample Artist", durationSeconds: 180))
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(fixtures)
    }

    private static func buildRoleSwiftSource(typePrefix: String, pluginID: String, roles: [PluginRole]) -> String {
        var conformances = ["PluginConfigurable"]
        if roles.contains(.playlistSource) { conformances.append("PlaylistSource") }
        if roles.contains(.resolver) { conformances.append("Resolver") }
        if roles.contains(.downloader) { conformances.append("Downloader") }
        if roles.contains(.share) { conformances.append("ShareProvider") }
        if roles.contains(.metadataProvider) { conformances.append("MetadataLookupProvider") }
        if roles.contains(.lyricsProvider) { conformances.append("LyricsLookupProvider") }

        var methods = """
            func initialize(params: PluginInitializeParams, context: PluginRuntimeContext) async throws {
                // Store paths/config/settings if needed.
            }

            func settingsChanged(_ settings: [String: JSONValue]) async {
                // React to live settings updates from Preferences.
            }

            private func waitIfCancelTest() async throws {
                if ProcessInfo.processInfo.environment["IPPM_PLUGIN_TEST_CANCEL"] != nil {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }

            private func loadFixtures() -> PluginTestFixtures? {
                guard ProcessInfo.processInfo.environment["IPPM_PLUGIN_OFFLINE"] != nil,
                      let path = ProcessInfo.processInfo.environment["IPPM_PLUGIN_FIXTURES"],
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                    return nil
                }
                return try? JSONDecoder().decode(PluginTestFixtures.self, from: data)
            }
        """

        if roles.contains(.playlistSource) {
            methods += """

                func fetch(url: URL) async throws -> PlaylistFetchResult {
                    try await waitIfCancelTest()
                    if let offline = loadFixtures()?.playlistSource?.offlineResponse {
                        return offline
                    }
                    throw PluginError(code: .unsupported, message: "Implement fetch(url:) for \(pluginID)")
                }
            """
        }
        if roles.contains(.resolver) {
            methods += """

                func search(
                    track: TrackRef,
                    policy: QualityPolicy,
                    onPartialCandidates: @escaping @Sendable ([Candidate]) async -> Void
                ) async throws -> [Candidate] {
                    try await waitIfCancelTest()
                    if let offline = loadFixtures()?.resolver?.offlineResponse {
                        await onPartialCandidates(offline)
                        return offline
                    }
                    throw PluginError(code: .unsupported, message: "Implement search(track:policy:) for \(pluginID)")
                }
            """
        }
        if roles.contains(.downloader) {
            methods += """

                func download(
                    candidate: Candidate,
                    destinationDir: URL,
                    onProgress: @escaping @Sendable (PluginProgress) async -> Void
                ) async throws -> URL {
                    try await waitIfCancelTest()
                    if ProcessInfo.processInfo.environment["IPPM_PLUGIN_OFFLINE"] != nil {
                        let out = destinationDir.appendingPathComponent("offline-sample.\\(candidate.container)")
                        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
                        try Data("offline".utf8).write(to: out)
                        await onProgress(PluginProgress(done: 1, total: 1, message: "Done"))
                        return out
                    }
                    throw PluginError(code: .unsupported, message: "Implement download(candidate:destinationDir:) for \(pluginID)")
                }
            """
        }
        if roles.contains(.share) {
            methods += """

                func setIndex(entries: [ShareIndexEntry], uploadSlots: Int) async throws {
                    try await waitIfCancelTest()
                }

                func stop() async throws {}
            """
        }
        if roles.contains(.metadataProvider) {
            methods += """

                let name = "\(pluginID)"
                func search(query: MetadataQuery) async throws -> [MetadataMatch] {
                    try await waitIfCancelTest()
                    return []
                }
            """
        }
        if roles.contains(.lyricsProvider) {
            methods += """

                func fetchLyrics(query: LyricsQuery) async throws -> LyricsMatch? {
                    try await waitIfCancelTest()
                    return nil
                }
            """
        }

        return """
        import Foundation
        import PluginKit

        actor \(typePrefix)Handler: \(conformances.joined(separator: ", ")) {
        \(methods)
        }
        """
    }
}

// MARK: - Fixtures Schema

public struct PlaylistSourceFixture: Codable, Sendable {
    public var url: String
    public var offlineResponse: PlaylistFetchResult?
    public init(url: String, offlineResponse: PlaylistFetchResult? = nil) {
        self.url = url
        self.offlineResponse = offlineResponse
    }
}

public struct ResolverFixture: Codable, Sendable {
    public var track: TrackRef
    public var policy: QualityPolicy?
    public var offlineResponse: [Candidate]?
    public init(track: TrackRef, policy: QualityPolicy? = nil, offlineResponse: [Candidate]? = nil) {
        self.track = track
        self.policy = policy
        self.offlineResponse = offlineResponse
    }
}

public struct DownloaderFixture: Codable, Sendable {
    public var candidate: Candidate
    public init(candidate: Candidate) { self.candidate = candidate }
}

public struct ShareFixture: Codable, Sendable {
    public var entries: [ShareIndexEntry]
    public var uploadSlots: Int?
    public init(entries: [ShareIndexEntry], uploadSlots: Int? = nil) {
        self.entries = entries
        self.uploadSlots = uploadSlots
    }
}

public struct MetadataFixture: Codable, Sendable {
    public var query: MetadataQuery
    public init(query: MetadataQuery) { self.query = query }
}

public struct LyricsFixture: Codable, Sendable {
    public var query: LyricsQuery
    public init(query: LyricsQuery) { self.query = query }
}

public struct PluginTestFixtures: Codable, Sendable {
    public var playlistSource: PlaylistSourceFixture?
    public var resolver: ResolverFixture?
    public var downloader: DownloaderFixture?
    public var share: ShareFixture?
    public var metadataProvider: MetadataFixture?
    public var lyricsProvider: LyricsFixture?

    public init(
        playlistSource: PlaylistSourceFixture? = nil,
        resolver: ResolverFixture? = nil,
        downloader: DownloaderFixture? = nil,
        share: ShareFixture? = nil,
        metadataProvider: MetadataFixture? = nil,
        lyricsProvider: LyricsFixture? = nil
    ) {
        self.playlistSource = playlistSource
        self.resolver = resolver
        self.downloader = downloader
        self.share = share
        self.metadataProvider = metadataProvider
        self.lyricsProvider = lyricsProvider
    }
}

// MARK: - Lightweight RPC Test Client for `plugin test`

private final class TestRPCClient: @unchecked Sendable {
    private let executableURL: URL
    private let workingDir: URL
    private let extraEnvironment: [String: String]
    private let process = Process()
    private var stdinHandle: FileHandle?
    private let lock = NSLock()
    private var nextID = 1
    private var stdoutBuffer = Data()
    private var responses: [String: JsonRpcEnvelope] = [:]
    private var waiters: [String: CheckedContinuation<JsonRpcEnvelope, Error>] = [:]
    private var exitWaiters: [CheckedContinuation<Int32?, Never>] = []
    private var terminated = false
    private var exitCode: Int32?

    init(executableURL: URL, workingDir: URL, extraEnvironment: [String: String] = [:]) {
        self.executableURL = executableURL
        self.workingDir = workingDir
        self.extraEnvironment = extraEnvironment
    }

    func launch() throws {
        process.executableURL = executableURL
        process.currentDirectoryURL = workingDir
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnvironment { env[k] = v }
        process.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            self?.receiveStdout(h.availableData)
        }
        process.terminationHandler = { [weak self] p in
            outPipe.fileHandleForReading.readabilityHandler = nil
            self?.handleExit(p.terminationStatus)
        }
        try process.run()
        stdinHandle = inPipe.fileHandleForWriting
    }

    func sendRequest(method: String, params: JSONValue) -> JsonRpcID {
        lock.lock()
        let num = nextID
        nextID += 1
        lock.unlock()
        let id = JsonRpcID.int(num)
        let env = JsonRpcEnvelope(id: id, method: method, params: params)
        if let line = try? JsonRpcCodec.encodeLine(env) {
            try? write(line)
        }
        return id
    }

    func sendCancel(id: JsonRpcID) {
        let val: JSONValue = switch id {
        case .int(let i): .int(i)
        case .string(let s): .string(s)
        }
        let env = JsonRpcEnvelope(method: "$/cancelRequest", params: .object(["id": val]))
        if let line = try? JsonRpcCodec.encodeLine(env) {
            try? write(line)
        }
    }

    func awaitResponse(id: JsonRpcID, timeoutSeconds: Double) async throws -> JsonRpcEnvelope {
        let key = id.stringKey
        return try await withThrowingTaskGroup(of: JsonRpcEnvelope.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.lock()
                    if let existing = self.responses.removeValue(forKey: key) {
                        self.lock.unlock()
                        cont.resume(returning: existing)
                    } else if self.terminated {
                        self.lock.unlock()
                        cont.resume(throwing: PluginError(code: .pluginCrashed, message: "Plug-in exited before responding"))
                    } else {
                        self.waiters[key] = cont
                        self.lock.unlock()
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw PluginError(code: .startTimeout, message: "Timed out after \(Int(timeoutSeconds)) s")
            }
            guard let first = try await group.next() else {
                throw PluginError(code: .startTimeout, message: "Timed out")
            }
            group.cancelAll()
            return first
        }
    }

    func call(method: String, params: JSONValue, timeoutSeconds: Double) async throws -> JSONValue {
        let id = sendRequest(method: method, params: params)
        let env = try await awaitResponse(id: id, timeoutSeconds: timeoutSeconds)
        if let err = env.error {
            let code = err.data.flatMap { PluginErrorCode(rawValue: $0.code) } ?? .internal
            throw PluginError(code: code, message: err.message, retryAfterSeconds: err.data?.retryAfterSeconds)
        }
        return env.result ?? .object([:])
    }

    func closeStdin() {
        try? stdinHandle?.close()
        stdinHandle = nil
    }

    func waitForExit(timeoutSeconds: Double) async -> Int32? {
        await withTaskGroup(of: Int32?.self) { group in
            group.addTask {
                await withCheckedContinuation { cont in
                    self.lock.lock()
                    if self.terminated {
                        let code = self.exitCode
                        self.lock.unlock()
                        cont.resume(returning: code)
                    } else {
                        self.exitWaiters.append(cont)
                        self.lock.unlock()
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func terminate() {
        closeStdin()
        if process.isRunning { process.terminate() }
    }

    private func write(_ data: Data) throws {
        guard let stdinHandle else { return }
        if #available(macOS 10.15.4, *) {
            try stdinHandle.write(contentsOf: data)
        } else {
            stdinHandle.write(data)
        }
    }

    private func receiveStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stdoutBuffer.append(data)
        var lines: [Data] = []
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            var line = Data(stdoutBuffer[stdoutBuffer.startIndex..<nl])
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
        lock.unlock()

        for line in lines {
            guard let env = try? JsonRpcCodec.decoder.decode(JsonRpcEnvelope.self, from: line),
                  let id = env.id else { continue }
            let key = id.stringKey
            lock.lock()
            if let waiter = waiters.removeValue(forKey: key) {
                lock.unlock()
                waiter.resume(returning: env)
            } else {
                responses[key] = env
                lock.unlock()
            }
        }
    }

    private func handleExit(_ status: Int32) {
        lock.lock()
        terminated = true
        exitCode = status
        let pending = waiters
        waiters.removeAll()
        let exits = exitWaiters
        exitWaiters.removeAll()
        lock.unlock()

        for (_, cont) in pending {
            cont.resume(throwing: PluginError(code: .pluginCrashed, message: "Plug-in exited (status \(status))"))
        }
        for cont in exits {
            cont.resume(returning: status)
        }
    }
}
