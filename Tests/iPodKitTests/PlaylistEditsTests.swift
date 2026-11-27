import Foundation
import Testing
@testable import iPodKit

@Suite struct PlaylistEditsTests {
    let folder = LibraryPlaylist(name: "Folder", isFolder: true)
    let a = LibraryPlaylist(name: "A")
    let b = LibraryPlaylist(name: "B")
    let c = LibraryPlaylist(name: "C")

    private func names(_ list: [LibraryPlaylist]) -> [String] { list.map(\.name) }

    @Test func moveIntoFolderAtIndex() {
        var list = [folder, a, b, c]
        list[2].parentID = folder.id // B is in Folder
        PlaylistEdits.move(c.id, toFolder: folder.id, atIndex: 0, in: &list)
        #expect(names(list) == ["Folder", "A", "C", "B"])
        #expect(list[2].parentID == folder.id)
    }

    @Test func moveToEndOfSiblings() {
        var list = [a, b, c]
        PlaylistEdits.move(a.id, toFolder: nil, atIndex: 99, in: &list)
        #expect(names(list) == ["B", "C", "A"])
    }

    @Test func moveWithoutIndexKeepsPlace() {
        var list = [a, folder, b]
        PlaylistEdits.move(b.id, toFolder: folder.id, atIndex: nil, in: &list)
        #expect(names(list) == ["A", "Folder", "B"])
        #expect(list[2].parentID == folder.id)
    }

    @Test func foldersAndSelfMovesAreIgnored() {
        var list = [a, folder]
        PlaylistEdits.move(folder.id, toFolder: nil, atIndex: 0, in: &list)
        PlaylistEdits.move(a.id, toFolder: a.id, atIndex: 0, in: &list)
        #expect(list == [a, folder])
    }

    @Test func worksOnStringIDsToo() {
        struct Row: PlaylistTreeNode, Equatable {
            var id: String; var name: String; var isFolder = false
            var parentID: String? = nil; var trackIDs: [String] = []
            var isSubscribed: Bool { false }
        }
        var list = [Row(id: "f", name: "F", isFolder: true), Row(id: "x", name: "X")]
        PlaylistEdits.move("x", toFolder: "f", atIndex: 0, in: &list)
        #expect(list[1].parentID == "f")
    }

    @Test func reorderTracksKeepsMovedOrder() {
        let t = (0..<5).map { _ in UUID() }
        var list = [LibraryPlaylist(name: "P", trackIDs: t)]
        PlaylistEdits.reorderTracks([t[3], t[0]], to: 5, inPlaylist: list[0].id, of: &list)
        #expect(list[0].trackIDs == [t[1], t[2], t[4], t[0], t[3]])
        PlaylistEdits.reorderTracks([t[3]], to: 0, inPlaylist: list[0].id, of: &list)
        #expect(list[0].trackIDs == [t[3], t[1], t[2], t[4], t[0]])
    }

    @Test func addSkipsDuplicatesAndSubscriptions() {
        let t1 = UUID(), t2 = UUID()
        var subscribed = LibraryPlaylist(name: "S"); subscribed.subscriptionID = UUID()
        var list = [LibraryPlaylist(name: "P", trackIDs: [t1]), subscribed]
        PlaylistEdits.addTracks([t1, t2, t2], toPlaylist: list[0].id, of: &list)
        PlaylistEdits.addTracks([t1], toPlaylist: subscribed.id, of: &list)
        #expect(list[0].trackIDs == [t1, t2])
        #expect(list[1].trackIDs.isEmpty)
        PlaylistEdits.removeTracks([t1], fromPlaylist: list[0].id, of: &list)
        #expect(list[0].trackIDs == [t2])
    }

    @Test func renameTrimsAndRejectsEmpty() {
        var list = [a]
        PlaylistEdits.rename(a.id, to: "   ", in: &list)
        #expect(list[0].name == "A")
        PlaylistEdits.rename(a.id, to: "  Road  ", in: &list)
        #expect(list[0].name == "Road")
    }

    @Test func reorderKeepsUnlistedAtEnd() {
        var list = [a, b, c]
        PlaylistEdits.reorder([c.id, a.id], in: &list)
        #expect(names(list) == ["C", "A", "B"])
    }

    @Test func uniqueNames() {
        #expect(PlaylistEdits.uniqueName("New Playlist", among: []) == "New Playlist")
        #expect(PlaylistEdits.uniqueName("New Playlist", among: ["New Playlist", "New Playlist 2"]) == "New Playlist 3")
    }
}
