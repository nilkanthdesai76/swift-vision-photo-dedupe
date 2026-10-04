import Foundation
import Vision
import AVFoundation
import CoreGraphics

/// Thresholds and sampling layout for video duplicate/similar detection.
///
/// A video is fingerprinted by 8 keyframes spread across its timeline
/// (avoiding the black frames at the very start/end). Two videos are
/// compared by index-aligned per-frame distances.
public enum VideoFeaturePrintConfig: Sendable {
    /// Bump when fingerprint computation changes so stale prints are discarded.
    public static let fingerprintQualityVersion = 3

    /// Sample fractions across the timeline (8 frames avoiding start/end
    /// black frames).
    public static let samplePercentages: [Double] = [0.10, 0.20, 0.35, 0.50, 0.65, 0.80, 0.90, 0.95]

    /// Per-frame distance <= 0.08 indicates >= 98% visual match.
    public static let duplicateMaxDistance: Float = 0.08
    /// Duplicate videos additionally need an average frame distance <= 0.04.
    public static let duplicateMaxAvgDistance: Float = 0.04
    /// At least this many successfully compared frames for a Vision verdict.
    public static let duplicateMinComparedFrames = 4
    /// Average frame distance <= 0.52 indicates visual similarity across
    /// scenes/bursts/takes.
    public static let similarMaxAvgDistance: Float = 0.52

    /// Duplicate candidates must have near-identical duration (<= 0.5 s and <= 1%).
    public static let duplicateMaxDurationDelta: TimeInterval = 0.5
    public static let duplicateMaxRelativeDurationDelta: Double = 0.01
    /// Byte-identical fallback when keyframes could not be extracted.
    public static let byteFallbackMaxDurationDelta: TimeInterval = 0.05

    /// Similar videos must be within this chronological lookahead window.
    public static let similarLookahead = 100
    /// ...and within this time gap.
    public static let similarMaxTimeGap: TimeInterval = 14_400

    /// Keyframe extraction size (px).
    public static let keyframeMaxSide: CGFloat = 300
    /// Generator tolerance when seeking keyframes.
    public static let keyframeToleranceSeconds: Double = 0.5
}

/// Metadata needed for video grouping, decoupled from PhotoKit.
public struct VideoRow: Sendable, Hashable {
    public let assetID: String
    public let creationDate: Date
    public let duration: TimeInterval
    public let fileSize: Int64

    public init(assetID: String, creationDate: Date, duration: TimeInterval, fileSize: Int64) {
        self.assetID = assetID
        self.creationDate = creationDate
        self.duration = duration
        self.fileSize = fileSize
    }
}

/// Extracts the multi-keyframe images used for video fingerprinting.
public enum VideoKeyframeExtractor: Sendable {
    /// Renders one frame per `VideoFeaturePrintConfig.samplePercentages`
    /// fraction of `duration` from `asset`.
    public static func extractKeyframes(
        from asset: AVAsset,
        duration: TimeInterval
    ) -> [CGImage] {
        guard duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: VideoFeaturePrintConfig.keyframeMaxSide,
            height: VideoFeaturePrintConfig.keyframeMaxSide
        )
        let tolerance = CMTime(
            seconds: VideoFeaturePrintConfig.keyframeToleranceSeconds,
            preferredTimescale: 600
        )
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var frames: [CGImage] = []
        for pct in VideoFeaturePrintConfig.samplePercentages {
            let seconds = duration * pct
            let cmTime = CMTime(seconds: seconds, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) {
                frames.append(cgImage)
            }
        }
        return frames
    }

    /// Computes one feature print per keyframe image.
    public static func computeFeaturePrint(for cgImage: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFit
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }
}

/// Pure video grouping core: consumes metadata rows plus pre-decoded
/// multi-frame feature prints and returns duplicate/similar groups.
public enum VideoGrouping: Sendable {
    /// Full pipeline: exact duplicates first, then similarity over the rest.
    public static func process(
        rows: [VideoRow],
        observations: [String: [VNFeaturePrintObservation]]
    ) -> (duplicates: [[String]], similars: [[String]]) {
        let duplicateGroups = groupDuplicates(rows: rows, observations: observations)
        let duplicateIDs = Set(duplicateGroups.flatMap { $0 })
        let similarGroups = groupSimilars(
            rows: rows,
            observations: observations,
            excludingDuplicateIDs: duplicateIDs
        )
        return (duplicates: duplicateGroups, similars: similarGroups)
    }

