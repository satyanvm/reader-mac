import Foundation

/// Turns a page's visual lines into flowing blocks (paragraphs and headings).
///
/// PDFs only record where glyphs sit, so structure is inferred from geometry, the way a typesetter
/// would read it:
///  - a new paragraph starts at an indented line, after extra vertical space, or after a short
///    line that ends a sentence (the ragged last line of a justified paragraph);
///  - noticeably larger type is a heading;
///  - a word hyphenated at a line end is rejoined.
///
/// A direct port of the Android `Reflow`; thresholds and tie-breaks are identical.
public enum Reflow {
    private static let sentenceEndChars: Set<Character> = [".", "!", "?", ":", ";", "'", "\"", "\u{201D}", "\u{2019}", ")", "]"]
    private static let pageNumber = try! NSRegularExpression(
        pattern: #"^(\d{1,4}|[ivxlcdm]{1,7}|page \d+( of \d+)?|- ?\d{1,4} ?-)$"#,
        options: [.caseInsensitive]
    )

    /// Blocks for one page, in reading order. Multi-column pages are read column by column, and
    /// footnotes (smaller type at the foot of a column) come last, as `.note` blocks, so they
    /// never split a paragraph that runs on into the next column or page.
    public static func blocks(_ input: [Line]) -> [Block] {
        let lines = dropPageNumbers(mergeSameRow(
            input.map { var l = $0; l.spans = normalizeSpaces(l.spans); return l }
                .filter { !$0.text.isBlank }
        ))
        if lines.isEmpty { return [] }

        let body = median(lines.map(\.fontSize))
        var out: [Block] = []
        var notes: [Block] = []
        for column in columns(lines, body: body) {
            let (main, foot) = splitFootnotes(column, body: body)
            let blocks = columnBlocks(main, body: body)
            // A paragraph that runs from the foot of one column to the head of the next is one.
            if let last = out.last, let first = blocks.first,
               continues(last, first, nextPageUsesIndents: blocks.contains(where: \.indented)) {
                out[out.count - 1] = merge(last, first)
                out += blocks.dropFirst()
            } else {
                out += blocks
            }
            notes += footnoteBlocks(foot)
        }
        return out + notes
    }

    /// The single-column reflow (the Android algorithm), with margins measured on this column.
    static func columnBlocks(_ lines: [Line], body: Float) -> [Block] {
        if lines.isEmpty { return [] }
        let larger = lines.filter { !isLarger($0.fontSize, body) }
        let bodyLines = larger.isEmpty ? lines : larger
        let left = percentile(bodyLines.map(\.x), 0.1)
        let right = percentile(bodyLines.map(\.endX), 0.75)
        let gaps = zip(bodyLines, bodyLines.dropFirst()).map { $1.y - $0.y }.filter { $0 > 0 }
        let lineGap = gaps.isEmpty ? body * 1.2 : median(gaps)
        let indentMin = body * 0.8

        var blocks: [Block] = []
        var current: [Line] = []
        var currentIndented = false

        func flush() {
            if current.isEmpty { return }
            let heading = current.allSatisfy { isLarger($0.fontSize, body) } ||
                (current.count == 1 && current[0].spans.allSatisfy(\.bold) && current[0].text.utf16.count < 80 &&
                    current[0].x - left > indentMin) // short, bold and centred
            blocks.append(Block(heading ? .heading : .paragraph, spans: join(current), indented: currentIndented && !heading))
            current = []
        }

        for (i, line) in lines.enumerated() {
            let prev = i > 0 ? lines[i - 1] : nil
            let indented = line.x - left > indentMin && line.x - left < (right - left) * 0.5
            var startsNew = true
            if let prev {
                startsNew = isLarger(line.fontSize, body) != isLarger(prev.fontSize, body) ||
                    line.y - prev.y > lineGap * 1.6 ||
                    (indented && abs(line.x - prev.x) > indentMin / 2) ||
                    (prev.endX < right - body * 3 && endsSentence(prev.text.trimmingTrailingWhitespace))
            }
            if startsNew {
                flush()
                currentIndented = indented
            }
            current.append(line)
        }
        flush()
        return blocks
    }

