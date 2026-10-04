import XCTest
@testable import VisionPhotoDedupe

/// Library inserts used to pass only the new/uncategorized IDs into
/// indexing. That list equalled the print universe, so a naive
/// `printUniverse == decodeSet` prune treated it as the full library and
/// deleted every cached feature print.
final class IndexPruneAndWindowTests: XCTestCase {

    // MARK: - shouldPruneStalePrints

    func testSmallSubsetDoesNotPruneExistingIndex() {
        let existing = Set((0..<3_000).map(String.init))
        let newPhotos: Set<String> = ["new-a", "new-b", "new-c"]
        XCTAssertFalse(
            FeaturePrintIndexer.shouldPruneStalePrints(
                existingIDs: existing,
                decodeIDs: newPhotos
            )
        )
    }

    func testFullLibraryPassPrunesDeletedIDs() {
        var existing = Set((0..<100).map(String.init))
        existing.insert("deleted")
        let currentLibrary = Set((0..<100).map(String.init))
        XCTAssertTrue(
            FeaturePrintIndexer.shouldPruneStalePrints(
                existingIDs: existing,
                decodeIDs: currentLibrary
            )
        )
    }

    func testEmptyIndexNeverPrunes() {
        XCTAssertFalse(
            FeaturePrintIndexer.shouldPruneStalePrints(
                existingIDs: [],
                decodeIDs: ["a"]
            )
        )
    }

    // MARK: - neighborBounds

    func testNeighborBoundsCentersOnInsertionPoint() {
        let dates: [Date] = (0..<10).map { Date(timeIntervalSince1970: TimeInterval($0 * 60)) }
        let target = Date(timeIntervalSince1970: 5 * 60)
        let bounds = FeaturePrintIndexer.neighborBounds(
            target: target,
            sortedDates: dates,
            window: 2
        )
        XCTAssertEqual(bounds, 3..<7)
    }

    func testNeighborBoundsClampsAtEdges() {
        let dates: [Date] = (0..<10).map { Date(timeIntervalSince1970: TimeInterval($0 * 60)) }
        let first = FeaturePrintIndexer.neighborBounds(
            target: Date(timeIntervalSince1970: 0),
            sortedDates: dates,
            window: 3
        )
        XCTAssertEqual(first, 0..<3)
        let last = FeaturePrintIndexer.neighborBounds(
            target: Date(timeIntervalSince1970: 9 * 60),
            sortedDates: dates,
            window: 3
        )
        XCTAssertEqual(last, 6..<10)
    }

    func testNeighborBoundsEmptyDates() {
        XCTAssertTrue(
            FeaturePrintIndexer.neighborBounds(
                target: Date(),
                sortedDates: [],
                window: 10
            ).isEmpty
        )
    }
}