    public static func groupDuplicates(
        rows: [VideoRow],
        observations: [String: [VNFeaturePrintObservation]]
    ) -> [[String]] {
        guard rows.count > 1 else { return [] }

        var parent = Array(0..<rows.count)
        func find(_ i: Int) -> Int {
            var root = i
            while parent[root] != root {
                parent[root] = parent[parent[root]]
                root = parent[root]
            }
            return root
        }
        func union(_ i: Int, _ j: Int) {
            let rootI = find(i)
            let rootJ = find(j)
            if rootI != rootJ {
                parent[rootJ] = rootI
            }
        }

        for i in 0..<rows.count {
            let rowA = rows[i]
            for j in (i + 1)..<rows.count {
                let rowB = rows[j]

                let durationDiff = abs(rowA.duration - rowB.duration)
                let maxDuration = max(1.0, max(rowA.duration, rowB.duration))
                let relDurationDiff = durationDiff / maxDuration

                // 1. Must have near-identical duration (<= 0.5s and <= 1%)
                guard durationDiff <= VideoFeaturePrintConfig.duplicateMaxDurationDelta,
                      relDurationDiff <= VideoFeaturePrintConfig.duplicateMaxRelativeDurationDelta
                else {
                    continue
                }

                // 2. Multi-frame Vision match:
                // Require at least 4 distinct compared frames. Every frame
                // must match closely and the overall average must be tight.
                if let obsA = observations[rowA.assetID],
                   let obsB = observations[rowB.assetID],
                   let dist = comparePrints(obsA, obsB),
                   dist.count >= VideoFeaturePrintConfig.duplicateMinComparedFrames,
                   dist.max <= VideoFeaturePrintConfig.duplicateMaxDistance,
                   dist.avg <= VideoFeaturePrintConfig.duplicateMaxAvgDistance {
                    union(i, j)
                    continue
                }

                // 3. Fallback: exact file size + exact duration (byte-identical
                // fallback when frames could not be extracted).
                if rowA.fileSize > 0,
                   rowA.fileSize == rowB.fileSize,
                   durationDiff < VideoFeaturePrintConfig.byteFallbackMaxDurationDelta {
                    union(i, j)
                }
            }
        }

        var groupsMap: [Int: [VideoRow]] = [:]
        for i in 0..<rows.count {
            groupsMap[find(i), default: []].append(rows[i])
        }

        var duplicateGroups: [[String]] = []
        for bucket in groupsMap.values where bucket.count > 1 {
            // Sort by file size descending so the highest-quality/original
            // is first (the keeper).
            let sorted = bucket.sorted { $0.fileSize > $1.fileSize }
            duplicateGroups.append(sorted.map(\.assetID))
        }
        return duplicateGroups
    }

    public static func groupSimilars(
        rows: [VideoRow],
        observations: [String: [VNFeaturePrintObservation]],
        excludingDuplicateIDs duplicateIDs: Set<String>
    ) -> [[String]] {
        let similarRows = rows.filter { !duplicateIDs.contains($0.assetID) }
        guard similarRows.count > 1 else { return [] }

        var parent = Array(0..<similarRows.count)
        func find(_ i: Int) -> Int {
            var root = i
            while parent[root] != root {
                parent[root] = parent[parent[root]]
                root = parent[root]
            }
            return root
        }
        func union(_ i: Int, _ j: Int) {
            let rootI = find(i)
            let rootJ = find(j)
            if rootI != rootJ {
                parent[rootJ] = rootI
            }
        }

        let sorted = similarRows.enumerated().sorted { $0.element.creationDate < $1.element.creationDate }

        for left in 0..<sorted.count {
            let leftItem = sorted[left]
            let leftDate = leftItem.element.creationDate
            let leftObs = observations[leftItem.element.assetID]

            let maxLookahead = min(
                sorted.count,
                left + 1 + VideoFeaturePrintConfig.similarLookahead
            )
            for j in (left + 1)..<maxLookahead {
                let rightItem = sorted[j]
                let rightDate = rightItem.element.creationDate
                let timeGap = rightDate.timeIntervalSince(leftDate)

                if timeGap > VideoFeaturePrintConfig.similarMaxTimeGap {
                    break
                }

                if let leftObs,
                   let rightObs = observations[rightItem.element.assetID],
                   let dist = comparePrints(leftObs, rightObs),
                   dist.avg <= VideoFeaturePrintConfig.similarMaxAvgDistance {
                    union(leftItem.offset, rightItem.offset)
                }
            }
        }

        var similarGroupsMap: [Int: [String]] = [:]
        for i in 0..<similarRows.count {
            similarGroupsMap[find(i), default: []].append(similarRows[i].assetID)
        }
        return Array(similarGroupsMap.values.filter { $0.count > 1 })
    }

    /// Index-aligned per-frame distances between two videos' print lists.
    public static func comparePrints(
        _ a: [VNFeaturePrintObservation],
        _ b: [VNFeaturePrintObservation]
    ) -> (avg: Float, max: Float, count: Int)? {
        guard !a.isEmpty, !b.isEmpty else { return nil }
        let count = min(a.count, b.count)
        var total: Float = 0
        var maxDist: Float = 0
        var comparisons = 0

        for i in 0..<count {
            var d: Float = 0
            if (try? a[i].computeDistance(&d, to: b[i])) != nil {
                total += d
                maxDist = max(maxDist, d)
                comparisons += 1
            }
        }
        guard comparisons > 0 else { return nil }
        return (avg: total / Float(comparisons), max: maxDist, count: comparisons)
    }
}
