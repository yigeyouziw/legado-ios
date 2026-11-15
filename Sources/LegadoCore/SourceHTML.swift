import Foundation

final class SourceHTMLNode {
    let tag: String?
    let value: String
    let attributes: [String: String]
    weak var parent: SourceHTMLNode?
    private(set) var children: [SourceHTMLNode] = []

    init(tag: String? = nil, value: String = "", attributes: [String: String] = [:]) {
        self.tag = tag
        self.value = value
        self.attributes = attributes
    }

    func append(_ node: SourceHTMLNode) {
        children.append(node)
        node.parent = self
    }

    var elements: [SourceHTMLNode] { children.filter { $0.tag != nil } }
    var descendants: [SourceHTMLNode] {
        var result: [SourceHTMLNode] = []
        var pending = Array(elements.reversed())
        while let node = pending.popLast() {
            result.append(node)
            pending.append(contentsOf: node.elements.reversed())
        }
        return result
    }

    var document: SourceHTMLNode {
        var current = self
        while let parent = current.parent { current = parent }
        return current
    }

    var previousSiblings: [SourceHTMLNode] {
        guard let parent, let index = parent.elements.firstIndex(where: { $0 === self }) else { return [] }
        return Array(parent.elements.prefix(index))
    }

    var text: String {
        normalizedSpace(renderedText)
    }

    var renderedText: String {
        guard let tag else { return value }
        guard !["script", "style", "template", "noscript"].contains(tag) else { return "" }
        if tag == "br" || tag == "hr" { return "\n" }
        let content = children.map(\.renderedText).joined()
        if SourceHTML.blockTags.contains(tag) { return "\n" + content + "\n" }
        return content
    }

    var ownText: String {
        normalizedSpace(children.filter { $0.tag == nil }.map(\.value).joined(separator: " "))
    }

    var innerHTML: String {
        children.map(\.outerHTML).joined()
    }

    var outerHTML: String {
        guard let tag else { return escapeSourceHTML(value) }
        if tag == "#document" { return innerHTML }
        guard !["script", "style", "template", "noscript"].contains(tag) else { return "" }
        let attributes = attributes.sorted { $0.key < $1.key }.map {
            " \($0.key)=\"\(escapeSourceHTML($0.value))\""
        }.joined()
        let opening = "<" + tag + attributes + ">"
        if SourceHTML.voidTags.contains(tag) { return opening }
        return opening + innerHTML + "</" + tag + ">"
    }
}

