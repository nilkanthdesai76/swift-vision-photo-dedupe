import XCTest
import CoreGraphics
import Vision
@testable import VisionPhotoDedupe

/// End-to-end tests using the real Vision framework: generated CGImages are
/// fingerprinted, indexed, and grouped.
final class SimilarGroupingTests: XCTestCase {

    // MARK: - Helpers

    private func makeSolidImage(
        width: Int = 128,
        height: Int = 128,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// A checkerboard has strong edges everywhere (high edge energy).
    private func makeCheckerImage(width: Int = 128, height: Int = 128, cells: Int = 16) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let cell = CGFloat(width) / CGFloat(cells)
        for row in 0..<cells {
            for column in 0..<cells {
                let dark = (row + column) % 2 == 0
                context.setFillColor(
                    red: dark ? 0 : 1,
                    green: dark ? 0 : 1,
                    blue: dark ? 0 : 1,
                    alpha: 1
                )
                context.fill(
                    CGRect(
                        x: CGFloat(column) * cell,
                        y: CGFloat(row) * cell,
                        width: cell,
                        height: cell
                    )
                )
            }
        }
        return context.makeImage()!
    }

    private func requireVisionSupported() throws {
        let sample = makeSolidImage(red: 0.5, green: 0.5, blue: 0.5)
        try XCTSkipIf(
            FeaturePrintIndexer.computeFeaturePrint(for: sample) == nil,
            "VNGenerateImageFeaturePrintRequest is unavailable in this environment (e.g. headless CI VM without Metal inference context)."
        )
    }

    private func index(_ indexer: FeaturePrintIndexer, _ pairs: [(String, CGImage)]) async {
        for (id, image) in pairs {
            await indexer.index(cgImage: image, for: id)
        }
    }

    // MARK: - Tests

    func testIdenticalImagesGroupAsDuplicates() async throws {
        try requireVisionSupported()
        let indexer = FeaturePrintIndexer()
        let photoA = makeSolidImage(red: 0.9, green: 0.2, blue: 0.2)
        let photoB = makeSolidImage(red: 0.1, green: 0.2, blue: 0.9)

        await index(indexer, [
            ("a", photoA),
            ("a-copy", photoA),
            ("b", photoB),
        ])

        let dates = [
            "a": Date(timeIntervalSince1970: 0),
            "a-copy": Date(timeIntervalSince1970: 60),
            "b": Date(timeIntervalSince1970: 120),
        ]
        let result = await indexer.findSimilarGroups(
            assetIDs: ["a", "a-copy", "b"],
            creationDates: dates,
            persistGroups: false
        )

        // The identical pair is an exact duplicate and therefore also similar.
        XCTAssertEqual(result.duplicates.count, 1)
        let duplicateIDs = Set(result.duplicates.first?.members.map(\.identifier) ?? [])
        XCTAssertEqual(duplicateIDs, ["a", "a-copy"])
        XCTAssertEqual(result.duplicates.first?.representativeId, "a")

        let similarIDs = Set(result.similar.first?.members.map(\.identifier) ?? [])
        XCTAssertEqual(similarIDs, ["a", "a-copy"])
    }

    func testDistinctImagesDoNotGroup() async throws {
        try requireVisionSupported()
        let indexer = FeaturePrintIndexer()
        await index(indexer, [
            ("red", makeSolidImage(red: 1, green: 0, blue: 0)),
            ("green", makeSolidImage(red: 0, green: 1, blue: 0)),
            ("blue", makeSolidImage(red: 0, green: 0, blue: 1)),
        ])

        let result = await indexer.findSimilarGroups(
            assetIDs: ["red", "green", "blue"],
            creationDates: [
                "red": Date(timeIntervalSince1970: 0),
                "green": Date(timeIntervalSince1970: 60),
                "blue": Date(timeIntervalSince1970: 120),
            ],
            persistGroups: false
        )

        XCTAssertTrue(result.similar.isEmpty)
        XCTAssertTrue(result.duplicates.isEmpty)
    }

