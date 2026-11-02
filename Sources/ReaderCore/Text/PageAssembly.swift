import Foundation

/// Cross-page cleanup, which needs to see neighbouring pages:
///  - running headers and footers (book title, chapter name, "Page 72") repeat on nearby pages
///    and are dropped;
///  - a paragraph split by a page break is rejoined onto the earlier page.
public enum PageAssembly {
    /// How many pages either side are compared when looking for running headers/footers.
    public static let window = 2

    /// Removes a first/last line that repeats (ignoring digits) at the same edge of a nearby page.
    public static func stripRunningLines(_ page: [Line], neighbours: [[Line]]) -> [Line] {
        let lines = page.filter { !$0.text.isBlank }
        if lines.count < 2 { return lines }
        let tops = Set(neighbours.flatMap { n in topRow(n.filter { !$0.text.isBlank }).map(key) })
        let bottoms = Set(neighbours.flatMap { n in bottomRow(n.filter { !$0.text.isBlank }).map(key) })
        var out = lines
        // A header can be several pieces on one row ("ALL AND EVERYTHING ... 452" read by OCR as
        // two lines). It's running when one piece repeats; then its whole row goes.
        if isRunning(out[0], tops) || topRow(out).contains(where: { isRunning($0, tops) && !isNumber($0) }) {
            out.removeFirst(min(out.count - 1, topRow(out).count))
        }
        if out.count > 1, isRunning(out[out.count - 1], bottoms) || bottomRow(out).contains(where: { isRunning($0, bottoms) && !isNumber($0) }) {
            out.removeLast(min(out.count - 1, bottomRow(out).count))
        }
        return out
    }

    /// The first lines that share the first line's row.
    private static func topRow(_ lines: [Line]) -> ArraySlice<Line> {
        guard let first = lines.first else { return [] }
        return lines.prefix { abs($0.y - first.y) < max($0.fontSize, first.fontSize) * 0.5 }
    }

    private static func bottomRow(_ lines: [Line]) -> ArraySlice<Line> {
        guard let last = lines.last else { return [] }
        return lines.reversed().prefix { abs($0.y - last.y) < max($0.fontSize, last.fontSize) * 0.5 }.reversed()[...]
    }

    private static func isNumber(_ line: Line) -> Bool { key(line) == "#" }

    /// Final blocks for a page given the reflowed blocks of the page before, this one and the one
    /// after. A paragraph that continues across a break is moved whole onto the earlier page,
    /// so both pages agree on who owns it no matter which is assembled first. Pages that would be
    /// left empty (a page that is one long paragraph) keep their text and are marked as
    /// continuations instead.
    public static func assemble(prev: [Block]?, page: [Block], next: [Block]?) -> [Block] {
        if page.isEmpty { return page }
        var out = page
        // Footnotes sit at the end of a page; paragraphs continue around them.
        let mainCount = page.filter { $0.kind != .note }.count
        let continuesPrev = prev != nil && Reflow.continues(prev!.last { $0.kind != .note && $0.kind != .image }, page.first,
                                                            nextPageUsesIndents: usesIndents(page))
        if continuesPrev && mainCount >= 2 {
            out.removeFirst()
        } else if continuesPrev {
            out[0].continuation = true
        }
        if let next, next.filter({ $0.kind != .note }).count >= 2,
           let last = out.lastIndex(where: { $0.kind != .note && $0.kind != .image }),
           Reflow.continues(out[last], next.first, nextPageUsesIndents: usesIndents(next)) {
            out[last] = Reflow.merge(out[last], next[0])
        }
        return out
    }

    private static func usesIndents(_ blocks: [Block]) -> Bool { blocks.contains(where: \.indented) }

    private static let digits = try! NSRegularExpression(pattern: #"\d+"#)

    private static func key(_ line: Line) -> String {
        let lower = line.text.lowercased()
        let hashed = digits.stringByReplacingMatches(in: lower, range: NSRange(lower.startIndex..., in: lower), withTemplate: "#")
        // Java's \s: no-break spaces are not collapsed.
        return hashed.collapsing(" \t\n\u{0B}\u{0C}\r", into: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isRunning(_ line: Line, _ edges: Set<String>) -> Bool {
        guard line.text.utf16.count <= 100 else { return false }
        let k = key(line)
        return !k.isEmpty && edges.contains(k)
    }
}
