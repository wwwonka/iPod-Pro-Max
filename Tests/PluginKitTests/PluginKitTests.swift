import Foundation
import XCTest
@testable import PluginKit

final class PluginKitTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ippm-pluginkit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - PLG-1 Types & SHA-256

    func testCandidateClampsHintOnInitAndDecode() throws {
        let low = Candidate(resolver: "s", token: "t", displayName: "d", container: "flac", hint: -0.5)
        XCTAssertEqual(low.hint, 0)
        let high = Candidate(resolver: "s", token: "t", displayName: "d", container: "flac", hint: 2.3)
        XCTAssertEqual(high.hint, 1)
        let nan = Candidate(resolver: "s", token: "t", displayName: "d", container: "flac", hint: .nan)
        XCTAssertEqual(nan.hint, 0)

        let json = #"{"resolver":"s","token":"t","displayName":"d","container":"mp3","hint":1.75}"#
        let decoded = try JSONDecoder().decode(Candidate.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.hint, 1)
    }

    func testSHA256KnownVectors() {
        XCTAssertEqual(
            SHA256.hex(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            SHA256.hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    // MARK: - Manifest & SVG Badge

    func testManifestValidationRules() throws {
        let missingRoles = #"{"id":"test","name":"Test","version":"1.0.0","apiVersion":1,"description":"desc","executable":{"macos":"bin/test"}}"#
        XCTAssertThrowsError(try ManifestValidator.validate(data: Data(missingRoles.utf8))) { err in
            XCTAssertEqual(err.localizedDescription, "plugin.json: missing field 'roles'")
        }

        let valid = """
        {
          "id": "demo-plugin",
          "name": "Demo",
          "version": "1.0.0",
          "apiVersion": 1,
          "description": "Demo plug-in",
          "roles": ["playlistSource", "futureRole"],
          "executable": {
            "macos": "bin/macos/demo",
            "windows-x64": "bin/win64/demo.exe"
          }
        }
        """
        XCTAssertThrowsError(
            try ManifestValidator.validate(data: Data(valid.utf8), expectedFolderName: "wrong-name", platform: .macos)
        ) { err in
            XCTAssertEqual(err.localizedDescription, "Folder name doesn't match plug-in id")
        }

        let macValidated = try ManifestValidator.validate(
            data: Data(valid.utf8),
            expectedFolderName: "demo-plugin",
            platform: .macos
        )
        XCTAssertEqual(macValidated.manifest.knownRoles, [.playlistSource])
        XCTAssertEqual(macValidated.warnings, ["Unknown role 'futureRole' ignored."])
        XCTAssertEqual(macValidated.executableRelativePath, "bin/macos/demo")

        // Windows ARM64 falls back to windows-x64 when windows-arm64 is absent
        let winARM = try ManifestValidator.validate(
            data: Data(valid.utf8),
            expectedFolderName: "demo-plugin",
            platform: .windowsARM64
        )
        XCTAssertEqual(winARM.executableRelativePath, "bin/win64/demo.exe")

        let unsupportedAPI = """
        {
          "id": "demo", "name": "Demo", "version": "1.0.0", "apiVersion": 99,
          "description": "d", "roles": ["resolver"], "executable": {"macos": "bin/demo"}
        }
        """
        XCTAssertThrowsError(try ManifestValidator.validate(data: Data(unsupportedAPI.utf8))) { err in
            XCTAssertTrue(err.localizedDescription.contains("unsupported apiVersion 99"))
        }
    }

    func testSVGBadgeParserValidation() throws {
        let valid = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M 2 2 L 22 2 C 22 12 12 22 2 22 Z"/></svg>"#
        let parsed = try SVGBadgeParser.parse(svgString: valid)
        XCTAssertEqual(parsed.steps.count, 4)

        let multiPath = #"<svg viewBox="0 0 24 24"><path d="M 0 0 L 10 10"/><path d="M 1 1 L 2 2"/></svg>"#
        XCTAssertThrowsError(try SVGBadgeParser.parse(svgString: multiPath))

        let withCircle = #"<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><path d="M 0 0 L 1 1"/></svg>"#
        XCTAssertThrowsError(try SVGBadgeParser.parse(svgString: withCircle))

        let nonSquare = #"<svg viewBox="0 0 24 12"><path d="M 0 0 L 10 10"/></svg>"#
        XCTAssertThrowsError(try SVGBadgeParser.parse(svgString: nonSquare))

        let badCmd = #"<svg viewBox="0 0 24 24"><path d="M 0 0 A 5 5 0 0 1 10 10"/></svg>"#
        XCTAssertThrowsError(try SVGBadgeParser.parse(svgString: badCmd))
    }

    // MARK: - PLG-12 ZipArchive & .ippmplugin Package

    func testZipRoundTripAndZipSlipRejection() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let zipURL = dir.appendingPathComponent("test.zip")
        let bigText = String(repeating: "Hello iPod Pro Max Plug-in Kit! ", count: 200)
        let entries = [
            ZipEntry(path: "plugin.json", data: Data(#"{"id":"x"}"#.utf8), unixPermissions: 0o644),
            ZipEntry(path: "bin/macos/run", data: Data(bigText.utf8), unixPermissions: 0o755),
        ]
        try ZipArchive.write(entries: entries, to: zipURL)
        let decoded = try ZipArchive.read(from: zipURL)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].path, "plugin.json")
        XCTAssertEqual(decoded[1].data, Data(bigText.utf8))
        XCTAssertEqual(decoded[1].unixPermissions, 0o755)

        XCTAssertThrowsError(try ZipArchive.sanitizeRelativePath("../escape"))
        XCTAssertThrowsError(try ZipArchive.sanitizeRelativePath("/abs/path"))
    }

    func testPluginPackagePackVerifyAndTamperDetection() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src", isDirectory: true)
        let execRel = PluginPlatform.current.executableKeys[0]
        let binPath = "bin/\(execRel)/demo-plugin"
        let binURL = srcDir.appendingPathComponent(binPath)
        try FileManager.default.createDirectory(at: binURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: binURL)

        let manifest = PluginManifest(
            id: "demo",
            name: "Demo",
            version: "1.2.0",
            description: "Demo plug-in",
            roles: ["playlistSource"],
            executable: [execRel: binPath]
        )
        let manData = try JSONEncoder().encode(manifest)
        try manData.write(to: srcDir.appendingPathComponent("plugin.json"))

        let pkgURL = dir.appendingPathComponent("Demo-1.2.0.ippmplugin")
        _ = try PluginPackage.pack(folderURL: srcDir, outputURL: pkgURL)

        let verified = try PluginPackage.verify(packageURL: pkgURL)
        XCTAssertEqual(verified.manifest.id, "demo")
        XCTAssertEqual(verified.manifest.version, "1.2.0")

        // Tamper with one file inside the zip -> must fail SHA256SUMS verification
        var entries = try ZipArchive.read(from: pkgURL)
        if let idx = entries.firstIndex(where: { $0.path == binPath }) {
            entries[idx].data = Data("tampered".utf8)
        }
        let tamperedURL = dir.appendingPathComponent("Tampered.ippmplugin")
        try ZipArchive.write(entries: entries, to: tamperedURL)
        XCTAssertThrowsError(try PluginPackage.verify(packageURL: tamperedURL)) { err in
            XCTAssertEqual(err.localizedDescription, "This plug-in is damaged and can't be installed.")
        }
    }

    // MARK: - PLG-5, PLG-7, PLG-11, PLG-13 Registry & Settings

    func testRegistryDiscoveryOverrideBackupAndInstall() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let ipodRoot = root.appendingPathComponent("iPod", isDirectory: true)
        let registry = PluginRegistry(iPodRoot: ipodRoot)
        let execKey = PluginPlatform.current.executableKeys[0]
        let binRel = "bin/\(execKey)/demo"

        // Build and install package 1.0.0
        let pkgSrc = root.appendingPathComponent("pkg-src", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pkgSrc.appendingPathComponent(binRel).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: pkgSrc.appendingPathComponent(binRel))
        let manifest = PluginManifest(
            id: "demo",
            name: "Demo",
            version: "1.0.0",
            description: "Demo",
            roles: ["resolver"],
            executable: [execKey: binRel],
            requiresConsent: .p2p,
            settings: [
                PluginSettingDefinition(key: "port", type: .int, label: "Port", defaultValue: .int(2234), min: 1024, max: 65535),
                PluginSettingDefinition(key: "token", type: .secret, label: "Token"),
                PluginSettingDefinition(key: "dl", type: .folder, label: "Folder", defaultValue: .string("downloads")),
            ]
        )
        try JSONEncoder().encode(manifest).write(to: pkgSrc.appendingPathComponent("plugin.json"))
        let pkgURL = root.appendingPathComponent("Demo-1.0.0.ippmplugin")
        _ = try PluginPackage.pack(folderURL: pkgSrc, outputURL: pkgURL)
        let verified = try PluginPackage.verify(packageURL: pkgURL)
        let installed = try await registry.install(package: verified)
        XCTAssertEqual(installed.id, "demo")
        XCTAssertFalse(registry.isEnabled("demo"))
        XCTAssertEqual(registry.needsConsent(for: installed), .p2p)

        // Grant consent & enable
        try registry.grantConsentAndEnable(pluginID: "demo", type: .p2p)
        XCTAssertTrue(registry.isEnabled("demo"))
        XCTAssertNil(registry.needsConsent(for: installed))

        // Corrupt primary plugins.json -> must recover from .bak after next mutation
        try registry.setDeveloperMode(true)
        try Data("corrupt".utf8).write(to: registry.pluginsStateURL)
        _ = registry.discover()
        XCTAssertTrue(registry.isEnabled("demo"))

        // Corrupt both primary and .bak -> resets to disabled + requires consent again
        try Data("corrupt".utf8).write(to: registry.pluginsStateURL)
        let bakURL = registry.pluginsStateURL.deletingLastPathComponent().appendingPathComponent("plugins.json.bak")
        try Data("corrupt".utf8).write(to: bakURL)
        _ = registry.discover()
        XCTAssertFalse(registry.isEnabled("demo"))
        XCTAssertEqual(registry.needsConsent(for: installed), .p2p)

        // Settings type mismatch fallback + missing folder fallback
        let pStore = registry.settingsStore(for: "demo")
        try pStore.saveSettingsDict([
            "port": .string("not-an-int"),
            "obsoleteKey": .bool(true),
        ])
        try pStore.saveSecretsDict(["token": .string("secret-xyz")])
        var warningCount = 0
        let resolved = pStore.resolvedSettings(
            for: manifest,
            folderOverrides: ["dl": "/nonexistent/folder/for/test"]
        ) { _ in warningCount += 1 }
        XCTAssertEqual(warningCount, 1)
        XCTAssertEqual(resolved["port"], .int(2234))
        XCTAssertEqual(resolved["token"], .string("secret-xyz"))
        XCTAssertNil(resolved["obsoleteKey"])
        XCTAssertEqual(resolved["dl"]?.stringValue, SafeStorage.defaultDownloadsFolder().path)

        // Unpacked plug-in with same id overrides installed
        let unpackedDir = root.appendingPathComponent("dev-demo", isDirectory: true)
        try FileManager.default.copyItem(at: registry.pluginsDir.appendingPathComponent("demo"), to: unpackedDir)
        registry.setHostConfiguration(unpackedFolders: [unpackedDir.path], folderOverrides: [:])
        let afterUnpacked = registry.discover()
        XCTAssertEqual(afterUnpacked.filter { $0.id == "demo" && !$0.isUnpacked }.first?.overriddenByUnpacked, true)
        XCTAssertEqual(afterUnpacked.filter { $0.id == "demo" && $0.isUnpacked }.first?.overriddenByUnpacked, false)

        // Uninstall keeping vs deleting settings
        try await registry.uninstall(pluginID: "demo", deleteSettings: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: registry.pluginsDir.appendingPathComponent("demo").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pStore.settingsURL.path))
    }

    func testResolverOrderPreservesDisabledSlots() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = PluginRegistry(iPodRoot: root)
        let execKey = PluginPlatform.current.executableKeys[0]
        for id in ["soulseek", "yt-dlp", "bandcamp"] {
            let dir = registry.pluginsDir.appendingPathComponent(id, isDirectory: true)
            let bin = dir.appendingPathComponent("bin/exec")
            try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: bin)
            let m = PluginManifest(id: id, name: id, version: "1.0.0", description: id, roles: ["resolver"], executable: [execKey: "bin/exec"])
            try JSONEncoder().encode(m).write(to: dir.appendingPathComponent("plugin.json"))
        }

        _ = registry.discover()
        try registry.setEnabled(true, pluginID: "soulseek")
        try registry.setEnabled(true, pluginID: "yt-dlp")
        try registry.setEnabled(true, pluginID: "bandcamp")
        XCTAssertEqual(registry.orderedEnabledResolvers().map(\.id), ["soulseek", "yt-dlp", "bandcamp"])

        // Disable middle item yt-dlp -> reorder remaining -> re-enable yt-dlp -> keeps middle slot!
        try registry.setEnabled(false, pluginID: "yt-dlp")
        XCTAssertEqual(registry.orderedEnabledResolvers().map(\.id), ["soulseek", "bandcamp"])
        try registry.reorderEnabledResolvers(["bandcamp", "soulseek"])
        try registry.setEnabled(true, pluginID: "yt-dlp")
        XCTAssertEqual(registry.orderedEnabledResolvers().map(\.id), ["bandcamp", "yt-dlp", "soulseek"])
    }

    // MARK: - PLG-4 ExternalPlugin Subprocess Integration

    #if !os(Windows)
    func testExternalPluginLifecycleCancelNonJSONAndCrashLimit() async throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw XCTSkip("python3 not available")
        }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let scriptURL = dir.appendingPathComponent("mock-plugin.py")
        let script = """
        #!/usr/bin/env python3
        import json, os, sys, time, threading

        cancelled = set()
        lock = threading.Lock()

        def handle_req(msg):
            rid = msg["id"]
            method = msg["method"]
            params = msg.get("params", {})
            if method == "initialize":
                print("not json line accidentally printed", flush=True)
                resp = {"jsonrpc":"2.0","id":rid,"result":{"roles":["playlistSource","resolver","downloader"],"version":"1.0.0"}}
                print(json.dumps(resp), flush=True)
            elif method == "shutdown":
                print(json.dumps({"jsonrpc":"2.0","id":rid,"result":{}}), flush=True)
                os._exit(0)
            elif method == "source/fetch":
                url = params.get("url", "")
                if "crash" in url:
                    os._exit(42)
                if "slow" in url:
                    for _ in range(50):
                        with lock:
                            if rid in cancelled:
                                print(json.dumps({"jsonrpc":"2.0","id":rid,"error":{"code":-32000,"message":"Cancelled","data":{"code":"cancelled"}}}), flush=True)
                                return
                        time.sleep(0.05)
                res = {
                    "playlist": {"source":"mock","sourceID":"1","title":"Test","revision":"r1"},
                    "tracks": [{"source":"mock","sourceID":"t1","title":"Song","artists":["Artist"]}]
                }
                print(json.dumps({"jsonrpc":"2.0","id":rid,"result":res}), flush=True)

        for line in sys.stdin:
            line = line.strip()
            if not line: continue
            msg = json.loads(line)
            if "id" in msg:
                t = threading.Thread(target=handle_req, args=(msg,), daemon=True)
                t.start()
            elif msg.get("method") == "$/cancelRequest":
                with lock:
                    cancelled.add(msg["params"]["id"])
        """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let execKey = PluginPlatform.current.executableKeys[0]
        let manifest = PluginManifest(
            id: "mock",
            name: "Mock",
            version: "1.0.0",
            description: "Mock",
            roles: ["playlistSource", "resolver", "downloader"],
            executable: [execKey: "mock-plugin.py"]
        )

        let logEntries = LockedBox<[PluginLogEntry]>([])
        let ext = ExternalPlugin(
            manifest: manifest,
            rootURL: dir,
            executableURL: scriptURL,
            paths: PluginPaths(data: dir.path, cache: dir.path, temp: dir.path),
            settingsProvider: { [:] },
            onLogLine: { entry in logEntries.mutate { $0.append(entry) } }
        )

        // 1. Normal call + non-JSON line on stdout handled cleanly without breaking connection
        let fetched = try await ext.fetch(url: URL(string: "https://example.com/ok")!)
        XCTAssertEqual(fetched.playlist.title, "Test")
        XCTAssertTrue(logEntries.value.contains { $0.text.contains("non-JSON line on stdout") })

        // 2. wrongResolver enforced for mismatched candidate
        do {
            _ = try await ext.download(
                candidate: Candidate(resolver: "other", token: "t", displayName: "d", container: "mp3"),
                destinationDir: dir
            )
            XCTFail("Expected wrongResolver")
        } catch let err as PluginError {
            XCTAssertEqual(err.code, .wrongResolver)
        }

        // 3. Cancellation returns cancelled within < 2s
        let task = Task {
            try await ext.fetch(url: URL(string: "https://example.com/slow")!)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancelled error")
        } catch let err as PluginError {
            XCTAssertEqual(err.code, .cancelled)
        }

        // 4. 3 crashes in 60s -> Error state, then restart recovers
        for _ in 0..<3 {
            do {
                _ = try await ext.fetch(url: URL(string: "https://example.com/crash")!)
                XCTFail("Expected crash")
            } catch let err as PluginError {
                XCTAssertEqual(err.code, .pluginCrashed)
            }
        }
        let stateAfterCrashes = await ext.currentState()
        if case .error = stateAfterCrashes {
            // expected
        } else {
            XCTFail("Expected .error state after 3 crashes, got \(stateAfterCrashes)")
        }

        // 4th attempt while in Error state fails without launching
        do {
            _ = try await ext.fetch(url: URL(string: "https://example.com/ok")!)
            XCTFail("Expected launchFailed while in error state")
        } catch let err as PluginError {
            XCTAssertEqual(err.code, .launchFailed)
        }

        await ext.restart()
        let recovered = try await ext.fetch(url: URL(string: "https://example.com/ok")!)
        XCTAssertEqual(recovered.tracks.count, 1)
    }
    #endif

    // MARK: - PLG-15 Skeleton Creation

    func testCreateSkeletonAndRefuseOverwrite() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("Deezer", isDirectory: true)
        try PluginCLI.createSkeleton(name: "Deezer", roles: [.playlistSource], at: target)

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("plugin.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("Sources/DeezerPlugin/main.swift").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("Tests/fixtures.json").path))
        let badge = try Data(contentsOf: target.appendingPathComponent("badge.svg"))
        _ = try SVGBadgeParser.parse(data: badge)

        // Calling again must refuse without overwriting
        XCTAssertThrowsError(try PluginCLI.createSkeleton(name: "Deezer", roles: [.playlistSource], at: target))
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ initial: T) { self.storage = initial }

    var value: T {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func mutate(_ block: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        block(&storage)
    }
}
