import CoreImage
import CoreGraphics

/// On-device blur scoring based on edge energy (CoreImage).
///
/// Blur is a global statistic, so it is evaluated on a small thumbnail —
/// this keeps the `CIEdges` pass ~9x cheaper on full-resolution input.
public enum BlurDetector: Sendable {
    /// Evaluation scale in points. Cached scores are tied to this scale:
    /// changing it would mix metrics under one threshold, so tune
    /// `VisionSimilarityConfig.blurThreshold` only.
    public static let targetSide: CGFloat = 96
    /// Mean luminance below this marks near-black frames, which have almost
    /// no edges and would falsely classify as blurred.
    public static let nearBlackLuminance: Float = 0.06

    private static let sharedCIContext = CIContext(options: [.cacheIntermediates: false])

    /// Edge energy of `image`; lower means blurrier. Returns `.infinity`
    /// when the image cannot be evaluated (or is near-black, which would
    /// otherwise look falsely blurred).
    public static func computeBlurScore(for image: CIImage) -> Float {
        let maxSide = max(image.extent.width, image.extent.height)
        let ciImage: CIImage
        if maxSide > targetSide {
            let scale = targetSide / maxSide
            ciImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            ciImage = image
        }

        if meanLuminance(of: ciImage) < nearBlackLuminance {
            return .infinity
        }

        guard let edgesFilter = CIFilter(name: "CIEdges") else { return .infinity }
        edgesFilter.setValue(ciImage, forKey: kCIInputImageKey)
        edgesFilter.setValue(10.0, forKey: kCIInputIntensityKey)
        guard let edgesImage = edgesFilter.outputImage else { return .infinity }

        guard let avgFilter = CIFilter(name: "CIAreaAverage") else { return .infinity }
        avgFilter.setValue(edgesImage, forKey: kCIInputImageKey)
        avgFilter.setValue(CIVector(cgRect: ciImage.extent), forKey: kCIInputExtentKey)
        guard let output = avgFilter.outputImage else { return .infinity }

        var result: [Float] = [0, 0, 0, 0]
        Self.sharedCIContext.render(
            output,
            toBitmap: &result,
            rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )
        return result[0] + result[1] + result[2]
    }

    /// Rec. 709 mean luma of `ciImage`.
    static func meanLuminance(of ciImage: CIImage) -> Float {
        guard let avgFilter = CIFilter(name: "CIAreaAverage") else { return 1 }
        avgFilter.setValue(ciImage, forKey: kCIInputImageKey)
        avgFilter.setValue(CIVector(cgRect: ciImage.extent), forKey: kCIInputExtentKey)
        guard let output = avgFilter.outputImage else { return 1 }
        var result: [Float] = [0, 0, 0, 0]
        Self.sharedCIContext.render(
            output,
            toBitmap: &result,
            rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )
        return 0.2126 * result[0] + 0.7152 * result[1] + 0.0722 * result[2]
    }
}
