import Foundation

/// Codable mirror of the last grouping result. Invalidated together with
/// the feature-print index by Vision revision, thresholds, and indexed-ID set.
public struct VisionGroupsDiskPayload: Codable, Sendable, Hashable {
    public struct Member: Codable, Sendable, Hashable {
        public var id: String
        public var distance: Float

        public init(id: String, distance: Float) {
            self.id = id
            self.distance = distance
        }
    }

    public struct Cluster: Codable, Sendable, Hashable {
        public var representativeId: String
        public var members: [Member]

        public init(representativeId: String, members: [Member]) {
            self.representativeId = representativeId
            self.members = members
        }
    }

    public var revision: Int
    public var minPercent: Int
    public var maxDistance: Float
    public var duplicatePercent: Int
    public var indexedIds: [String]
    public var clusters: [Cluster]
    public var duplicateClusters: [Cluster]

    public init(
        revision: Int,
        minPercent: Int,
        maxDistance: Float,
        duplicatePercent: Int,
        indexedIds: [String],
        clusters: [Cluster],
        duplicateClusters: [Cluster]
    ) {
        self.revision = revision
        self.minPercent = minPercent
        self.maxDistance = maxDistance
        self.duplicatePercent = duplicatePercent
        self.indexedIds = indexedIds
        self.clusters = clusters
        self.duplicateClusters = duplicateClusters
    }
}

/// Photo feature-print index section: archived prints, blur scores, and the
/// last grouping result.
public struct VisionDiskState: Codable, Sendable, Hashable {
    public var entries: [String: Data]
    public var blurScores: [String: Float]
    public var revision: Int
    public var quality: Int
    public var groups: VisionGroupsDiskPayload?

    public init(
        entries: [String: Data],
        blurScores: [String: Float],
        revision: Int,
        quality: Int,
        groups: VisionGroupsDiskPayload? = nil
    ) {
        self.entries = entries
        self.blurScores = blurScores
        self.revision = revision
        self.quality = quality
        self.groups = groups
    }

    public static let empty = VisionDiskState(
        entries: [:],
        blurScores: [:],
        revision: 0,
        quality: 0,
        groups: nil
    )
}

/// Video section: multi-frame feature prints (8 keyframes per video).
public struct VideoVisionDiskState: Codable, Sendable, Hashable {
    public var entries: [String: [Data]]
    public var revision: Int
    public var quality: Int

    public init(entries: [String: [Data]], revision: Int, quality: Int) {
        self.entries = entries
        self.revision = revision
        self.quality = quality
    }

    public static let empty = VideoVisionDiskState(entries: [:], revision: 0, quality: 0)
}

/// JSON encode/decode helpers for the disk-state payloads.
public enum DiskStateCodec: Sendable {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try encode(value).write(to: url, options: .atomic)
    }

    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try decode(type, from: data)
    }
}
