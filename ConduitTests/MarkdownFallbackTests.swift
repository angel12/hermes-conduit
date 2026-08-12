import XCTest
@testable import Conduit

final class MarkdownFallbackTests: XCTestCase {

    func testResolveAcceptsValidHTTPURLWithoutChangingEscapes() throws {
        let destination = try XCTUnwrap(
            WebFallbackImageDestination.resolve(
                "https://example.com/assets/100%20photos.png?size=2#preview"
            )
        )

        XCTAssertEqual(
            destination.absoluteString,
            "https://example.com/assets/100%20photos.png?size=2#preview"
        )
    }

    func testResolveRepairsPathCharactersWithoutCorruptingURLDelimiters() throws {
        let destination = try XCTUnwrap(
            WebFallbackImageDestination.resolve("https://example.com/assets/a b.png#preview")
        )

        XCTAssertEqual(destination.absoluteString, "https://example.com/assets/a%20b.png#preview")
    }

    func testResolvePreservesExistingEscapesWhenRepairingInvalidPercentCharacters() throws {
        let destination = try XCTUnwrap(
            WebFallbackImageDestination.resolve("https://example.com/assets/100%20photos%ZZ.png")
        )

        XCTAssertEqual(
            destination.absoluteString,
            "https://example.com/assets/100%20photos%25ZZ.png"
        )
    }

    func testResolveRejectsMissingHostAndUnsupportedScheme() {
        XCTAssertNil(WebFallbackImageDestination.resolve("https:///image.png"))
        XCTAssertNil(WebFallbackImageDestination.resolve("javascript:alert(1)"))
    }

    func testUnparseableDestinationUsesUnavailableCopy() {
        let destination = WebFallbackImageDestination.resolve("https://[invalid")

        XCTAssertNil(destination)
        XCTAssertEqual(
            WebFallbackImageLabel.title(alt: "", destinationAvailable: destination != nil),
            "Image unavailable"
        )
    }

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
