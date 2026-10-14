import Foundation

/// A tiny read-only DOM for EPUB files, built with Foundation's `XMLDocument`. Well-formed XHTML
/// (the norm in EPUBs) parses as XML; anything else falls back to libxml2's HTML tidy mode.
/// External entities and DTDs are never loaded.
enum Markup {
    indirect enum Node {
        case element(Element)
        case text(String)
    }

    final class Element {
        /// Lowercased local name ("dc:title" → "title").
        let name: String
        /// By lowercased qualified name ("xlink:href") and local name ("href" for a namespaced
        /// attribute only if no plain one exists).
        let attributes: [String: String]
        let children: [Node]

        init(name: String, attributes: [String: String], children: [Node]) {
            self.name = name
            self.attributes = attributes
            self.children = children
        }

        func attr(_ name: String) -> String { attributes[name] ?? "" }

        var elements: [Element] {
            children.compactMap { if case .element(let e) = $0 { return e }; return nil }
        }

        /// Direct element children called `name`.
        func children(_ name: String) -> [Element] { elements.filter { $0.name == name } }

        /// This element or the first descendant called `name`, depth first.
        func first(_ name: String) -> Element? {
            if self.name == name { return self }
            for e in elements { if let hit = e.first(name) { return hit } }
            return nil
        }

        var text: String {
            children.map { node in
                switch node {
                case .text(let t): return t
                case .element(let e): return e.text
                }
            }.joined()
        }
    }

    static func parse(_ data: Data, html: Bool) -> Element? {
        let safe: XMLNode.Options = [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever]
        if let doc = try? XMLDocument(data: data, options: safe), let root = doc.rootElement() {
            return convert(root)
        }
        // Not well-formed (HTML entities like &nbsp;, unclosed <p> or <br>): parse leniently.
        // libxml2's tidy mode isn't used because it mis-decodes UTF-8 and drops entities.
        return LenientHTML.parse(String(decoding: data, as: UTF8.self))
    }

    private static func convert(_ el: XMLElement) -> Element {
        var attrs: [String: String] = [:]
        for a in el.attributes ?? [] {
            let value = a.stringValue ?? ""
            if let name = a.name?.lowercased() { attrs[name] = value }
        }
        for a in el.attributes ?? [] {
            if let local = a.localName?.lowercased(), attrs[local] == nil { attrs[local] = a.stringValue ?? "" }
        }
        let children: [Node] = (el.children ?? []).compactMap { node in
            switch node.kind {
            case .element: return (node as? XMLElement).map { .element(convert($0)) }
            case .text: return .text(node.stringValue ?? "")
            default: return nil
            }
        }
        let name = (el.localName ?? el.name ?? "").lowercased()
        return Element(name: name, attributes: attrs, children: children)
    }
}
