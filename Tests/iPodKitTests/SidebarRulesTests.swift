import Testing
@testable import iPodKit

@Suite struct SidebarRulesTests {
    @Test func dragEligibility() {
        #expect(!SidebarRules.canDrag(siblingCount: 1, inFolder: false, isPlaylist: false))
        #expect(SidebarRules.canDrag(siblingCount: 1, inFolder: false, isPlaylist: true))
        #expect(SidebarRules.canDrag(siblingCount: 2, inFolder: false, isPlaylist: false))
        #expect(SidebarRules.canDrag(siblingCount: 1, inFolder: true, isPlaylist: false))
    }

    @Test func horizontalIntent() {
        #expect(!SidebarRules.isHorizontalIntent(dx: 20, dy: 0))
        #expect(SidebarRules.isHorizontalIntent(dx: -40, dy: 10))
        #expect(!SidebarRules.isHorizontalIntent(dx: 40, dy: 30))
    }

    @Test func insideGroup() {
        #expect(SidebarRules.isInsideGroup(pointerY: 1000, top: 100, bottom: 200, rowHeight: 28, groupIsFolder: false))
        #expect(!SidebarRules.isInsideGroup(pointerY: 1000, top: 100, bottom: 200, rowHeight: 28, groupIsFolder: true))
        #expect(SidebarRules.isInsideGroup(pointerY: 210, top: 100, bottom: 200, rowHeight: 28, groupIsFolder: true))
        #expect(!SidebarRules.isInsideGroup(pointerY: 80, top: 100, bottom: 200, rowHeight: 28, groupIsFolder: false))
    }

    @Test func nearestInsertion() {
        let spans: [(minY: Double, maxY: Double)] = [(0, 28), (28, 56), (56, 84)]
        #expect(SidebarRules.nearestInsertion(spans: spans, to: 3)! == (0, 0))
        #expect(SidebarRules.nearestInsertion(spans: spans, to: 50)! == (2, 56))
        #expect(SidebarRules.nearestInsertion(spans: spans, to: 500)! == (3, 84))
        #expect(SidebarRules.nearestInsertion(spans: [], to: 0) == nil)
    }

    @Test func nearestSlot() {
        #expect(SidebarRules.nearestSlot(midY: 5, heights: [28, 56, 28], top: 0) == 0)
        #expect(SidebarRules.nearestSlot(midY: 60, heights: [28, 56, 28], top: 0) == 1)
        #expect(SidebarRules.nearestSlot(midY: 999, heights: [28, 56, 28], top: 0) == 2)
        #expect(SidebarRules.nearestSlot(midY: 0, heights: [], top: 0) == nil)
    }

    @Test func dropPrecedence() {
        var state = SidebarRules.DragState()
        state.deviceID = "iPod"
        state.folderID = "f"
        #expect(SidebarRules.drop(state, playlistID: "p", movable: true) == .sendToDevice(playlistID: "p", deviceID: "iPod"))
        // Folders can go to an iPod but not into another folder.
        state.deviceID = nil
        #expect(SidebarRules.drop(state, playlistID: "folder", movable: false) == .none)
        #expect(SidebarRules.drop(state, playlistID: "p", movable: true) == .moveToFolder(playlistID: "p", folderID: "f", index: nil))
        state.folderID = nil
        state.folderInsert = ("f", 2)
        #expect(SidebarRules.drop(state, playlistID: "p", movable: true) == .moveToFolder(playlistID: "p", folderID: "f", index: 2))
        state.folderInsert = nil
        state.topLevelIndex = 0
        #expect(SidebarRules.drop(state, playlistID: "p", movable: true) == .moveToFolder(playlistID: "p", folderID: nil, index: 0))
        state.topLevelIndex = nil
        state.reorder = (1, 3)
        #expect(SidebarRules.drop(state, playlistID: nil, movable: false) == .reorder(from: 1, to: 3))
        state.reorder = (1, 1)
        #expect(SidebarRules.drop(state, playlistID: nil, movable: false) == .none)
        state.reorder = (1, 3)
        state.cancelled = true
        #expect(SidebarRules.drop(state, playlistID: "p", movable: true) == .none)
    }

    @Test func playlistActions() {
        #expect(SidebarRules.actions(subscribed: false, syncing: false, sourceName: nil) == [.rename, .delete])
        #expect(SidebarRules.actions(subscribed: true, syncing: false, sourceName: "Spotify")
            == [.refresh, .openSource(name: "Spotify"), .rename, nil, .unsubscribe])
        #expect(SidebarRules.actions(subscribed: true, syncing: true, sourceName: nil) == [.stop, .rename, nil, .unsubscribe])
        #expect(SidebarRules.PlaylistAction.openSource(name: "YouTube").title == "Open in YouTube")
    }
}
