import Foundation

/// One member of a photo cluster with its distance to the representative.
public struct SearchResult: Sendable, Hashable {
    public let identifier: String
    public let distance: Float

    public init(identifier: String, distance: Float) {
        self.identifier = identifier
        self.distance = distance
    }
}

/// A group of photos that are similar (or exact duplicates) of each other.
/// `representativeId` is the cluster medoid — the photo with the smallest
/// total distance to every other member.
public struct VisionPhotoCluster: Sendable, Hashable {
    public let representativeId: String
    public let members: [SearchResult]

    public init(representativeId: String, members: [SearchResult]) {
        self.representativeId = representativeId
        self.members = members
    }
}

/// The full grouping output: "similar" clusters (loose bucket) and
/// "duplicates" clusters (exact-match bucket). Every duplicate cluster is
/// also present in `similar`.
public struct VisionGroupingResult: Sendable, Hashable {
    public let similar: [VisionPhotoCluster]
    public let duplicates: [VisionPhotoCluster]

    public init(similar: [VisionPhotoCluster], duplicates: [VisionPhotoCluster]) {
        self.similar = similar
        self.duplicates = duplicates
    }

    public static let empty = VisionGroupingResult(similar: [], duplicates: [])
}

/// Windowing / concurrency knobs for the match phase. Defaults mirror the
/// values tuned for a large on-device photo library (tens of thousands of
/// photos).
public struct GroupingTuning: Sendable {
    /// Max index distance between two compared photos (chronological hard cap).
    public var hardCap: Int
    /// Max photo-index gap in the chronological lookahead window.
    public var maxLookahead: Int
    /// Max time gap (seconds) that still keeps the lookahead window open.
    public var maxTimeGap: TimeInterval
    /// Number of parallel chunks the seed range is split into.
    public var matchChunkCount: Int
    /// Clusters at or below this size get an exact medoid (all-pairs sum of
    /// distances); larger clusters use their first member as representative.
    public var exactMedoidMemberLimit: Int

    public init(
        hardCap: Int = 150,
        maxLookahead: Int = 100,
        maxTimeGap: TimeInterval = 6 * 60 * 60,
        matchChunkCount: Int = GroupingTuning.defaultMatchChunkCount,
        exactMedoidMemberLimit: Int = 40
    ) {
        self.hardCap = hardCap
        self.maxLookahead = maxLookahead
        self.maxTimeGap = maxTimeGap
        self.matchChunkCount = matchChunkCount
        self.exactMedoidMemberLimit = exactMedoidMemberLimit
    }

    public static let `default` = GroupingTuning()

    /// Adaptive default: one chunk per core, clamped to 2...8.
    public static let defaultMatchChunkCount: Int = {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return min(8, max(2, cores - 2))
    }()
}
