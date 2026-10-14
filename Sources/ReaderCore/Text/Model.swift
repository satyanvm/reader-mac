import Foundation

/// A run of text in one style.
public struct Span: Hashable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool

    public init(_ text: String, bold: Bool = false, italic: Bool = false) {
        self.text = text
        self.bold = bold
        self.italic = italic
    }
}

/// One visual line from a page, from PDF text or OCR. Coordinates are in any consistent unit
/// (PDF points or image pixels); only their ratios to `fontSize` matter. `y` grows downward.
public struct Line: Hashable, Sendable {
    public var spans: [Span]
    public var x: Float
    public var endX: Float
    public var y: Float
    public var fontSize: Float

    public init(spans: [Span], x: Float, endX: Float, y: Float, fontSize: Float) {
        self.spans = spans
        self.x = x
        self.endX = endX
        self.y = y
        self.fontSize = fontSize
    }

    public var text: String { spans.map(\.text).joined() }
}

/// A unit of flowing text.
public struct Block: Hashable, Sendable {
    /// `note` is a footnote, moved to the end of its page (PDF flowing text only).
    public enum Kind: String, Sendable { case paragraph = "PARAGRAPH", heading = "HEADING", image = "IMAGE", note = "NOTE" }

    public var kind: Kind
    public var spans: [Span]
    /// First line was indented in the source (only meaningful for paragraphs).
    public var indented: Bool
    /// Continues a paragraph from the previous page: render without a first-line indent.
    public var continuation: Bool
    /// For `.image`: a path inside the book.
    public var image: String?

    public init(_ kind: Kind, spans: [Span] = [], indented: Bool = false, continuation: Bool = false, image: String? = nil) {
        self.kind = kind
        self.spans = spans
        self.indented = indented
        self.continuation = continuation
        self.image = image
    }

    public var text: String { spans.map(\.text).joined() }
}

/// One source page (PDF) as flowing text. Empty means no text was found (e.g. a figure).
public struct PageText: Hashable, Sendable {
    public var blocks: [Block]
    public var recognized: Bool

    public init(blocks: [Block], recognized: Bool = false) {
        self.blocks = blocks
        self.recognized = recognized
    }

    public var isEmpty: Bool { blocks.isEmpty }

    /// Same JSON shape as the Android cache files.
    public func json() throws -> Data {
        let blocks: [[String: Any]] = self.blocks.map { b in
            [
                "k": b.kind.rawValue,
                "i": b.indented,
                "c": b.continuation,
                "img": b.image ?? NSNull(),
                "s": b.spans.map { ["t": $0.text, "b": $0.bold, "it": $0.italic] },
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["recognized": recognized, "blocks": blocks])
    }

    public static func from(json data: Data) throws -> PageText {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = o["blocks"] as? [[String: Any]] else {
            throw PositionJSON.DecodeError(description: "bad page text")
        }
        let blocks = try arr.map { b -> Block in
            guard let k = (b["k"] as? String).flatMap(Block.Kind.init(rawValue:)) else {
                throw PositionJSON.DecodeError(description: "bad block kind")
            }
            let spans = (b["s"] as? [[String: Any]] ?? []).map {
                Span($0["t"] as? String ?? "", bold: $0["b"] as? Bool ?? false, italic: $0["it"] as? Bool ?? false)
            }
            return Block(k, spans: spans, indented: b["i"] as? Bool ?? false,
                         continuation: b["c"] as? Bool ?? false, image: b["img"] as? String)
        }
        return PageText(blocks: blocks, recognized: o["recognized"] as? Bool ?? false)
    }
}

public extension Array where Element == Span {
    /// Merges adjacent spans with the same style.
    func compact() -> [Span] {
        var out: [Span] = []
        out.reserveCapacity(count)
        for s in self where !s.text.isEmpty {
            if let last = out.last, last.bold == s.bold, last.italic == s.italic {
                out[out.count - 1].text += s.text
            } else {
                out.append(s)
            }
        }
        return out
    }
}
