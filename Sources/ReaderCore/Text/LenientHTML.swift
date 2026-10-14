import Foundation

/// A forgiving HTML parser for EPUB chapters that aren't well-formed XML. It follows the HTML
/// rules that matter for reading text: void elements, `<p>` closed by the next block, `<li>`
/// closed by the next item, stray end tags ignored, named and numeric character references.
enum LenientHTML {
    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "image", "input", "link", "meta", "param",
        "source", "track", "wbr",
    ]
    private static let rawTextTags: Set<String> = ["script", "style", "title", "textarea"]
    /// Opening one of these closes an open `<p>`.
    private static let closesParagraph: Set<String> = XhtmlBlocks.blockTags.subtracting(["body", "li", "td", "th", "tr", "dd", "dt"])

    private final class Builder {
        let name: String
        let attributes: [String: String]
        var children: [Markup.Node] = []
        init(_ name: String, _ attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }
        func build() -> Markup.Element { Markup.Element(name: name, attributes: attributes, children: children) }
    }

    static func parse(_ html: String) -> Markup.Element {
        let s = Array(html.unicodeScalars)
        var i = 0
        var stack = [Builder("#root", [:])]
        var text = String.UnicodeScalarView()

        func flushText() {
            if !text.isEmpty {
                stack[stack.count - 1].children.append(.text(decode(String(text))))
                text = String.UnicodeScalarView()
            }
        }
        func close(_ name: String) {
            guard let at = stack.lastIndex(where: { $0.name == name }), at > 0 else { return }
            while stack.count > at {
                let b = stack.removeLast()
                stack[stack.count - 1].children.append(.element(b.build()))
            }
        }
        func starts(_ prefix: String, at j: Int) -> Bool {
            let p = Array(prefix.unicodeScalars)
            guard j + p.count <= s.count else { return false }
            for k in 0..<p.count where Character(s[j + k]).lowercased() != Character(p[k]).lowercased() { return false }
            return true
        }
        func skip(past end: String, from j: Int) -> Int {
            var k = j
            while k < s.count, !starts(end, at: k) { k += 1 }
            return min(s.count, k + end.unicodeScalars.count)
        }

        while i < s.count {
            guard s[i] == "<", i + 1 < s.count else {
                text.append(s[i])
                i += 1
                continue
            }
            if starts("<!--", at: i) { flushText(); i = skip(past: "-->", from: i + 4); continue }
            if starts("<![CDATA[", at: i) {
                let start = i + 9
                let end = skip(past: "]]>", from: start)
                text.append(contentsOf: s[start..<max(start, end - 3)])
                i = end
                continue
            }
            if s[i + 1] == "!" || s[i + 1] == "?" { flushText(); i = skip(past: ">", from: i); continue }
            let closing = s[i + 1] == "/"
            var j = i + (closing ? 2 : 1)
            var name = ""
            while j < s.count, !CharacterSet.whitespacesAndNewlines.contains(s[j]), s[j] != ">", s[j] != "/" {
                name.unicodeScalars.append(s[j])
                j += 1
            }
            guard let first = name.unicodeScalars.first, CharacterSet.letters.contains(first) else {
                text.append(s[i]) // a literal "<"
                i += 1
                continue
            }
            name = localName(name)
            var attrs: [String: String] = [:]
            var selfClosing = false
            // Attributes: name, name=value, name="value", name='value'.
            while j < s.count, s[j] != ">" {
                if s[j] == "/" { selfClosing = true; j += 1; continue }
                if CharacterSet.whitespacesAndNewlines.contains(s[j]) { j += 1; continue }
                var key = ""
                while j < s.count, !CharacterSet.whitespacesAndNewlines.contains(s[j]), !"=>/".unicodeScalars.contains(s[j]) {
                    key.unicodeScalars.append(s[j])
                    j += 1
                }
                while j < s.count, CharacterSet.whitespacesAndNewlines.contains(s[j]) { j += 1 }
                var value = ""
                if j < s.count, s[j] == "=" {
                    j += 1
                    while j < s.count, CharacterSet.whitespacesAndNewlines.contains(s[j]) { j += 1 }
                    if j < s.count, s[j] == "\"" || s[j] == "'" {
                        let q = s[j]
                        j += 1
                        while j < s.count, s[j] != q { value.unicodeScalars.append(s[j]); j += 1 }
                        j += 1
                    } else {
                        while j < s.count, !CharacterSet.whitespacesAndNewlines.contains(s[j]), s[j] != ">" {
                            value.unicodeScalars.append(s[j])
                            j += 1
                        }
                    }
                }
                if !key.isEmpty {
                    selfClosing = false
                    let k = key.lowercased()
                    attrs[k] = decode(value)
                    let local = localName(k)
                    if attrs[local] == nil { attrs[local] = decode(value) }
                }
            }
            i = min(s.count, j + 1)
            flushText()

            if closing {
                close(name)
                continue
            }
            if closesParagraph.contains(name), stack.last?.name == "p" { close("p") }
            if name == "p", stack.last?.name == "p" { close("p") }
            if name == "li", let li = stack.lastIndex(where: { $0.name == "li" }),
               !stack[li...].contains(where: { $0.name == "ul" || $0.name == "ol" }) {
                close("li")
            }
            let element = Builder(name, attrs)
            if voidTags.contains(name) || selfClosing {
                stack[stack.count - 1].children.append(.element(element.build()))
            } else if rawTextTags.contains(name) {
                // Skip to the matching end tag; contents aren't markup.
                let start = i
                var k = i
                while k < s.count, !starts("</\(name)", at: k) { k += 1 }
                let raw = String(String.UnicodeScalarView(s[start..<k]))
                element.children = [.text(name == "title" || name == "textarea" ? decode(raw) : raw)]
                stack[stack.count - 1].children.append(.element(element.build()))
                i = skip(past: ">", from: k)
            } else {
                stack.append(element)
            }
        }
        flushText()
        while stack.count > 1 {
            let b = stack.removeLast()
            stack[stack.count - 1].children.append(.element(b.build()))
        }
        let root = stack[0].build()
        return root.first("html") ?? Markup.Element(name: "html", attributes: [:], children: root.children)
    }

    private static func localName(_ qualified: String) -> String {
        let lower = qualified.lowercased()
        return lower.split(separator: ":").last.map(String.init) ?? lower
    }

    /// Replaces `&name;`, `&#123;` and `&#x7B;` with their characters; unknown ones are kept.
    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = String.UnicodeScalarView()
        let u = Array(s.unicodeScalars)
        var i = 0
        while i < u.count {
            guard u[i] == "&", let semi = u[(i + 1)..<min(u.count, i + 34)].firstIndex(of: ";") else {
                out.append(u[i])
                i += 1
                continue
            }
            let ref = String(String.UnicodeScalarView(u[(i + 1)..<semi]))
            var scalar: UnicodeScalar?
            if ref.hasPrefix("#x") || ref.hasPrefix("#X") {
                scalar = UInt32(ref.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init)
            } else if ref.hasPrefix("#") {
                scalar = UInt32(ref.dropFirst()).flatMap(UnicodeScalar.init)
            } else {
                scalar = htmlEntities[ref]
            }
            if let scalar {
                out.append(scalar)
                i = semi + 1
            } else {
                out.append(u[i])
                i += 1
            }
        }
        return String(out)
    }
}
