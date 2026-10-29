import XCTest
@testable import MediaKit

final class MediaKitTests: XCTestCase {
    func testStableIDsDependOnlyOnRelativePath() {
        XCTAssertEqual(FolderImporter.stableID(for: "A/B.mp3"), FolderImporter.stableID(for: "A/B.mp3"))
        XCTAssertNotEqual(FolderImporter.stableID(for: "A/B.mp3"), FolderImporter.stableID(for: "A/C.mp3"))
    }
}
