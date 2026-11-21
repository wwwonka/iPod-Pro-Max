import XCTest
@testable import MediaKit
import iPodKit

final class PlayerCompletionTests: XCTestCase {
    func testInsertMoveRemoveAndClearKeepPlayingTrack() {
        var queue = PlaybackQueue(); queue.start(ids: ["a", "b", "c", "d"], at: "a")
        queue.insert(["c", "c", "x", "a"], at: 0)
        XCTAssertEqual(queue.ids, ["a", "c", "x", "b", "d"])
        queue.move("d", to: 0); XCTAssertEqual(queue.upcoming.first, "d")
        queue.remove(["a", "c"]); XCTAssertEqual(queue.current, "a"); XCTAssertFalse(queue.ids.contains("c"))
        queue.clearUpcoming(); XCTAssertEqual(queue.ids, ["a"])
    }
    func testShuffleManualOrderRestoresOriginalWithNewInsertions() {
        var queue = PlaybackQueue(); queue.start(ids: ["a", "b", "c", "d"], at: "b")
        queue.setShuffled(true); queue.move("d", to: 0)
        XCTAssertEqual(queue.upcoming.first, "d")
        queue.insert(["new"], at: 0)
        queue.setShuffled(false)
        XCTAssertEqual(queue.ids, ["a", "b", "new", "c", "d"])
        XCTAssertEqual(queue.current, "b")
        XCTAssertTrue(queue.jump(to: "new")); XCTAssertFalse(queue.jump(to: "missing"))
    }
    func testGroupMovePreservesOrderAndProtectsCurrentTrack() {
        var queue = PlaybackQueue()
        queue.start(ids: ["a", "b", "c", "d", "e", "f"], at: "a")
        queue.move(["b", "c"], to: 5)
        XCTAssertEqual(queue.ids, ["a", "d", "e", "f", "b", "c"])
        queue.move(["e", "c"], to: 0)
        XCTAssertEqual(queue.ids, ["a", "e", "c", "d", "f", "b"])
        queue.move(["a", "missing", "e", "e"], to: 5)
        XCTAssertEqual(queue.current, "a")
        XCTAssertEqual(Set(queue.ids), Set(["a", "b", "c", "d", "e", "f"]))
        XCTAssertEqual(queue.ids.count, 6)
    }
    func testOtherCacheSessionCannotUnlinkLiveWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = TemporaryMediaCache(root: root), second = TemporaryMediaCache(root: root)
        let file = first.scratchURL(extension: "spectrum")
        try Data([1, 2]).write(to: file)
        let writer = try FileHandle(forWritingTo: file)
        second.configure(MediaCachePolicy(), launchCleanup: true)
        second.clear(.scratch)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try writer.seekToEnd(); try writer.write(contentsOf: Data([3])); try writer.close()
        first.commitScratch(file, category: .spectrum, key: "live")
        XCTAssertEqual(first.read(.spectrum, key: "live"), Data([1, 2, 3]))
        XCTAssertNotEqual(first.scratchURL().deletingLastPathComponent(), second.scratchURL().deletingLastPathComponent())
    }
    func testLaunchReapsDeadSessionsButPreservesUnownedLegacyFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TemporaryMediaCache(root: root)
        let folder = cache.directory(.scratch)
        let abandoned = folder.appendingPathComponent("2147483647-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data([0]).write(to: abandoned.appendingPathComponent("old.tmp"))
        let legacy = folder.appendingPathComponent("old-build.tmp")
        try Data([0]).write(to: legacy)
        cache.configure(MediaCachePolicy(), launchCleanup: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }
    func testCacheRevisionKeysAndUnlinkDoesNotInvalidateRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TemporaryMediaCache(root: root)
        let key = TemporaryMediaCache.key(path: "/private/song", size: 10, modified: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(key.count, 40); XCTAssertFalse(key.contains("song"))
        XCTAssertNotEqual(key, TemporaryMediaCache.key(path: "/private/song", size: 11, modified: Date(timeIntervalSince1970: 1)))
        XCTAssertNotEqual(key, TemporaryMediaCache.key(path: "/private/song", size: 10, modified: Date(timeIntervalSince1970: 2)))
        cache.write(Data([1,2,3]), category: .waveforms, key: key)
        let retained = cache.read(.waveforms, key: key)
        XCTAssertNil(cache.read(.waveforms, key: key, version: 2))
        cache.clear(); XCTAssertNil(cache.read(.waveforms, key: key)); XCTAssertEqual(retained, Data([1,2,3]))
        try? FileManager.default.removeItem(at: root)
        cache.write(Data([4]), category: .waveforms, key: key)
        XCTAssertEqual(cache.read(.waveforms, key: key), Data([4]))
    }
    func testCacheLRULimitCleanupAndExitPolicy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = TemporaryMediaCache(root: root)
        cache.write(Data([1,1,1]), category: .spectrum, key: "a")
        cache.write(Data([2,2,2]), category: .waveforms, key: "b")
        let a = cache.directory(.spectrum).appendingPathComponent("v1-a.bin")
        let b = cache.directory(.waveforms).appendingPathComponent("v1-b.bin")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: a.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: b.path)
        cache.touch(.waveforms, key: "b")
        cache.write(Data([3,3,3]), category: .spectrum, key: "c")
        var policy = MediaCachePolicy(); policy.limitBytes = 6; policy.clearSpectrumOnExit = true
        cache.configure(policy)
        XCTAssertNil(cache.read(.spectrum, key: "a"))
        XCTAssertEqual(cache.read(.waveforms, key: "b"), Data([2,2,2]))
        XCTAssertEqual(cache.sizes().values.reduce(0, +), 6)
        let scratch = cache.scratchURL(); try Data([0]).write(to: scratch)
        let other = TemporaryMediaCache(root: root); other.configure(policy, launchCleanup: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path))
        let obsolete = cache.directory(.spectrum).appendingPathComponent("v0-obsolete.bin"); try Data([0]).write(to: obsolete)
        let freshLaunch = TemporaryMediaCache(root: root); freshLaunch.configure(policy, launchCleanup: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: obsolete.path))
        cache.cleanupOnExit(); XCTAssertEqual(cache.sizes()["Spectrum"], 0)
        XCTAssertEqual(cache.sizes()["Waveforms"], 3)
    }
    func testCacheFailureFallsBackWithoutThrowing() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let cache = TemporaryMediaCache(root: file)
        cache.write(Data([1]), category: .spectrum, key: "a")
        XCTAssertNil(cache.read(.spectrum, key: "a")); cache.clear()
    }
    func testSpectrumStereoFrequenciesAndVersionedRoundTrip() {
        let analyzer = SpectrumAnalyzer(sampleRate: 44100)
        for sample in 0..<44100 {
            let t = Double(sample) / 44100
            analyzer.consume(left: Float(sin(t * 2 * .pi * 440) * 0.8), right: Float(sin(t * 2 * .pi * 3000) * 0.8))
        }
        let spectrum = analyzer.result()
        XCTAssertEqual(spectrum.frames.count, 20)
        let frame = spectrum.frames[10]
        XCTAssertEqual(frame.count, 32)
        let left = Array(frame.prefix(16)), right = Array(frame.suffix(16))
        XCTAssertGreaterThan(right.firstIndex(of: right.max()!)!, left.firstIndex(of: left.max()!)!)
        let data = SpectrumFile.encode(spectrum)
        XCTAssertEqual(SpectrumFile.decode(data)?.frames, spectrum.frames)
        XCTAssertNil(SpectrumFile.decode(Data("IPSP0002".utf8)))
        XCTAssertNil(SpectrumFile.decode(data + Data([1])))
        XCTAssertEqual(SpectrumFile.decode(SpectrumFile.header)?.frames.count, 0)
    }
    func testPortableFFTWorkspaceTransformsImpulseWithoutStaleValues() {
        var real = [Float](repeating: 0, count: 2048), imaginary = real
        real[0] = 1
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in SpectrumAnalyzer.fft(real, imaginary) }
        }
        XCTAssertTrue(real.allSatisfy { abs($0 - 1) < 0.0001 })
        XCTAssertTrue(imaginary.allSatisfy { abs($0) < 0.0001 })
    }
    func testPortableCacheSettingsDefaults() throws {
        let defaults = try JSONDecoder().decode(PortableSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(defaults.temporaryCacheLimitMB, 200); XCTAssertFalse(defaults.clearSpectrumOnExit)
        var value = defaults; value.clearWaveformsOnExit = true; value.temporaryCacheLimitMB = 500
        let restored = try JSONDecoder().decode(PortableSettings.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored.temporaryCacheLimitMB, 500); XCTAssertTrue(restored.clearWaveformsOnExit)
    }
    @MainActor func testSimulatedSessionReceivesCommandsAndStates() {
        let session = SimulatedMediaSession()
        var commands: [MediaSessionCommand] = []; session.onCommand = { commands.append($0) }
        session.publish(.init(title: "Track", rate: 1.5, status: .playing, spoken: true))
        session.send(.pause); session.send(.seek(12)); session.send(.skip(30))
        XCTAssertEqual(commands, [.pause, .seek(12), .skip(30)])
        XCTAssertEqual(session.publications.count, 1); XCTAssertEqual(session.publications.first?.rate, 1.5)
    }
}
