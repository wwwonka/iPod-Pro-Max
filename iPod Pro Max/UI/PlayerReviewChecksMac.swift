#if canImport(AppKitBackend)
import AppKit
import SwiftCrossUI
import iPodKit

/// Event-driven regressions from the player review, with no device or disk mutation.
@MainActor func checkPlayerDisplayOwnership() async {
    final class FreeSpaceProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64 = 1_000_000
        private var reads = 0
        func read() -> Int64 { lock.lock(); defer { lock.unlock() }; reads += 1; return value }
        func change() { lock.lock(); value = 2_000_000; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
    }
    let probe = FreeSpaceProbe()
    let display = PlayerDisplayController(readFreeSpace: { _ in probe.read() })
    var first = 0, second = 0
    let firstToken = display.didChange.observe { first += 1 }
    var secondToken: SwiftCrossUI.Cancellable? = display.didChange.observe { second += 1 }
    display.idleDetail = "probe"
    precondition(first == 1 && second == 1)
    secondToken?.cancel(); secondToken = nil
    display.idleDetail = "next"
    precondition(first == 2 && second == 1, "One LCD cannot replace or cancel another LCD's subscription")

    let device = IPodDevice(id: "idle-check", mountPoint: URL(fileURLWithPath: "/unused-idle-check"),
        volumeName: "Check", modelInfo: nil, generation: .unknown, sysInfo: [:], firewireGUID: nil,
        serialNumber: nil, extendedDBVersion: nil, artworkFormatsFromDevice: nil, isSimulated: true, databaseName: nil)
    display.setIdleDevices([device], selectedID: device.id)
    await display.waitForIdleSpace()
    let original = display.idleDetail
    probe.change()
    display.setIdleDevices([device], selectedID: device.id)
    display.invalidateIdleSpace(for: "another-device")
    await display.waitForIdleSpace()
    precondition(probe.count == 1, "Rendering and unrelated events must not reread free space")
    display.invalidateIdleSpace(for: device.id)
    await display.waitForIdleSpace()
    precondition(probe.count == 2 && display.idleDetail != original, "Same-device mutation refreshes idle free space")
    withExtendedLifetime(firstToken) {}
    log("PASS: LCD subscriptions remain independent; same-device free space invalidates on events with zero reads per render")
}
#endif
