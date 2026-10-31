import XCTest
@testable import iPodKit

final class DeviceSnapshotCacheTests: XCTestCase {
    private func device(_ name: String, at path: String) -> IPodDevice {
        IPodDevice(id: name, mountPoint: URL(fileURLWithPath: path), volumeName: name,
            modelInfo: nil, generation: .unknown, sysInfo: [:], firewireGUID: nil,
            serialNumber: nil, extendedDBVersion: nil, artworkFormatsFromDevice: nil,
            isSimulated: true, databaseName: nil)
    }

    @MainActor func testSwitchingDevicesReusesEachSnapshot() async {
        let cache = DeviceSnapshotCache<String>()
        let a = device("a", at: "/tmp/a"), b = device("b", at: "/tmp/b")
        let first = await cache.load(for: a) { $0.id }
        let second = await cache.load(for: b) { $0.id }
        XCTAssertEqual(first, "a"); XCTAssertEqual(second, "b")
        for _ in 0..<20 {
            let again = await cache.load(for: a) { _ in XCTFail("Repeated disk read"); return "wrong" }
            XCTAssertEqual(again, "a")
            _ = await cache.load(for: b) { _ in XCTFail("Repeated disk read"); return "wrong" }
        }
        XCTAssertEqual(cache.readCount, 2)
        cache.invalidate(a)
        let updated = await cache.load(for: a) { _ in "updated" }
        XCTAssertEqual(updated, "updated")
        XCTAssertEqual(cache.readCount, 3)
        XCTAssertEqual(cache.cached(for: b), "b")
    }

    @MainActor func testPrefetchAndViewJoinTheSameRead() async {
        let cache = DeviceSnapshotCache<Int>()
        let a = device("a", at: "/tmp/a")
        let gate = SnapshotReadGate()
        let first = Task { await cache.load(for: a) { _ in await gate.wait(); return 42 } }
        await gate.waitForEntry()
        let second = Task { await cache.load(for: a) { _ in XCTFail("Duplicate read"); return 0 } }
        await gate.open()
        let one = await first.value, two = await second.value
        XCTAssertEqual(one, 42); XCTAssertEqual(two, 42)
        XCTAssertEqual(cache.readCount, 1)
    }

    @MainActor func testInvalidatedReadCannotRestoreStaleData() async {
        let cache = DeviceSnapshotCache<Int>()
        let a = device("a", at: "/tmp/a")
        let gate = SnapshotReadGate()
        let old = Task { await cache.load(for: a) { _ in await gate.wait(); return 1 } }
        await gate.waitForEntry()
        cache.invalidate(a)
        cache.store(2, for: a)
        await gate.open()
        let value = await old.value
        XCTAssertEqual(value, 2)
        XCTAssertEqual(cache.cached(for: a), 2)
    }

    @MainActor func testMountPointIsPartOfIdentity() async {
        let cache = DeviceSnapshotCache<String>()
        let first = device("same-id", at: "/tmp/one"), second = device("same-id", at: "/tmp/two")
        _ = await cache.load(for: first) { $0.mountPoint.path }
        _ = await cache.load(for: second) { $0.mountPoint.path }
        XCTAssertEqual(cache.cached(for: first), "/tmp/one")
        XCTAssertEqual(cache.cached(for: second), "/tmp/two")
        XCTAssertEqual(cache.readCount, 2)
    }
}

private actor SnapshotReadGate {
    private var entered = false
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entries: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        entries.forEach { $0.resume() }; entries.removeAll()
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entries.append($0) } }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }; waiters.removeAll()
    }
}
