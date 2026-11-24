import Foundation
import iPodKit

/// Small common preferences, staged synchronously by controls and flushed at operation boundaries.
@MainActor
final class PortablePreferences {
    static let shared = PortablePreferences()
    private struct Pending {
        var store: PortableLibraryStore
        var mode: String?
        var sidebarWidth: Double?
        var lastTab: String?
        var sectionTabs: [String: String] = [:]
        var sidebarOpen: Bool?
        var gridArtworkSizes: [String: Double] = [:]
        var syncArtwork: Bool?
        var favoriteIcon: String?
        var hiddenTrackColumns: [String]?
        var sidebarOrder: [String: [String]] = [:]
        var preferredFormats: [String]?
        var minimumBitrateKbps: Int?
        var acceptYouTubeFallback: Bool?
        var revision: Int
    }
    private var pending: Pending?
    private var revision = 0
    private var saveTask: Task<Void, Never>?
    private let writer = Writer()

    func stageMusicMode(_ mode: String, store: PortableLibraryStore) {
        stage(store) { guard $0.mode != mode else { return false }; $0.mode = mode; return true }
    }
    func stageSidebarWidth(_ width: Double, store: PortableLibraryStore) {
        stage(store) { guard $0.sidebarWidth != width else { return false }; $0.sidebarWidth = width; return true }
    }
    func stageLastTab(_ tab: String, store: PortableLibraryStore) {
        stage(store) { guard $0.lastTab != tab else { return false }; $0.lastTab = tab; return true }
    }
    func stageSectionTab(_ tab: String, section: String, store: PortableLibraryStore) {
        stage(store) { guard $0.sectionTabs[section] != tab else { return false }; $0.sectionTabs[section] = tab; return true }
    }
    func stageSidebarOpen(_ open: Bool, store: PortableLibraryStore) {
        stage(store) { guard $0.sidebarOpen != open else { return false }; $0.sidebarOpen = open; return true }
    }
    func stageGridArtworkSize(_ size: Double, section: String, store: PortableLibraryStore) {
        stage(store) { guard $0.gridArtworkSizes[section] != size else { return false }; $0.gridArtworkSizes[section] = size; return true }
    }
    func stageSyncArtwork(_ value: Bool, store: PortableLibraryStore) {
        stage(store) { guard $0.syncArtwork != value else { return false }; $0.syncArtwork = value; return true }
    }
    func stageFavoriteIcon(_ value: String, store: PortableLibraryStore) {
        stage(store) { guard $0.favoriteIcon != value else { return false }; $0.favoriteIcon = value; return true }
    }
    func stageHiddenTrackColumns(_ value: [String], store: PortableLibraryStore) {
        stage(store) { guard $0.hiddenTrackColumns != value else { return false }; $0.hiddenTrackColumns = value; return true }
    }
    func stageSidebarOrder(_ order: [String: [String]], store: PortableLibraryStore) {
        stage(store) {
            var changed = false
            for (section, items) in order where $0.sidebarOrder[section] != items {
                $0.sidebarOrder[section] = items
                changed = true
            }
            return changed
        }
    }
    func stageQualityPolicy(preferredFormats: [String], minimumBitrateKbps: Int, acceptYouTubeFallback: Bool, store: PortableLibraryStore) {
        stage(store) {
            var changed = false
            if $0.preferredFormats != preferredFormats { $0.preferredFormats = preferredFormats; changed = true }
            if $0.minimumBitrateKbps != minimumBitrateKbps { $0.minimumBitrateKbps = minimumBitrateKbps; changed = true }
            if $0.acceptYouTubeFallback != acceptYouTubeFallback { $0.acceptYouTubeFallback = acceptYouTubeFallback; changed = true }
            return changed
        }
    }
    /// Merges one change into what is waiting to be written; false when nothing changed.
    private func stage(_ store: PortableLibraryStore, _ change: (inout Pending) -> Bool) {
        var value = pending?.store.data.url == store.data.url ? pending! : Pending(store: store, revision: 0)
        guard change(&value) else { return }
        revision += 1
        value.revision = revision
        pending = value
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            do { try await flush() }
            catch { ApplicationLifecycle.shared.report(error) }
        }
    }
    func flush() async throws {
        while let value = pending {
            try await writer.write(mode: value.mode, sidebarWidth: value.sidebarWidth, lastTab: value.lastTab, sectionTabs: value.sectionTabs, sidebarOpen: value.sidebarOpen, gridArtworkSizes: value.gridArtworkSizes, syncArtwork: value.syncArtwork, favoriteIcon: value.favoriteIcon, hiddenTrackColumns: value.hiddenTrackColumns, sidebarOrder: value.sidebarOrder, preferredFormats: value.preferredFormats, minimumBitrateKbps: value.minimumBitrateKbps, acceptYouTubeFallback: value.acceptYouTubeFallback, store: value.store)
            if pending?.revision == value.revision { pending = nil }
        }
    }
    private actor Writer {
        func write(mode: String?, sidebarWidth: Double?, lastTab: String?, sectionTabs: [String: String], sidebarOpen: Bool?, gridArtworkSizes: [String: Double], syncArtwork: Bool?, favoriteIcon: String?, hiddenTrackColumns: [String]?, sidebarOrder: [String: [String]], preferredFormats: [String]?, minimumBitrateKbps: Int?, acceptYouTubeFallback: Bool?, store: PortableLibraryStore) throws {
            try store.data.requireAvailableStorage()
            var value = try store.data.readChecked(PortableSettings.self, from: "settings.json") ?? PortableSettings()
            guard value.version == 1 else { throw IPodDBError.unsupported("Unsupported settings.json version") }
            var changed = false
            if let mode, value.musicViewMode != mode { value.musicViewMode = mode; changed = true }
            if let sidebarWidth, value.sidebarWidth != sidebarWidth { value.sidebarWidth = sidebarWidth; changed = true }
            if let lastTab, value.lastTab != lastTab { value.lastTab = lastTab; changed = true }
            for (section, tab) in sectionTabs where value.sectionTabs[section] != tab { value.sectionTabs[section] = tab; changed = true }
            if let sidebarOpen, value.sidebarOpen != sidebarOpen { value.sidebarOpen = sidebarOpen; changed = true }
            for (section, size) in gridArtworkSizes where value.gridArtworkSizes[section] != size { value.gridArtworkSizes[section] = size; changed = true }
            if let syncArtwork, value.syncArtwork != syncArtwork { value.syncArtwork = syncArtwork; changed = true }
            if let favoriteIcon, value.favoriteIcon != favoriteIcon { value.favoriteIcon = favoriteIcon; changed = true }
            if let hiddenTrackColumns, value.hiddenTrackColumns != hiddenTrackColumns { value.hiddenTrackColumns = hiddenTrackColumns; changed = true }
            for (section, items) in sidebarOrder where value.sidebarOrder[section] != items {
                value.sidebarOrder[section] = items
                changed = true
            }
            if let preferredFormats, value.preferredFormats != preferredFormats { value.preferredFormats = preferredFormats; changed = true }
            if let minimumBitrateKbps, value.minimumBitrateKbps != minimumBitrateKbps { value.minimumBitrateKbps = minimumBitrateKbps; changed = true }
            if let acceptYouTubeFallback, value.acceptYouTubeFallback != acceptYouTubeFallback { value.acceptYouTubeFallback = acceptYouTubeFallback; changed = true }
            guard changed else { return }
            try store.data.write(value, to: "settings.json")
        }
    }
}

/// Platform close hooks await this operation instead of discarding pending preferences or writes.
@MainActor
final class ApplicationLifecycle {
    static let shared = ApplicationLifecycle()
    var savePreferences: () async throws -> Void = {}
    var beforeExit: () async throws -> Void = {}
    var onError: (String) -> Void = { _ in }
    private var exitTask: Task<Void, Error>?
    func prepareForExit() async throws {
        if let exitTask { try await exitTask.value; return }
        let task = Task { try await beforeExit() }
        exitTask = task
        defer { exitTask = nil }
        try await task.value
    }
    func report(_ error: Error) {
        onError("Couldn't save preferences: \(error.localizedDescription)")
    }
}
