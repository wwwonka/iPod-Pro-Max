//
//  DeviceMonitor.swift
//  iPod Pro Max
//
//  Keeps the list of connected iPods up to date. Finding, identifying (USB fallback), watching and
//  ejecting are DeviceKit's, the same code as on Linux and Windows and in the command-line tool.
//

import Foundation
import Observation
import iPodKit
import DeviceKit

@MainActor
@Observable
final class DeviceMonitor {
    private(set) var devices: [IPodDevice] = []
    /// Folders attached through Settings › Advanced as simulated iPods (persisted as paths).
    private(set) var simulatedFolders: [URL] = []

    /// DiskArbitration mount, unmount and rename events (no polling).
    private var watcher: VolumeWatcher?
    private let defaultsKey = "simulatedIPodFolders"

    init() {
        if let paths = UserDefaults.standard.array(forKey: defaultsKey) as? [String] {
            simulatedFolders = paths.map { URL(fileURLWithPath: $0) }
        }
        // Development aid: `-simulatedIPodFolder /path` on the command line attaches a folder for this launch only.
        if let extra = UserDefaults.standard.string(forKey: "simulatedIPodFolder"), !extra.isEmpty {
            let url = URL(fileURLWithPath: extra)
            if !simulatedFolders.contains(url) { simulatedFolders.append(url) }
        }
        watcher = VolumeWatcher { [weak self] in
            Task { @MainActor [weak self] in self?.rescan() }
        }
        rescan()
    }

    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0

    /// Scans volumes on a background thread (network or wedged volumes must never block the UI).
    func rescan() {
        scanGeneration += 1
        let generation = scanGeneration
        let folders = simulatedFolders
        scanTask?.cancel()
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let found = Self.scanVolumes(simulatedFolders: folders)
            guard let self else { return }
            await self.applyScan(found, generation: generation)
        }
    }

    private func applyScan(_ found: [IPodDevice], generation: Int) {
        guard generation == scanGeneration else { return }
        if found != devices { devices = found }
    }

    nonisolated static func scanVolumes(simulatedFolders: [URL]) -> [IPodDevice] {
        // Development aid: `-ignoreDevices YES` hides real iPods.
        DeviceScanner.scan(simulatedFolders: simulatedFolders,
                           includeRealDevices: !UserDefaults.standard.bool(forKey: "ignoreDevices"))
    }

    func device(id: String) -> IPodDevice? { devices.first { $0.id == id } }

    func attachSimulatedFolder(_ url: URL) {
        if !simulatedFolders.contains(url) {
            simulatedFolders.append(url)
            persistSimulated()
        }
        rescan()
    }

    func detachSimulatedFolder(_ url: URL) {
        simulatedFolders.removeAll { $0 == url }
        persistSimulated()
        rescan()
    }

    private func persistSimulated() {
        UserDefaults.standard.set(simulatedFolders.map(\.path), forKey: defaultsKey)
    }

    /// Ejects (unmounts) a real iPod. Simulated folders are simply detached.
    func eject(_ device: IPodDevice) async throws {
        if device.isSimulated {
            detachSimulatedFolder(device.mountPoint)
            return
        }
        try await Ejector.eject(device)
        rescan()
    }
}
