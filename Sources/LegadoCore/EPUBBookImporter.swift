import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum EPUBBookImporter {
    private struct Item {
        let location: EPUBLocation
        let mediaType: String
        let properties: [Substring]
        let fallback: String?
    }

    private struct Entry {
        let title: String
        let location: EPUBLocation
    }

    static func read(_ data: Data, fallbackTitle: String) throws -> LocalBook {
        let archive = try EPUBArchive(data: data)
        let container = try readXML(archive, path: "META-INF/container.xml")
        guard let path = container.descendants(named: "rootfile").first?.attributes["full-path"],
              let packagePath = EPUBLocation(path)?.path else { throw LocalBookImportError.invalidEPUB }
        let package = try readXML(archive, path: packagePath)
        guard let manifest = package.child(named: "manifest"), let spine = package.child(named: "spine") else {
            throw LocalBookImportError.invalidEPUB
        }

        var items: [String: Item] = [:]
        var navPath: String?
        for node in manifest.children where node.name == "item" {
            guard let id = node.attributes["id"], let href = node.attributes["href"],
                  let location = EPUBLocation(href, relativeTo: packagePath) else { continue }
            let properties = node.attributes["properties", default: ""].split(whereSeparator: \.isWhitespace)
            items[id] = Item(
                location: location, mediaType: node.attributes["media-type", default: ""].lowercased(),
                properties: properties, fallback: node.attributes["fallback"]
            )
            if navPath == nil, properties.contains("nav") { navPath = location.path }
        }

        let ncxPath = spine.attributes["toc"].flatMap { items[$0]?.location.path }
        var toc = navPath.map { readNavigation(archive, path: $0) } ?? []
        if toc.isEmpty, let ncxPath { toc = readNCX(archive, path: ncxPath) }
        let tocByPath = Dictionary(grouping: toc, by: \.location.path)
        let metadata = package.child(named: "metadata")
        let title = bookTitle(metadata) ?? fallbackTitle
        let author = metadata?.children.filter { $0.name == "creator" }.map { cleanInline($0.text) }
            .filter { !$0.isEmpty }.joined(separator: "、") ?? ""
        let encryptedPaths = encryptedResources(archive)
        var chapters: [LocalChapter] = []
        var totalBytes = 0

        for node in spine.children where node.name == "itemref" {
            guard node.attributes["linear"]?.lowercased() != "no", let id = node.attributes["idref"],
                  let item = readableItem(id, from: items), item.location.path != navPath else { continue }
            let path = item.location.path
            if encryptedPaths.contains(path) { throw LocalBookImportError.encryptedEPUB }
            guard let chapterData = try archive.data(at: path) else { throw LocalBookImportError.invalidEPUB }
            totalBytes += chapterData.count
            guard totalBytes <= 96 * 1024 * 1024 else { throw LocalBookImportError.fileTooLarge }
            let document = EPUBXHTML.read(chapterData)
            let names = tocByPath[path, default: []]
            chapters.append(contentsOf: chapterSections(document, names: names, number: chapters.count + 1))
        }
        guard !chapters.isEmpty else { throw LocalBookImportError.emptyBook }
        let cover = readCover(package, metadata: metadata, items: items, archive: archive, packagePath: packagePath)
        return LocalBook(title: title, author: author, chapters: chapters, cover: cover)
    }

    private static func readXML(_ archive: EPUBArchive, path: String) throws -> EPUBXMLNode {
        guard let data = try archive.data(at: path, maximumSize: 8 * 1024 * 1024),
              let root = EPUBXMLTree.read(data) else { throw LocalBookImportError.invalidEPUB }
        return root
    }

    private static func bookTitle(_ metadata: EPUBXMLNode?) -> String? {
        guard let metadata else { return nil }
        let titles = metadata.children.filter { $0.name == "title" }
        let main = metadata.children.first {
            $0.name == "meta" && $0.attributes["property"] == "title-type" && cleanInline($0.text) == "main"
        }
        let mainID = main?.attributes["refines"].flatMap { $0.hasPrefix("#") ? String($0.dropFirst()) : nil }
        let primary = mainID.flatMap { id in titles.first { $0.attributes["id"] == id } }
        guard let title = (primary ?? titles.first).map({ cleanInline($0.text) }), !title.isEmpty else { return nil }
        return title
    }

    private static func readableItem(_ id: String, from items: [String: Item]) -> Item? {
        var seen: Set<String> = []
        var next: String? = id
        while let id = next, seen.insert(id).inserted, let item = items[id] {
            if ["application/xhtml+xml", "text/html"].contains(item.mediaType) { return item }
            next = item.fallback
        }
        return nil
    }

    private static func readNavigation(_ archive: EPUBArchive, path: String) -> [Entry] {
        guard let root = try? readXML(archive, path: path),
              let nav = root.descendants(named: "nav").first(where: { node in
                  let type = node.attributes["epub:type"] ?? node.attributes["type"] ?? ""
                  return type.split(whereSeparator: \.isWhitespace).contains("toc")
                      || node.attributes["role"] == "doc-toc"
              }) else { return [] }
        return nav.descendants(named: "a").compactMap { node in
            guard let href = node.attributes["href"], let location = EPUBLocation(href, relativeTo: path) else { return nil }
            let title = cleanInline(node.text)
            return title.isEmpty ? nil : Entry(title: title, location: location)
        }
    }

    private static func readNCX(_ archive: EPUBArchive, path: String) -> [Entry] {
        guard let root = try? readXML(archive, path: path), let navMap = root.child(named: "navmap") else { return [] }
        return navMap.descendants(named: "navpoint").compactMap { node in
            guard let href = node.child(named: "content")?.attributes["src"],
                  let location = EPUBLocation(href, relativeTo: path),
                  let label = node.child(named: "navlabel") else { return nil }
            let title = cleanInline(label.text)
            return title.isEmpty ? nil : Entry(title: title, location: location)
        }
    }

    private static func encryptedResources(_ archive: EPUBArchive) -> Set<String> {
        guard let root = try? readXML(archive, path: "META-INF/encryption.xml") else { return [] }
        return Set(root.descendants(named: "cipherreference").compactMap { node in
            node.attributes["URI"].flatMap { EPUBLocation($0)?.path }
        })
    }

    private static func readCover(
        _ package: EPUBXMLNode, metadata: EPUBXMLNode?, items: [String: Item], archive: EPUBArchive, packagePath: String
    ) -> Data? {
        let coverID = metadata?.children.first { $0.name == "meta" && $0.attributes["name"] == "cover" }?.attributes["content"]
        if let item = items.values.first(where: { $0.properties.contains("cover-image") }) ?? coverID.flatMap({ items[$0] }),
           item.mediaType.hasPrefix("image/"),
           let image = try? archive.data(at: item.location.path, maximumSize: 12 * 1024 * 1024) {
            return image
        }
        guard let href = package.child(named: "guide")?.children.first(where: { $0.attributes["type"] == "cover" })?.attributes["href"],
              let coverPath = EPUBLocation(href, relativeTo: packagePath)?.path else { return nil }
        if items.values.contains(where: { $0.location.path == coverPath && $0.mediaType.hasPrefix("image/") }) {
            return try? archive.data(at: coverPath, maximumSize: 12 * 1024 * 1024)
        }
        guard let coverDocument = try? readXML(archive, path: coverPath),
              let image = coverDocument.descendants(named: "img").first ?? coverDocument.descendants(named: "image").first,
              let link = image.attributes["src"] ?? image.attributes["href"] ?? image.attributes["xlink:href"],
              let imagePath = EPUBLocation(link, relativeTo: coverPath)?.path else { return nil }
        return try? archive.data(at: imagePath, maximumSize: 12 * 1024 * 1024)
    }

    private static func chapterSections(_ document: EPUBXHTML, names: [Entry], number: Int) -> [LocalChapter] {
        let content = document.text as NSString
        var positions: [Int: String] = [:]
        let title = names.first(where: { $0.location.fragment == nil })?.title
            ?? document.heading ?? "第 \(number) 节"
        for name in names {
            guard let fragment = name.location.fragment, let position = document.anchors[fragment],
                  position < content.length, positions[position] == nil else { continue }
            positions[position] = name.title
        }

        let boundaries = Set([0, content.length] + Array(positions.keys)).sorted()
        var chapters: [LocalChapter] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            let section = content.substring(with: NSRange(location: start, length: end - start))
            let label = positions[start] ?? title
            let text = EPUBXHTML.clean(section)
            guard !text.isEmpty else { continue }
            let paragraphs = text.components(separatedBy: "\n\n")
            let body = paragraphs.count > 1 && paragraphs[0] == label ? paragraphs.dropFirst().joined(separator: "\n\n") : text
            chapters.append(contentsOf: LocalChapter.sections(body, title: label))
        }
        return chapters
    }

    private static func cleanInline(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private struct EPUBLocation {
    let path: String
    let fragment: String?

    init?(_ href: String, relativeTo base: String = "") {
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let raw = parts.first?.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard !raw.hasPrefix("//"), raw.split(separator: "/").first?.contains(":") != true,
              let decoded = String(raw).removingPercentEncoding, !decoded.contains("\\") else { return nil }
        if decoded.isEmpty {
            guard !base.isEmpty else { return nil }
            path = base
        } else {
            var components = decoded.hasPrefix("/") ? [] : Array(base.split(separator: "/").dropLast())
            for part in decoded.split(separator: "/") {
                switch part {
                case ".": continue
                case "..":
                    guard !components.isEmpty else { return nil }
                    components.removeLast()
                default: components.append(part)
                }
            }
            guard !components.isEmpty else { return nil }
            path = components.joined(separator: "/")
        }
        fragment = parts.count == 2 && !parts[1].isEmpty ? String(parts[1]).removingPercentEncoding : nil
    }
}

private final class EPUBXMLNode {
    private enum Content {
        case text(String)
        case element(EPUBXMLNode)
    }

    let name: String
    let attributes: [String: String]
    private var content: [Content] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    var children: [EPUBXMLNode] {
        content.compactMap { item in
            if case .element(let child) = item { return child }
            return nil
        }
    }

    var text: String {
        content.map { item in
            switch item {
            case .text(let text): text
            case .element(let child): child.text
            }
        }.joined()
    }

    func append(_ string: String) { content.append(.text(string)) }
    func append(_ child: EPUBXMLNode) { content.append(.element(child)) }

    func child(named name: String) -> EPUBXMLNode? {
        children.first { $0.name == name }
    }

    func descendants(named name: String) -> [EPUBXMLNode] {
        var matching: [EPUBXMLNode] = []
        collect(named: name, into: &matching)
        return matching
    }

    private func collect(named name: String, into matching: inout [EPUBXMLNode]) {
        for child in children {
            if child.name == name { matching.append(child) }
            child.collect(named: name, into: &matching)
        }
    }
}

private final class EPUBXMLTree: NSObject, XMLParserDelegate {
    private var root: EPUBXMLNode?
    private var stack: [EPUBXMLNode] = []

    static func read(_ data: Data) -> EPUBXMLNode? {
        let tree = EPUBXMLTree()
        guard ReadingXML.parse(data, delegate: tree) else { return nil }
        return tree.root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard stack.count < 128 else {
            parser.abortParsing()
            return
        }
        let node = EPUBXMLNode(name: ReadingXML.localName(elementName), attributes: attributeDict)
        if let parent = stack.last { parent.append(node) } else { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.append(string) }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.append(String(decoding: CDATABlock, as: UTF8.self))
    }
}
