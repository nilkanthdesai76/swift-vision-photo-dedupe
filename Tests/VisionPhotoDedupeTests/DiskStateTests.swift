import XCTest
@testable import VisionPhotoDedupe

final class DiskStateTests: XCTestCase {

    func testVisionDiskStateRoundTrip() throws {
        let state = VisionDiskState(
            entries: ["photo-1": Data([0x01, 0x02])],
            blurScores: ["photo-1": 0.42],
            revision: 3,
            quality: FeaturePrintIndexer.fingerprintQualityVersion,
            groups: VisionGroupsDiskPayload(
                revision: 3,
                minPercent: VisionSimilarityConfig.minimumPercent,
                maxDistance: VisionSimilarityConfig.maxDistance,
                duplicatePercent: VisionSimilarityConfig.duplicatePercent,
                indexedIds: ["photo-1", "photo-2"],
                clusters: [
                    VisionGroupsDiskPayload.Cluster(
                        representativeId: "photo-1",
                        members: [
                            VisionGroupsDiskPayload.Member(id: "photo-1", distance: 0),
                            VisionGroupsDiskPayload.Member(id: "photo-2", distance: 0.05),
                        ]
                    )
                ],
                duplicateClusters: []
            )
        )

        let data = try DiskStateCodec.encode(state)
        let decoded = try DiskStateCodec.decode(VisionDiskState.self, from: data)

        XCTAssertEqual(decoded.entries["photo-1"], Data([0x01, 0x02]))
        XCTAssertEqual(decoded.blurScores["photo-1"], 0.42)
        XCTAssertEqual(decoded.quality, FeaturePrintIndexer.fingerprintQualityVersion)
        XCTAssertEqual(decoded.groups?.clusters.count, 1)
        XCTAssertEqual(decoded.groups?.clusters.first?.members.count, 2)
    }

    func testVisionDiskStateBackwardCompatibilityWithoutGroups() throws {
        // Simulates older saved JSON without the optional `groups` field.
        let json = """
        {
            "entries": {"photo-1": "AQID"},
            "blurScores": {},
            "revision": 1,
            "quality": 3
        }
        """

        let decoded = try DiskStateCodec.decode(
            VisionDiskState.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(decoded.entries["photo-1"], Data([0x01, 0x02, 0x03]))
        XCTAssertNil(decoded.groups)
    }

    func testVideoVisionDiskStateSerialization() throws {
        let dummyData1 = Data([0x01, 0x02, 0x03])
        let dummyData2 = Data([0x04, 0x05, 0x06])
        let state = VideoVisionDiskState(
            entries: ["video-1": [dummyData1, dummyData2]],
            revision: 1,
            quality: VideoFeaturePrintConfig.fingerprintQualityVersion
        )

        let data = try DiskStateCodec.encode(state)
        let decoded = try DiskStateCodec.decode(VideoVisionDiskState.self, from: data)

        XCTAssertEqual(decoded.entries["video-1"]?.count, 2)
        XCTAssertEqual(decoded.revision, 1)
        XCTAssertEqual(decoded.quality, VideoFeaturePrintConfig.fingerprintQualityVersion)
    }

    func testDiskStateCodecSaveAndLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("vision-state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let state = VisionDiskState(
            entries: ["a": Data([0x01])],
            blurScores: ["a": 1.5],
            revision: 2,
            quality: 3
        )
        try DiskStateCodec.save(state, to: url)
        let loaded = try DiskStateCodec.load(VisionDiskState.self, from: url)

        XCTAssertEqual(loaded?.entries.count, 1)
        XCTAssertEqual(loaded?.blurScores["a"], 1.5)
    }
}
