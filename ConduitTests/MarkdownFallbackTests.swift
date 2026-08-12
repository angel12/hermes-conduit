import XCTest
@testable import Conduit

final class MarkdownFallbackTests: XCTestCase {

    func testUnlinkedImageWithoutAltUsesNonActionCopy() {
        XCTAssertEqual(
            WebFallbackImageLabel.title(alt: "", destinationAvailable: false),
            "Image unavailable"
        )
    }

    func testLinkedImageWithoutAltKeepsOpenActionCopy() {
        XCTAssertEqual(
            WebFallbackImageLabel.title(alt: "", destinationAvailable: true),
            "Open image"
        )
    }
}
