import Foundation
#if canImport(Photos)
import Photos
#endif

/// Size-based eligibility gates for perceptual (feature print) scanning.
public enum ScanThresholds: Sendable {
    /// Assets below this on either pixel edge are useless for
    /// duplicate/similar/blur analysis (often 0x0 / 1x1 placeholders) and
    /// can stall the image pipeline for a long time.
    public static let photoSignatureMinPixelDimension = 32
    /// Near-empty files (a few KB) are almost never camera photos and
    /// correlate with degenerate-resolution assets.
    public static let photoSignatureMinFileBytes: Int64 = 8_192
    /// Soft cap so one stuck image request cannot block a whole scan pass.
    public static let photoSignatureImageRequestTimeoutSeconds: Double = 2.0
}

public enum PhotoScanEligibility: Sendable {
    /// Pure eligibility check over asset metadata.
    public static func isEligible(
        pixelWidth: Int,
        pixelHeight: Int,
        fileSize: Int64,
        hasKnownFileSize: Bool
    ) -> Bool {
        let minDimension = ScanThresholds.photoSignatureMinPixelDimension
        guard pixelWidth >= minDimension, pixelHeight >= minDimension else {
            return false
        }
        if hasKnownFileSize, fileSize < ScanThresholds.photoSignatureMinFileBytes {
            return false
        }
        return true
    }

    #if canImport(Photos)
    /// PhotoKit convenience wrapper.
    public static func isEligible(_ asset: PHAsset) -> Bool {
        isEligible(
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            fileSize: 0,
            hasKnownFileSize: false
        )
    }
    #endif
}
