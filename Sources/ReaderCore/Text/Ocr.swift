import CoreGraphics
import OSLog
import Vision

/// Reads text from a page image, for scanned PDFs.
public protocol Ocr: Sendable {
    func lines(_ image: CGImage) throws -> [Line]
    /// Like `lines`, and says whether a lower-quality fallback recognizer produced them.
    func recognize(_ image: CGImage) throws -> OcrResult
}

public struct OcrResult: Sendable {
    public var lines: [Line]
    /// Read by a fallback (the fast recognizer) because the accurate one failed. Readable but
    /// full of misread letters, so it's shown for now and not cached: the page is read again
    /// next time, when the accurate model may load.
    public var degraded: Bool

    public init(lines: [Line], degraded: Bool = false) {
        self.lines = lines
        self.degraded = degraded
    }
}

extension Ocr {
    public func recognize(_ image: CGImage) throws -> OcrResult { OcrResult(lines: try lines(image)) }
}

/// On-device recognition with the Vision framework (no network, no download). Output lines go
/// through the same `Reflow` as PDF text, with pixel coordinates and the line height standing in
/// for font size, exactly like the ML Kit path on Android.
public struct VisionOcr: Ocr {
    public init() {}

    private static let log = Logger(subsystem: "io.github.satyanvm.reader", category: "ocr")

    public func lines(_ image: CGImage) throws -> [Line] { try recognize(image).lines }

    public func recognize(_ image: CGImage) throws -> OcrResult {
        // The newest accurate model fails to load on some macOS builds ("e5rt ... failed"), so fall
        // back to the previous accurate revision, then to the fast recognizer.
        let attempts: [(VNRecognizeTextRequest) -> Void] = [
            { $0.recognitionLevel = .accurate },
            { $0.recognitionLevel = .accurate; $0.revision = VNRecognizeTextRequestRevision3 },
            { $0.recognitionLevel = .fast },
        ]
        var lastError: Error?
        for (i, configure) in attempts.enumerated() {
            let request = VNRecognizeTextRequest()
            request.usesLanguageCorrection = true
            configure(request)
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
                let lines = lines(request.results ?? [], width: Float(image.width), height: Float(image.height))
                return OcrResult(lines: lines, degraded: i == attempts.count - 1)
            } catch {
                Self.log.error("Text recognition (level \(request.recognitionLevel.rawValue), revision \(request.revision)) failed: \(error, privacy: .public)")
                lastError = error
            }
        }
        throw lastError ?? CocoaError(.featureUnsupported)
    }

    private func lines(_ observations: [VNRecognizedTextObservation], width w: Float, height h: Float) -> [Line] {
        let lines = observations.compactMap { obs -> Line? in
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
        return Self.evenedOut(lines).sorted { ($0.y, $0.x) < ($1.y, $1.x) } // top to bottom, left to right
    }

    /// A recognized line's box height swings by half again with capitals, quotes and descenders,
    /// which would read as larger type (a heading). The average character width is steady across
    /// body lines (within about 13%), so type size is judged by that: lines near the page's
    /// typical width get the page's body size; clearly wider or narrower type is scaled from it.
    static func evenedOut(_ lines: [Line]) -> [Line] {
        guard lines.count >= 3 else { return lines }
        func median(_ v: [Float]) -> Float { v.sorted()[v.count / 2] }
        let body = median(lines.map(\.fontSize))
        let charWidth = { (l: Line) in (l.endX - l.x) / Float(max(1, l.text.count)) }
        let typical = median(lines.map(charWidth))
        guard typical > 0 else { return lines }
        return lines.map { line in
            var l = line
            let ratio = charWidth(line) / typical
            // A word or two is too short to measure reliably.
            l.fontSize = line.text.count < 6 || (ratio > 0.85 && ratio < 1.25) ? body : body * ratio
            return l
        }
    }
}