    /// PDF text extraction can hand back one visual line as several pieces (a font change, a
    /// footnote marker). Consecutive pieces on the same baseline, left to right, become one line.
    static func mergeSameRow(_ lines: [Line]) -> [Line] {
        var out: [Line] = []
        for line in lines {
            if var prev = out.last {
                let size = min(prev.fontSize, line.fontSize)
                let gap = line.x - prev.endX
                if abs(line.y - prev.y) < size * 0.35, gap > -size * 0.5, gap < size * 2 {
                    let needsSpace = gap > size * 0.15 && !prev.text.hasSuffix(" ") && !line.text.hasPrefix(" ")
                    prev.spans = (prev.spans + (needsSpace ? [Span(" ")] : []) + line.spans).compact()
                    prev.endX = max(prev.endX, line.endX)
                    prev.fontSize = max(prev.fontSize, line.fontSize)
                    out[out.count - 1] = prev
                    continue
                }
            }
            out.append(line)
        }
        return out
    }

    /// Splits a page into columns at a vertical gutter that no body line crosses, in reading
    /// order: full-width lines above the columns (a chapter title), each column, then full-width
    /// lines below. A page without a clear gutter is one column.
    static func columns(_ lines: [Line], body: Float, depth: Int = 0) -> [[Line]] {
        guard depth < 2, lines.count >= 6 else { return [lines] }
        let minX = lines.map(\.x).min()!
        let maxX = lines.map(\.endX).max()!
        let width = maxX - minX
        guard width > body * 20 else { return [lines] }
        // Prefer a gutter no line crosses; allow a stray line or two (a long heading) otherwise.
        var gutter: (start: Float, end: Float)?
        for tolerance in [0, max(1, lines.count / 20)] {
            var best: (start: Float, end: Float)?
            var run: (start: Float, end: Float)?
            var g = minX + width * 0.2
            while g <= minX + width * 0.8 {
                if lines.filter({ $0.x < g && $0.endX > g }).count <= tolerance {
                    run = (run?.start ?? g, g)
                } else {
                    if let r = run, r.end - r.start > (best.map { $0.end - $0.start } ?? -1) { best = r }
                    run = nil
                }
                g += 1
            }
            if let r = run, r.end - r.start > (best.map { $0.end - $0.start } ?? -1) { best = r }
            if let best, best.end - best.start >= body * 0.8 {
                gutter = best
                break
            }
        }
        guard let gutter else { return [lines] }
        let mid = (gutter.start + gutter.end) / 2
        let left = lines.filter { $0.endX <= mid }
        let right = lines.filter { $0.x >= mid }
        // Both sides must read like text, not a list of page numbers or labels.
        func isColumn(_ side: [Line]) -> Bool {
            side.count >= max(3, lines.count / 5) &&
                side.map { Float($0.text.count) }.reduce(0, +) / Float(side.count) >= 15
        }
        guard isColumn(left), isColumn(right) else { return [lines] }
        let columnTop = (left + right).map(\.y).min()!
        let spanning = lines.filter { $0.x < mid && $0.endX > mid }
        let above = spanning.filter { $0.y < columnTop }
        let below = spanning.filter { $0.y >= columnTop }
        let body = columns(left, body: body, depth: depth + 1) + columns(right, body: body, depth: depth + 1)
        return ([above] + body + [below]).filter { !$0.isEmpty }
    }

