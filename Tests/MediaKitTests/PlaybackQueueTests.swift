import XCTest
@testable import MediaKit

final class PlaybackQueueTests: XCTestCase {
    func testSnapshotAndBoundaries() {
        var q = PlaybackQueue()
        q.start(ids: ["c", "b", "a", "b"], at: "b")
        XCTAssertEqual(q.ids, ["c", "b", "a"])
        XCTAssertEqual(q.next(), "a")
        XCTAssertNil(q.next(automatic: true))
        XCTAssertEqual(q.previous(), "b")
        q.clear()
        XCTAssertNil(q.next()); XCTAssertNil(q.previous())
    }
    func testRepeatAndManualSkip() {
        var q = PlaybackQueue()
        q.start(ids: ["a", "b"], at: "a")
        q.repeatMode = .one
        XCTAssertEqual(q.next(automatic: true), "a")
        XCTAssertEqual(q.next(), "b")
        q.repeatMode = .all
        XCTAssertEqual(q.next(automatic: true), "a")
        XCTAssertEqual(q.previous(), "b")
    }
    func testShuffleRetainsCurrentAndRestoresDisplayedOrder() {
        var q = PlaybackQueue()
        q.start(ids: ["a", "b", "c", "d"], at: "c")
        q.setShuffled(true)
        XCTAssertEqual(q.current, "c")
        XCTAssertEqual(Set(q.ids), Set(["a", "b", "c", "d"]))
        let next = q.next()
        q.setShuffled(false)
        XCTAssertEqual(q.ids, ["a", "b", "c", "d"])
        XCTAssertEqual(q.current, next)
    }
}
