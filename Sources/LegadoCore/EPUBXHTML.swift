import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct EPUBXHTML {
    fileprivate static let paragraph = "\u{000b}"
    fileprivate static let lineBreak = "\u{000c}"

    let text: String
    let heading: String?
    let anchors: [String: Int]

    static func read(_ data: Data) -> EPUBXHTML {
        let collector = EPUBTextCollector()
        if ReadingXML.parse(data, delegate: collector), collector.hasBody { return collector.document }

        // Some EPUB 2 books contain HTML void tags and undeclared entities inside their XHTML.
        let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? ""
        guard raw.range(of: #"(?i)<(?:html|body|div|p|h[1-6])\b"#, options: .regularExpression) != nil else {
            return EPUBXHTML(text: "", heading: nil, anchors: [:])
        }
        let body = raw.replacingOccurrences(of: #"(?is)<head\b[^>]*>.*?</head\s*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<(script|style|template|noscript|rt|rp)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<!doctype[^>]*(?:\[[\s\S]*?\]\s*)?>|<\?.*?\?>"#, with: "", options: .regularExpression)
        let heading = body.range(of: #"(?is)<h[1-6]\b[^>]*>.*?</h[1-6]\s*>"#, options: .regularExpression)
            .map { clean(plainText(String(body[$0]))) }
        return EPUBXHTML(text: plainText(body), heading: heading, anchors: [:])
    }

    private static func plainText(_ body: String) -> String {
        let blocks = #"(?i)</?(?:address|article|aside|blockquote|dd|div|dl|dt|figcaption|figure|footer|h[1-6]|header|li|main|ol|p|pre|section|table|tr|ul)\b[^>]*>"#
        let text = body.replacingOccurrences(of: blocks, with: paragraph, options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<br\b[^>]*>"#, with: lineBreak, options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return ReadingXML.replaceEntities(text, xmlOnly: false)
    }

    static func clean(_ text: String) -> String {
        text.components(separatedBy: paragraph).compactMap { paragraph in
            let lines = paragraph.components(separatedBy: lineBreak).compactMap { line in
                let text = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return text.isEmpty ? nil : text
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

private final class EPUBTextCollector: NSObject, XMLParserDelegate {
    private static let blocks: Set<String> = [
        "address", "article", "aside", "blockquote", "dd", "div", "dl", "dt", "figcaption", "figure", "footer",
        "header", "li", "main", "ol", "p", "pre", "section", "table", "tr", "ul"
    ]
    private static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    private static let ignored: Set<String> = ["script", "style", "template", "noscript", "rt", "rp"]

    private var depth = 0
    private var bodyDepth: Int?
    private var ignoredDepth: Int?
    private var headingDepth: Int?
    private var heading = ""
    private var text = ""
    private var offset = 0
    private var anchors: [String: Int] = [:]
    fileprivate private(set) var hasBody = false

    var document: EPUBXHTML {
        let cleanedHeading = EPUBXHTML.clean(heading)
        return EPUBXHTML(text: text, heading: cleanedHeading.isEmpty ? nil : cleanedHeading, anchors: anchors)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        depth += 1
        guard depth <= 256 else {
            parser.abortParsing()
            return
        }
        let name = ReadingXML.localName(elementName)
        if name == "body", bodyDepth == nil {
            bodyDepth = depth
            hasBody = true
        }
        guard bodyDepth != nil, ignoredDepth == nil else { return }
        if Self.ignored.contains(name) || attributeDict["hidden"] != nil || attributeDict["aria-hidden"] == "true" {
            ignoredDepth = depth
            return
        }
        if Self.blocks.contains(name) || Self.headings.contains(name) { separate(with: EPUBXHTML.paragraph) }
        if let id = attributeDict["id"] ?? attributeDict["xml:id"] ?? (name == "a" ? attributeDict["name"] : nil),
           anchors[id] == nil {
            anchors[id] = offset
        }
        switch name {
        case "br":
            separate(with: EPUBXHTML.lineBreak)
        case "hr":
            separate(with: EPUBXHTML.paragraph)
        case "td", "th":
            if !text.isEmpty { append(" ") }
        case "img":
            if let alt = attributeDict["alt"], !alt.isEmpty { append(alt) }
        default:
            if Self.headings.contains(name), heading.isEmpty, headingDepth == nil { headingDepth = depth }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer { depth -= 1 }
        if ignoredDepth == depth {
            ignoredDepth = nil
            return
        }
        guard bodyDepth != nil, ignoredDepth == nil else { return }
        if bodyDepth == depth { bodyDepth = nil }
        if headingDepth == depth { headingDepth = nil }
        let name = ReadingXML.localName(elementName)
        if Self.blocks.contains(name) || Self.headings.contains(name) { separate(with: EPUBXHTML.paragraph) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if bodyDepth != nil, ignoredDepth == nil { append(string) }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
    }

    private func append(_ value: String) {
        text.append(value)
        offset += value.utf16.count
        if headingDepth != nil { heading.append(value) }
    }

    private func separate(with value: String) {
        if !text.isEmpty && !text.hasSuffix(value) { append(value) }
    }
}

enum ReadingXML {
    private static let entityRegex = try? NSRegularExpression(
        pattern: #"<!\[CDATA\[[\s\S]*?\]\]>|<!--[\s\S]*?-->|&(#(?:[xX][0-9a-fA-F]{1,8}|[0-9]{1,10})|[A-Za-z][A-Za-z0-9]{1,30});"#
    )
    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{a0}",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200c}", "zwj": "\u{200d}",
        "lrm": "\u{200e}", "rlm": "\u{200f}", "shy": "\u{ad}", "ndash": "–", "mdash": "—", "hellip": "…",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„", "laquo": "«", "raquo": "»",
        "lsaquo": "‹", "rsaquo": "›", "prime": "′", "Prime": "″", "bull": "•", "middot": "·", "dagger": "†", "Dagger": "‡",
        "copy": "©", "reg": "®", "trade": "™", "sect": "§", "para": "¶", "deg": "°", "plusmn": "±", "times": "×", "divide": "÷",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "aacute": "á", "eacute": "é", "iacute": "í", "oacute": "ó", "uacute": "ú", "Aacute": "Á", "Eacute": "É", "Iacute": "Í",
        "Oacute": "Ó", "Uacute": "Ú", "agrave": "à", "egrave": "è", "igrave": "ì", "ograve": "ò", "ugrave": "ù",
        "acirc": "â", "ecirc": "ê", "icirc": "î", "ocirc": "ô", "ucirc": "û", "auml": "ä", "euml": "ë", "iuml": "ï", "ouml": "ö",
        "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß", "ccedil": "ç", "ntilde": "ñ", "Ntilde": "Ñ"
    ]
    private static let xmlEntities: Set<String> = ["amp", "lt", "gt", "quot", "apos"]
    private static let forbiddenDeclarations = [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian]
        .compactMap { "<!ENTITY".data(using: $0) }

    static func parse(_ data: Data, delegate: any XMLParserDelegate) -> Bool {
        guard !forbiddenDeclarations.contains(where: { data.range(of: $0) != nil }) else { return false }
        let input: Data
        if data.contains(38), let string = String(data: data, encoding: .utf8) {
            input = Data(replaceEntities(string, xmlOnly: true).utf8)
        } else {
            input = data
        }
        let parser = XMLParser(data: input)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        return parser.parse() && parser.parserError == nil
    }

    static func localName(_ name: String) -> String {
        name.split(separator: ":").last?.lowercased() ?? ""
    }

    static func replaceEntities(_ text: String, xmlOnly: Bool) -> String {
        guard let entityRegex, text.contains("&") else { return text }
        let source = text as NSString
        var output = ""
        var position = 0
        entityRegex.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match, match.range(at: 1).location != NSNotFound else { return }
            let key = source.substring(with: match.range(at: 1))
            let replacement: String
            if key.hasPrefix("#"), !xmlOnly {
                let digits = key.dropFirst()
                let isHex = digits.first == "x" || digits.first == "X"
                guard let value = UInt32(isHex ? digits.dropFirst() : digits, radix: isHex ? 16 : 10),
                      let scalar = Unicode.Scalar(value), value >= 32 || [9, 10, 13].contains(value) else { return }
                replacement = String(scalar)
            } else {
                guard !xmlOnly || !xmlEntities.contains(key), let character = entities[key] else { return }
                replacement = character
            }
            output += source.substring(with: NSRange(location: position, length: match.range.location - position))
            output += replacement
            position = NSMaxRange(match.range)
        }
        guard position > 0 else { return text }
        output += source.substring(from: position)
        return output
    }
}
