import Foundation

/// Thresholds that define when two Vision feature prints count as
/// "similar" vs "exact duplicates".
///
/// Vision's `VNFeaturePrintObservation.computeDistance(_:to:)` returns a
/// Euclidean distance where `0` means identical. Empirically (and matching
/// Apple's guidance) a distance of `4.0` corresponds to 0% similarity, so
/// similarity percent maps linearly: `percent = (1 - distance / 4) * 100`.
public enum VisionSimilarityConfig: Sendable {
    /// Minimum similarity percent for the "similar" bucket (>= 90%).
    public static let minimumPercent = 90
    /// Minimum similarity percent for the "exact duplicate" bucket (>= 98%).
    public static let duplicatePercent = 98
    /// Distance that maps to 0% similar.
    public static let distanceScale: Float = 4
    /// Max distance for the "similar" bucket (4 * (1 - 0.90) = 0.40).
    public static let maxDistance: Float = 4 * (1 - 90 / 100.0)
    /// Max distance for the "exact duplicate" bucket (4 * (1 - 0.98) = 0.08).
    public static let duplicateMaxDistance: Float = 4 * (1 - 98 / 100.0)
    /// Edge-energy cutoff for blurry photos. Lower score => blurrier.
    /// Scores are cached at `BlurDetector.targetSide` px, so tune via this
    /// threshold only, never via the thumbnail scale.
    public static let blurThreshold: Float = 0.16

    /// Maps a Vision distance to a 0...100 similarity percent.
    public static func percent(from distance: Float) -> Int {
        max(0, min(100, Int((1 - distance / distanceScale) * 100)))
    }
}
