import CoreGraphics
import Vision

/// Reads text from a page image, for scanned PDFs.
public protocol Ocr: Sendable {
    func lines(_ image: CGImage) throws -> [Line]
}

/// On-device recognition with the Vision framework (no network, no download). Output lines go
/// through the same `Reflow` as PDF text, with pixel coordinates and the line height standing in
/// for font size, exactly like the ML Kit path on Android.
public struct VisionOcr: Ocr {
    public init() {}

    public func lines(_ image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let w = Float(image.width)
        let h = Float(image.height)
        return (request.results ?? []).compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            let box = obs.boundingBox // normalized, origin bottom-left
            return Line(
                spans: [Span(text)],
                x: Float(box.minX) * w,
                endX: Float(box.maxX) * w,
                y: (1 - Float(box.minY)) * h,
                fontSize: Float(box.height) * h
            )
        }
    }
}