enum SourceHTML {
    static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param",
        "source", "track", "wbr"
    ]
    static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "dd", "div", "dl", "dt", "figcaption",
        "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "li",
        "main", "nav", "ol", "p", "pre", "section", "table", "tbody", "td", "tr", "ul"
    ]
    private static let tokens = try! NSRegularExpression(
        pattern: #"(?is)<!--.*?(?:-->|$)|<(script|style|textarea|title)(\s[^>]*|)>(.*?)</\1\s*>|</?[a-z][a-z0-9:_-]*(?:"[^"]*"|'[^']*'|[^"'<>])*>|<![^>]*>|<\?[^>]*\?>"#
    )
    private static let tagPattern = try! NSRegularExpression(pattern: #"(?i)^</?([a-z][a-z0-9:_-]*)"#)
    private static let attributePattern = try! NSRegularExpression(
        pattern: #"([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?"#
    )

    static func parse(_ html: String) -> SourceHTMLNode {
        let root = SourceHTMLNode(tag: "#document", value: html)
        let input = html as NSString
        var stack = [root]
        var cursor = 0
        tokens.enumerateMatches(in: html, range: NSRange(location: 0, length: input.length)) { match, _, _ in
            guard let match, let parent = stack.last else { return }
            if cursor < match.range.location {
                let text = input.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                parent.append(SourceHTMLNode(value: decodeSourceEntities(text)))
            }
            cursor = NSMaxRange(match.range)
            let token = input.substring(with: match.range)
            guard let tagMatch = tagPattern.firstMatch(in: token, range: NSRange(location: 0, length: (token as NSString).length)) else { return }
            let tokenText = token as NSString
            let tag = tokenText.substring(with: tagMatch.range(at: 1)).lowercased()
            if token.hasPrefix("</") {
                if let index = stack.lastIndex(where: { $0.tag == tag }), index > 0 {
                    stack.removeSubrange(index...)
                }
                return
            }
            implicitlyClose(tag, in: &stack)
            let attributeStart = NSMaxRange(tagMatch.range)
            let rawEnd = match.range(at: 3).location == NSNotFound
                ? tokenText.length - 1
                : match.range(at: 3).location - match.range.location - 1
            let attributes = parseAttributes(token, in: NSRange(location: attributeStart, length: max(0, rawEnd - attributeStart)))
            let node = SourceHTMLNode(tag: tag, attributes: attributes)
            stack[stack.count - 1].append(node)
            if match.range(at: 3).location != NSNotFound {
                let body = input.substring(with: match.range(at: 3))
                node.append(SourceHTMLNode(value: ["script", "style"].contains(tag) ? body : decodeSourceEntities(body)))
            } else if !voidTags.contains(tag), !token.hasSuffix("/>"), stack.count < 256 {
                stack.append(node)
            }
        }
        if cursor < input.length {
            let tail = input.substring(from: cursor)
            stack[stack.count - 1].append(SourceHTMLNode(value: decodeSourceEntities(tail)))
        }
        return root
    }

    static func plainText(_ input: String) -> String {
        let text = input.range(of: #"<[a-zA-Z!/][^>]*>"#, options: .regularExpression) == nil
            ? decodeSourceEntities(input)
            : parse(input).renderedText
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .sourceTrimmed
    }

    private static func parseAttributes(_ text: String, in range: NSRange) -> [String: String] {
        let input = text as NSString
        var attributes: [String: String] = [:]
        attributePattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else { return }
            let key = input.substring(with: match.range(at: 1)).lowercased()
            guard attributes[key] == nil else { return }
            let valueRange = (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }
            attributes[key] = valueRange.map { decodeSourceEntities(input.substring(with: $0)) } ?? ""
        }
        return attributes
    }

    private static func implicitlyClose(_ tag: String, in stack: inout [SourceHTMLNode]) {
        guard let top = stack.last?.tag else { return }
        let pairs: [String: Set<String>] = [
            "li": ["li"], "dt": ["dt", "dd"], "dd": ["dt", "dd"], "option": ["option"],
            "td": ["td", "th"], "th": ["td", "th"], "tr": ["tr", "td", "th"]
        ]
        if top == "p", tag == "p" || blockTags.contains(tag) {
            stack.removeLast()
        } else if let allowed = pairs[tag] {
            while let open = stack.last?.tag, allowed.contains(open) { stack.removeLast() }
        }
    }
}

private let entityPattern = try! NSRegularExpression(pattern: #"&(?:#(?:x[0-9a-fA-F]+|\d+)|[a-zA-Z][a-zA-Z0-9]+);"#)
private let namedHTMLEntities: [String: String] = [
    "amp": "&", "apos": "'", "quot": "\"", "lt": "<", "gt": ">", "nbsp": " ",
    "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "hellip": "…",
    "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“",
    "rdquo": "”", "laquo": "«", "raquo": "»", "middot": "·", "bull": "•",
    "copy": "©", "reg": "®", "trade": "™", "times": "×", "divide": "÷",
    "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "zwj": "\u{200D}",
    "zwnj": "\u{200C}", "shy": "\u{00AD}", "ideographicspace": "\u{3000}"
]

func decodeSourceEntities(_ value: String) -> String {
    guard value.contains("&") else { return value }
    let original = value as NSString
    let decoded = NSMutableString(string: value)
    let matches = entityPattern.matches(in: value, range: NSRange(location: 0, length: original.length))
    for match in matches.reversed() {
        let token = String(original.substring(with: match.range).dropFirst().dropLast())
        let character: String?
        if token.lowercased().hasPrefix("#x") {
            character = UInt32(token.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(String.init)
        } else if token.hasPrefix("#") {
            character = UInt32(token.dropFirst()).flatMap(Unicode.Scalar.init).map(String.init)
        } else {
            character = namedHTMLEntities[token.lowercased()]
        }
        if let character { decoded.replaceCharacters(in: match.range, with: character) }
    }
    return decoded as String
}

func escapeSourceHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

func normalizedSpace(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}