    private static let noteMarker = try! NSRegularExpression(pattern: #"^\s*([*†‡§¶]+|\d{1,3}[.)]?\s|[¹²³⁴⁵⁶⁷⁸⁹⁰]+)"#)

    private static func startsWithNoteMarker(_ text: String) -> Bool {
        noteMarker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Footnotes: a run of smaller type at the foot of a column, set off by extra space or
    /// starting with a note marker (*, †, a number).
    static func splitFootnotes(_ lines: [Line], body: Float) -> (main: [Line], notes: [Line]) {
        var start = lines.count
        while start > 0, lines[start - 1].fontSize < body * 0.88 { start -= 1 }
        guard start < lines.count, start > 0 else { return (lines, []) }
        let gaps = zip(lines, lines.dropFirst()).map { $1.y - $0.y }.filter { $0 > 0 }
        let lineGap = gaps.isEmpty ? body * 1.2 : median(gaps)
        let first = lines[start]
        let setOff = first.y - lines[start - 1].y > lineGap * 1.3
        guard setOff || startsWithNoteMarker(first.text) else { return (lines, []) }
        return (Array(lines[..<start]), Array(lines[start...]))
    }

    /// One `.note` block per footnote: a new one starts at each note marker.
    static func footnoteBlocks(_ lines: [Line]) -> [Block] {
        var groups: [[Line]] = []
        for line in lines {
            if groups.isEmpty || startsWithNoteMarker(line.text) { groups.append([line]) } else { groups[groups.count - 1].append(line) }
        }
        return groups.map { Block(.note, spans: join($0)) }
    }

    /// Joins lines into one run of spans, undoing end-of-line hyphenation.
    public static func join(_ lines: [Line]) -> [Span] {
        var out: [Span] = []
        for line in lines {
            if let last = out.last {
                let lastText = last.text.trimmingTrailingWhitespace
                let next = line.spans.first?.text.trimmingLeadingWhitespace ?? ""
                let chars = Array(lastText)
                if chars.count >= 2, chars[chars.count - 1] == "-", chars[chars.count - 2].isLetter,
                   next.first?.isLowercase == true {
                    out[out.count - 1].text = String(chars.dropLast())
                } else {
                    out[out.count - 1].text = lastText + " "
                }
            }
            for (i, s) in line.spans.enumerated() {
                var s = s
                if i == 0 { s.text = s.text.trimmingLeadingWhitespace }
                out.append(s)
            }
        }
        if !out.isEmpty { out[out.count - 1].text = out[out.count - 1].text.trimmingTrailingWhitespace }
        return out.compact()
    }

    /// Can `next` (first block of a page) continue `prev` (last block of the page before)?
    public static func continues(_ prev: Block?, _ next: Block?, nextPageUsesIndents: Bool) -> Bool {
        guard let prev, let next else { return false }
        if prev.kind != .paragraph || next.kind != .paragraph { return false }
        if nextPageUsesIndents { return !next.indented }
        let ends = endsSentence(prev.text.trimmingTrailingWhitespace)
        let startsUpper = next.text.trimmingLeadingWhitespace.first?.isUppercase == true
        return !(ends && startsUpper)
    }

    /// `prev` with `next`'s text appended, as one paragraph.
    public static func merge(_ prev: Block, _ next: Block) -> Block {
        let a = Line(spans: prev.spans, x: 0, endX: 0, y: 0, fontSize: 1)
        let b = Line(spans: next.spans, x: 0, endX: 0, y: 0, fontSize: 1)
        var out = prev
        out.spans = join([a, b])
        return out
    }

    static func endsSentence(_ s: String) -> Bool {
        s.last.map { sentenceEndChars.contains($0) } ?? false
    }

    private static func isPageNumber(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return pageNumber.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    private static func dropPageNumbers(_ lines: [Line]) -> [Line] {
        var start = 0, end = lines.count
        while start < end, isPageNumber(lines[start].text) { start += 1 }
        while end > start, isPageNumber(lines[end - 1].text) { end -= 1 }
        return Array(lines[start..<end])
    }

    private static func isLarger(_ size: Float, _ body: Float) -> Bool { size > body * 1.15 }

    /// Spaces, tabs and no-break spaces collapse to one space (as on Android).
    private static func normalizeSpaces(_ spans: [Span]) -> [Span] {
        spans.map { var s = $0; s.text = s.text.collapsing(" \t\u{00A0}", into: " "); return s }
    }

    private static func median(_ values: [Float]) -> Float { percentile(values, 0.5) }

    private static func percentile(_ values: [Float], _ p: Double) -> Float {
        if values.isEmpty { return 0 }
        let sorted = values.sorted()
        return sorted[Int(Double(sorted.count - 1) * p)]
    }
}

extension String {
    var isBlank: Bool { allSatisfy(\.isWhitespace) }

    var trimmingLeadingWhitespace: String {
        String(drop(while: \.isWhitespace))
    }

    var trimmingTrailingWhitespace: String {
        var s = Substring(self)
        while let last = s.last, last.isWhitespace { s = s.dropLast() }
        return String(s)
    }

    /// Replaces each run of characters from `set` with `replacement`.
    func collapsing(_ set: String, into replacement: String) -> String {
        let chars = Set(set.unicodeScalars)
        var out = String.UnicodeScalarView()
        var inRun = false
        for u in unicodeScalars {
            if chars.contains(u) {
                if !inRun { out.append(contentsOf: replacement.unicodeScalars) }
                inRun = true
            } else {
                out.append(u)
                inRun = false
            }
        }
        return String(out)
    }
}
