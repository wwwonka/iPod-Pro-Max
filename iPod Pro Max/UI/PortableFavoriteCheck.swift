#if canImport(AppKitBackend)
import Foundation
import iPodKit

/// A simulated iPod and temporary WAV exercise the same loader used by the application.
@MainActor
func checkPortableFavoriteRecovery() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("favorite-loader-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("iPod")
    let music = base.appendingPathComponent("Music")
    try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
    try IPodDevice.createSimulatedIPod(at: root)
    let source = music.appendingPathComponent("Song.wav")
    let count = 8000 * 2
    var wav = Data("RIFF".utf8)
    func le32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { wav.append(contentsOf: $0) } }
    func le16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { wav.append(contentsOf: $0) } }
    le32(36 + count); wav.append(Data("WAVEfmt ".utf8)); le32(16); le16(1); le16(1); le32(8000); le32(16000); le16(2); le16(16)
    wav.append(Data("data".utf8)); le32(count); wav.append(Data(repeating: 0, count: count))
    try wav.write(to: source)
    let noLegacy = base.appendingPathComponent("absent-legacy.json")
    var loaded = try await PortableLoading.load(folder: music, refresh: true, root: root, legacyLibraryURL: noLegacy)
    guard loaded.cache.tracks.count == 1 else { fatalError("Expected one imported song") }
    let id = loaded.cache.tracks[0].id
    loaded.cache.tracks[0].isFavorite = true
    loaded.cache.reconcileFavoriteReferences()
    try loaded.store.save(loaded.cache)
    try FileManager.default.removeItem(at: source)
    let missing = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    precondition(missing.cache.tracks.isEmpty && missing.cache.favoriteReferences?.first?.id == id,
                 "Unavailable favorites must stay hidden and retain identity")
    try wav.write(to: source)
    let restored = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    precondition(restored.cache.tracks.first?.id == id && restored.cache.tracks.first?.isFavorite == true,
                 "A restored source must recover its favorite")
    let hosts = try restored.store.data.readChecked(KnownHosts.self, from: "known_hosts.json")
    let sourceID = hosts?.hosts.first { $0.id == restored.store.hostID }?.sources.first { $0.path == music.path }?.id
    guard let sourceID else { fatalError("Missing test source") }
    try restored.store.removeSource(id: sourceID)
    // Simulate a source removal whose immediate refresh was interrupted: the next launch has
    // no `removedKind` hint, but must reconcile the persisted source registry against the cache.
    let removed = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    precondition(removed.cache.tracks.isEmpty && removed.cache.favoriteReferences?.isEmpty == true,
                 "Explicit source removal must forget its favorites")
    // A removed parent source must not erase offline favorites still covered by a nested source.
    let nested = music.appendingPathComponent("Nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let nestedSong = nested.appendingPathComponent("Favorite.wav")
    try wav.write(to: nestedSong)
    let playlistSong = nested.appendingPathComponent("Playlist.wav")
    try wav.write(to: playlistSong)
    let parent = try await PortableLoading.load(folder: music, refresh: true, root: root, legacyLibraryURL: noLegacy)
    var nestedCache = parent.cache
    guard let index = nestedCache.tracks.firstIndex(where: { $0.path == nestedSong.path }) else { fatalError("Missing nested song") }
    let nestedID = nestedCache.tracks[index].id
    nestedCache.tracks[index].isFavorite = true
    nestedCache.tracks[index].rating = 4
    nestedCache.tracks[index].playCount = 12
    nestedCache.tracks[index].dateAdded = Date(timeIntervalSince1970: 1_000)
    guard let playlistIndex = nestedCache.tracks.firstIndex(where: { $0.path == playlistSong.path }) else { fatalError("Missing playlist song") }
    let playlistID = UUID()
    nestedCache.tracks[playlistIndex].id = playlistID
    nestedCache.playlists.append(LibraryPlaylist(name: "Offline", trackIDs: [playlistID]))
    nestedCache.reconcileFavoriteReferences()
    try parent.store.save(nestedCache)
    _ = try parent.store.addSource(kind: .music, path: nested.path)
    let overlap = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    precondition(overlap.cache.tracks.filter { $0.path == nestedSong.path }.count == 1 &&
                 overlap.cache.tracks.first(where: { $0.path == nestedSong.path })?.id == nestedID &&
                 overlap.cache.tracks.first(where: { $0.path == nestedSong.path })?.isFavorite == true,
                 "Overlapping sources must not duplicate a track or change its identity")
    let hiddenRoot = music.appendingPathComponent(".Hidden")
    try FileManager.default.createDirectory(at: hiddenRoot, withIntermediateDirectories: true)
    let hiddenSong = hiddenRoot.appendingPathComponent("Hidden.wav")
    try wav.write(to: hiddenSong)
    let hiddenSource = try parent.store.addSource(kind: .music, path: hiddenRoot.path)
    let hidden = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    precondition(hidden.cache.tracks.contains(where: { $0.path == hiddenSong.path }),
                 "Explicit hidden source must be scanned even when nested under another source")
    try parent.store.removeSource(id: hiddenSource.id)
    try FileManager.default.removeItem(at: hiddenRoot)
    let overlapAgain = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    precondition(overlapAgain.cache.tracks.filter { $0.path == nestedSong.path }.count == 1 &&
                 overlapAgain.cache.tracks.first(where: { $0.path == playlistSong.path })?.id == playlistID,
                 "Repeated overlapping scans must preserve playlist identity")
    // Moving a child while the parent remains must follow files that actually moved.
    let movedChild = base.appendingPathComponent("RelocatedChild")
    try FileManager.default.moveItem(at: nested, to: movedChild)
    guard var childHosts = try parent.store.data.readChecked(KnownHosts.self, from: "known_hosts.json"),
          let hostIndex = childHosts.hosts.firstIndex(where: { $0.id == parent.store.hostID }),
          let childIndex = childHosts.hosts[hostIndex].sources.firstIndex(where: { $0.path == nested.path }) else {
        fatalError("Missing nested source")
    }
    childHosts.hosts[hostIndex].sources[childIndex].path = movedChild.path
    try parent.store.data.write(childHosts, to: "known_hosts.json")
    let childMoved = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    precondition(childMoved.cache.tracks.first(where: { $0.path == movedChild.appendingPathComponent("Favorite.wav").path })?.id == nestedID &&
                 childMoved.cache.tracks.first(where: { $0.path == movedChild.appendingPathComponent("Playlist.wav").path })?.id == playlistID,
                 "Moving a child source must follow moved files despite an overlapping parent")
    try FileManager.default.moveItem(at: movedChild, to: nested)
    childHosts.hosts[hostIndex].sources[childIndex].path = nested.path
    try parent.store.data.write(childHosts, to: "known_hosts.json")
    _ = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    // Both paths can be unavailable at first; resolve one song, then move the source again.
    try FileManager.default.removeItem(at: nestedSong)
    try FileManager.default.removeItem(at: playlistSong)
    try FileManager.default.moveItem(at: nested, to: movedChild)
    childHosts.hosts[hostIndex].sources[childIndex].path = movedChild.path
    try parent.store.data.write(childHosts, to: "known_hosts.json")
    let deferredMove = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    let childID = childHosts.hosts[hostIndex].sources[childIndex].id.uuidString
    precondition(deferredMove.cache.sourcePaths?[childID] == movedChild.path && deferredMove.cache.sourcePathHistory?[childID]?.contains(nested.path) == true,
                 "An unresolved relocation must remember its old root")
    try wav.write(to: movedChild.appendingPathComponent("Favorite.wav"))
    let partial = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    precondition(partial.cache.tracks.first(where: { $0.path == movedChild.appendingPathComponent("Favorite.wav").path })?.id == nestedID &&
                 partial.cache.sourcePathHistory?[childID]?.contains(nested.path) == true,
                 "A partially resolved source must preserve both visible and offline identities")
    let movedAgain = base.appendingPathComponent("RelocatedAgain")
    try FileManager.default.moveItem(at: movedChild, to: movedAgain)
    childHosts.hosts[hostIndex].sources[childIndex].path = movedAgain.path
    try parent.store.data.write(childHosts, to: "known_hosts.json")
    let twiceMoved = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    precondition(twiceMoved.cache.tracks.first(where: { $0.path == movedAgain.appendingPathComponent("Favorite.wav").path })?.id == nestedID &&
                 twiceMoved.cache.sourcePathHistory?[childID]?.contains(nested.path) == true,
                 "A second move must preserve the song resolved at the first destination")
    try wav.write(to: movedAgain.appendingPathComponent("Playlist.wav"))
    let deferredRestored = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    precondition(deferredRestored.cache.tracks.first(where: { $0.path == movedAgain.appendingPathComponent("Favorite.wav").path })?.id == nestedID &&
                 deferredRestored.cache.tracks.first(where: { $0.path == movedAgain.appendingPathComponent("Playlist.wav").path })?.id == playlistID &&
                 deferredRestored.cache.sourcePathHistory?[childID] == nil,
                 "Returning both songs must recover identities and clear resolved roots")
    try FileManager.default.moveItem(at: movedAgain, to: nested)
    childHosts.hosts[hostIndex].sources[childIndex].path = nested.path
    try parent.store.data.write(childHosts, to: "known_hosts.json")
    _ = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    // Removing the parent while both old and new child paths are unavailable preserves the child.
    try FileManager.default.removeItem(at: nestedSong)
    try FileManager.default.removeItem(at: playlistSong)
    try FileManager.default.moveItem(at: nested, to: movedChild)
    childHosts.hosts[hostIndex].sources[childIndex].path = movedChild.path
    try parent.store.data.write(childHosts, to: "known_hosts.json")
    _ = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    guard let parentSource = childHosts.hosts[hostIndex].sources.first(where: { $0.path == music.path }) else { fatalError("Missing parent") }
    try parent.store.removeSource(id: parentSource.id)
    let withoutParent = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    precondition(withoutParent.cache.offlineTracks?.contains(where: { $0.id == nestedID }) == true,
                 "Removing a parent must retain unresolved child identity")
    try wav.write(to: movedChild.appendingPathComponent("Favorite.wav"))
    try wav.write(to: movedChild.appendingPathComponent("Playlist.wav"))
    let restoredWithoutParent = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    precondition(restoredWithoutParent.cache.tracks.first(where: { $0.path == movedChild.appendingPathComponent("Favorite.wav").path })?.id == nestedID &&
                 restoredWithoutParent.cache.tracks.first(where: { $0.path == movedChild.appendingPathComponent("Playlist.wav").path })?.id == playlistID,
                 "A child must regain both identities after parent removal")
    try FileManager.default.moveItem(at: movedChild, to: nested)
    childHosts.hosts[hostIndex].sources[childIndex].path = nested.path
    try parent.store.data.write(childHosts, to: "known_hosts.json")
    _ = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    try FileManager.default.removeItem(at: nestedSong)
    try FileManager.default.removeItem(at: playlistSong)
    let offline = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    // Moving the parent must not relocate an offline track still covered by the child source.
    let relocatedParent = base.appendingPathComponent("RelocatedParent")
    _ = try parent.store.register(name: "Test", musicFolder: relocatedParent)
    let parentMoved = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    precondition(parentMoved.cache.offlineTracks?.contains(where: { $0.id == nestedID && $0.path == nestedSong.path }) == true,
                 "A remaining nested source must keep its offline favorite at the old path")
    try wav.write(to: nestedSong)
    let childStillPresent = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    precondition(childStillPresent.cache.tracks.first(where: { $0.path == nestedSong.path })?.id == nestedID,
                 "The remaining child source must restore the same track after its parent moves")
    _ = try parent.store.register(name: "Test", musicFolder: music)
    try FileManager.default.removeItem(at: nestedSong)
    _ = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    let registry = try parent.store.data.readChecked(KnownHosts.self, from: "known_hosts.json")
    guard let parentID = registry?.hosts.first(where: { $0.id == parent.store.hostID })?.sources.first(where: { $0.path == music.path })?.id else {
        fatalError("Missing parent source")
    }
    try parent.store.removeSource(id: parentID)
    let immediate = try await PortableLoading.load(refresh: true, removedKind: .music, removedSourcePath: music.path, root: root, legacyLibraryURL: noLegacy)
    precondition(immediate.cache.tracks.isEmpty && immediate.cache.favoriteReferences?.contains(where: { $0.id == nestedID }) == true,
                 "Removing a parent must retain an offline favorite covered by its child source")
    // Restore the cache state from before the removal to model an interrupted refresh and restart.
    try parent.store.save(offline.cache)
    let restarted = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    precondition(restarted.cache.tracks.isEmpty && restarted.cache.favoriteReferences?.contains(where: { $0.id == nestedID }) == true,
                 "Restart reconciliation must retain a favorite covered by a remaining source")
    try wav.write(to: nestedSong)
    try wav.write(to: playlistSong)
    let nestedRestored = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    precondition(nestedRestored.cache.tracks.first(where: { $0.path == nestedSong.path })?.id == nestedID &&
                 nestedRestored.cache.tracks.first(where: { $0.path == nestedSong.path })?.isFavorite == true,
                 "Returning media under a remaining child source must recover its identity and favorite")
    let recoveredFavorite = nestedRestored.cache.tracks.first(where: { $0.path == nestedSong.path })
    precondition(recoveredFavorite?.rating == 4 && recoveredFavorite?.playCount == 12 && recoveredFavorite?.dateAdded == Date(timeIntervalSince1970: 1_000),
                 "Unavailable music must preserve its rating, play count and date added")
    precondition(nestedRestored.cache.tracks.first(where: { $0.path == playlistSong.path })?.id == playlistID &&
                 nestedRestored.cache.playlists.first(where: { $0.name == "Offline" })?.trackIDs == [playlistID],
                 "Unavailable non-favorites must retain playlist identity")
    // Relocation with an offline first scan must keep full identity and user metadata.
    try FileManager.default.removeItem(at: nestedSong)
    try FileManager.default.removeItem(at: playlistSong)
    let movedRoot = music.appendingPathComponent("Moved")
    try FileManager.default.moveItem(at: nested, to: movedRoot)
    _ = try nestedRestored.store.register(name: "Test", musicFolder: movedRoot)
    let movedOffline = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    precondition(movedOffline.cache.tracks.isEmpty && movedOffline.cache.offlineTracks?.contains(where: { $0.id == playlistID && $0.path.hasPrefix(movedRoot.path + "/") }) == true,
                 "An offline relocation must retain playlist identities at the new location")
    var changedWav = wav; changedWav.append(0)
    let movedFavorite = movedRoot.appendingPathComponent("Favorite.wav")
    let movedPlaylist = movedRoot.appendingPathComponent("Playlist.wav")
    try changedWav.write(to: movedFavorite)
    try changedWav.write(to: movedPlaylist)
    let movedBack = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
    let movedTrack = movedBack.cache.tracks.first { $0.path == movedFavorite.path }
    precondition(movedTrack?.id == nestedID && movedTrack?.rating == 4 && movedTrack?.playCount == 12 && movedTrack?.dateAdded == Date(timeIntervalSince1970: 1_000),
                 "Relocation and metadata extraction must preserve favorite identity and user metadata")
    precondition(movedBack.cache.tracks.first(where: { $0.path == movedPlaylist.path })?.id == playlistID &&
                 movedBack.cache.playlists.first(where: { $0.name == "Offline" })?.trackIDs == [playlistID],
                 "A non-favorite playlist track must retain identity after offline relocation")
    let current = removed.store.hostFolder.url.appendingPathComponent("library.json")
    let backup = removed.store.hostFolder.url.appendingPathComponent("library.json.bak")
    let broken = Data("{broken".utf8)
    try broken.write(to: current); try broken.write(to: backup)
    do {
        _ = try await PortableLoading.load(refresh: true, root: root, legacyLibraryURL: noLegacy)
        fatalError("Corrupt libraries must fail instead of being replaced")
    } catch {
        let currentBytes = try Data(contentsOf: current)
        let backupBytes = try Data(contentsOf: backup)
        precondition(currentBytes == broken && backupBytes == broken,
                     "Corrupt library and backup must remain untouched")
    }
    log("PASS: portable loader preserves offline favorites, explicit removal and corrupt caches")
}
#endif