    func testProgressEndsAtCompleteResult() async throws {
        try requireVisionSupported()
        let indexer = FeaturePrintIndexer()
        await index(indexer, [
            ("a", makeSolidImage(red: 0.9, green: 0.2, blue: 0.2)),
            ("a-copy", makeSolidImage(red: 0.9, green: 0.2, blue: 0.2)),
        ])

        final class ProgressBox: @unchecked Sendable {
            var lastFraction: Double = 0
            var finalResult: VisionGroupingResult?
        }
        let box = ProgressBox()
        _ = await indexer.findSimilarGroups(
            assetIDs: ["a", "a-copy"],
            creationDates: [
                "a": Date(timeIntervalSince1970: 0),
                "a-copy": Date(timeIntervalSince1970: 60),
            ],
            persistGroups: false,
            onProgress: { fraction, result in
                box.lastFraction = max(box.lastFraction, fraction)
                if result != nil { box.finalResult = result }
            }
        )

        XCTAssertEqual(box.lastFraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(box.finalResult?.duplicates.count, 1)
    }

    func testIncrementalMergeAttachesNewDuplicate() async throws {
        try requireVisionSupported()
        let indexer = FeaturePrintIndexer()
        let original = makeSolidImage(red: 0.2, green: 0.9, blue: 0.4)

        await index(indexer, [("a", original), ("b", original)])
        let first = await indexer.findSimilarGroups(
            assetIDs: ["a", "b"],
            creationDates: [
                "a": Date(timeIntervalSince1970: 0),
                "b": Date(timeIntervalSince1970: 60),
            ],
            persistGroups: true
        )
        XCTAssertEqual(first.duplicates.first?.members.count, 2)

        // A third identical photo arrives after the cached groups were built.
        await index(indexer, [("c", original)])
        let merged = await indexer.mergeNewPhotosIntoCachedGroups(
            newIDs: ["c"],
            creationDates: [
                "a": Date(timeIntervalSince1970: 0),
                "b": Date(timeIntervalSince1970: 60),
                "c": Date(timeIntervalSince1970: 120),
            ]
        )

        XCTAssertNotNil(merged)
        XCTAssertEqual(merged?.duplicates.count, 1)
        let memberIDs = Set(merged?.duplicates.first?.members.map(\.identifier) ?? [])
        XCTAssertEqual(memberIDs, ["a", "b", "c"])
    }

    func testCachedGroupsInvalidAfterReset() async throws {
        try requireVisionSupported()
        let indexer = FeaturePrintIndexer()
        let original = makeSolidImage(red: 0.2, green: 0.4, blue: 0.9)
        await index(indexer, [("a", original), ("b", original)])
        _ = await indexer.findSimilarGroups(
            assetIDs: ["a", "b"],
            creationDates: [
                "a": Date(timeIntervalSince1970: 0),
                "b": Date(timeIntervalSince1970: 60),
            ],
            persistGroups: true
        )
        let cachedBeforeReset = await indexer.loadCachedGroups()
        XCTAssertNotNil(cachedBeforeReset)

        await indexer.reset()
        let cachedAfterReset = await indexer.loadCachedGroups()
        XCTAssertNil(cachedAfterReset)
    }

    // MARK: - Blur & eligibility

    func testNearBlackImageIsNotBlurry() {
        let black = CIImage(cgImage: makeSolidImage(red: 0.005, green: 0.005, blue: 0.005))
        XCTAssertEqual(BlurDetector.computeBlurScore(for: black), .infinity)
    }

    func testSharpImageHasFiniteEdgeEnergy() {
        let checker = CIImage(cgImage: makeCheckerImage())
        let score = BlurDetector.computeBlurScore(for: checker)
        XCTAssertTrue(score.isFinite)
        XCTAssertGreaterThan(score, 0)
    }

    func testBlurryPhotoIDsUseThreshold() async {
        let indexer = FeaturePrintIndexer()
        // Feed blur scores directly (bypassing image rendering).
        await indexer.setBlurScore(0.30, for: "sharp")
        await indexer.setBlurScore(0.10, for: "blurry")

        let blurry = await indexer.blurryPhotoIDs()
        XCTAssertEqual(blurry.map(\.identifier), ["blurry"])
    }

    func testPhotoScanEligibility() {
        XCTAssertFalse(PhotoScanEligibility.isEligible(
            pixelWidth: 1, pixelHeight: 1000, fileSize: 0, hasKnownFileSize: false
        ))
        XCTAssertFalse(PhotoScanEligibility.isEligible(
            pixelWidth: 100, pixelHeight: 100, fileSize: 1_000, hasKnownFileSize: true
        ))
        XCTAssertTrue(PhotoScanEligibility.isEligible(
            pixelWidth: 100, pixelHeight: 100, fileSize: 1_000, hasKnownFileSize: false
        ))
    }
}
