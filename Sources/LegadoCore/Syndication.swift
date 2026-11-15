import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct SyndicationFeed: Equatable, Sendable {
    public let title: String
    public let articles: [SyndicatedArticle]
}

public struct SyndicatedArticle: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let url: URL?
    public let date: Date?
}

public enum SyndicationError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case invalidResponse
    case serverStatus(Int)
    case invalidFeed
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入完整的 HTTP 或 HTTPS 订阅地址。"
        case .invalidResponse: "无法读取订阅服务器的响应。"
        case .serverStatus(let status): "订阅服务器返回 HTTP \(status)。"
        case .invalidFeed: "该地址未返回可读取的 RSS 或 Atom 订阅。"
        case .tooLarge: "订阅文件超过 4 MB。"
        }
    }
}

public enum SyndicationReader {
    private static let maximumBytes = 4 * 1024 * 1024

    public static func webURL(_ value: String, relativeTo base: URL? = nil) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    public static func fetch(_ url: URL) async throws -> SyndicationFeed {
        guard let url = webURL(url.absoluteString) else { throw SyndicationError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue("application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.8", forHTTPHeaderField: "Accept")
        #if canImport(FoundationNetworking)
        let (data, response) = try await URLSession.shared.data(for: request)
        let base = try validate(response)
        #else
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        defer { stream.task.cancel() }
        let base = try validate(response)
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in stream {
            guard data.count < maximumBytes else { throw SyndicationError.tooLarge }
            data.append(byte)
        }
        #endif
        try Task.checkCancellation()
        return try parse(data, baseURL: base)
    }

    public static func parse(_ data: Data, baseURL: URL) throws -> SyndicationFeed {
        guard data.count <= maximumBytes else { throw SyndicationError.tooLarge }
        guard let base = webURL(baseURL.absoluteString) else { throw SyndicationError.invalidURL }
        let collector = SyndicationCollector(baseURL: base)
        guard ReadingXML.parse(data, delegate: collector), let feed = collector.feed else { throw SyndicationError.invalidFeed }
        return feed
    }

    private static func validate(_ response: URLResponse) throws -> URL {
        guard let response = response as? HTTPURLResponse, let value = response.url?.absoluteString,
              let base = webURL(value) else { throw SyndicationError.invalidResponse }
        guard (200 ..< 300).contains(response.statusCode) else { throw SyndicationError.serverStatus(response.statusCode) }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw SyndicationError.tooLarge }
        return base
    }
}

private final class SyndicationCollector: NSObject, XMLParserDelegate {
    private enum Kind: String {
        case rss, rdf, feed

        var entryName: String { self == .feed ? "entry" : "item" }
        var entryDepth: Int { self == .rss ? 3 : 2 }
        var channelDepth: Int { self == .feed ? 1 : 2 }
    }

    private struct Element {
        let name: String
        let base: URL
    }

    private struct Field {
        let key: String
        let depth: Int
        let base: URL
        let isHTML: Bool
        let mayBePermalink: Bool
        var text = ""
        var length = 0

        mutating func append(_ value: String) {
            guard length < 12_000 else { return }
            let available = value.prefix(12_000 - length)
            text.append(contentsOf: available)
            length += available.count
        }
    }

    private struct Article {
        var identifier = ""
        var title = ""
        var summary = ""
        var content = ""
        var publicationDate: Date?
        var updateDate: Date?
        var link: URL?
        var permalink: URL?
    }

    private let baseURL: URL
    private var stack: [Element] = []
    private var kind: Kind?
    private var channelExists = false
    private var field: Field?
    private var hiddenDepth: Int?
    private var current: Article?
    private var title = ""
    private var articles: [SyndicatedArticle] = []
    private var seen: Set<String> = []

    private lazy var regularISODate = ISO8601DateFormatter()
    private lazy var fractionalISODate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private lazy var rssDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    init(baseURL: URL) { self.baseURL = baseURL }

    var feed: SyndicationFeed? {
        guard channelExists else { return nil }
        return SyndicationFeed(title: title.isEmpty ? (baseURL.host ?? baseURL.absoluteString) : title, articles: articles)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard stack.count < 96 else {
            parser.abortParsing()
            return
        }
        let name = ReadingXML.localName(elementName)
        let parent = stack.last
        let parentBase = parent?.base ?? baseURL
        let base = attributeDict["xml:base"].flatMap { SyndicationReader.webURL($0, relativeTo: parentBase) } ?? parentBase
        stack.append(Element(name: name, base: base))
        if stack.count == 1 { kind = Kind(rawValue: name) }
        guard let kind else {
            parser.abortParsing()
            return
        }

        if (kind == .feed && stack.count == 1) || (stack.count == 2 && name == "channel") { channelExists = true }
        if stack.count == kind.entryDepth, name == kind.entryName, articles.count < 200,
           kind != .rss || parent?.name == "channel" {
            current = Article()
            return
        }
        if field != nil {
            guard hiddenDepth == nil else { return }
            if ["script", "style", "template"].contains(name) { hiddenDepth = stack.count }
            if SourceHTML.blockTags.contains(name) || name == "br" { field?.append("\n") }
            return
        }
        let isArticleField = current != nil && stack.count == kind.entryDepth + 1
        let isFeedTitle = stack.count == kind.channelDepth + 1 && name == "title"
            && parent?.name == (kind == .feed ? "feed" : "channel")
        let articleFields = ["title", "link", "id", "guid", "description", "summary", "encoded", "content", "pubdate", "published", "updated", "date"]
        guard isFeedTitle || (isArticleField && articleFields.contains(name)) else { return }

        if name == "link", let href = attributeDict["href"] {
            let relation = attributeDict["rel"] ?? "alternate"
            if relation == "alternate", current?.link == nil {
                current?.link = SyndicationReader.webURL(href, relativeTo: base)
            }
            return
        }
        let type = attributeDict["type", default: ""].lowercased()
        let isHTML = ["html", "text/html"].contains(type) || ["description", "encoded"].contains(name)
        let mayBePermalink = kind != .feed && name == "guid" && attributeDict["isPermaLink"]?.lowercased() != "false"
        field = Field(key: name, depth: stack.count, base: base, isHTML: isHTML, mayBePermalink: mayBePermalink)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer { _ = stack.popLast() }
        let depth = stack.count
        if let hiddenDepth {
            if hiddenDepth == depth { self.hiddenDepth = nil }
            return
        }
        if let field, field.depth == depth {
            accept(field)
            self.field = nil
        } else if let name = stack.last?.name, SourceHTML.blockTags.contains(name) {
            field?.append("\n")
        }
        if let kind, depth == kind.entryDepth, stack.last?.name == kind.entryName, let current {
            append(current)
            self.current = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if hiddenDepth == nil { field?.append(string) }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if hiddenDepth == nil { field?.append(String(decoding: CDATABlock, as: UTF8.self)) }
    }

    private func accept(_ field: Field) {
        let text = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if current == nil {
            if field.key == "title", title.isEmpty { title = displayText(text, asHTML: field.isHTML, limit: 240) }
            return
        }
        switch field.key {
        case "title":
            if current?.title.isEmpty == true { current?.title = displayText(text, asHTML: field.isHTML, limit: 340) }
        case "link":
            if current?.link == nil { current?.link = SyndicationReader.webURL(text, relativeTo: field.base) }
        case "id", "guid":
            if current?.identifier.isEmpty == true { current?.identifier = String(text.prefix(1_024)) }
            if field.mayBePermalink { current?.permalink = SyndicationReader.webURL(text) }
        case "summary", "description":
            if current?.summary.isEmpty == true { current?.summary = displayText(text, asHTML: field.isHTML, limit: 4_000) }
        case "content", "encoded":
            if current?.content.isEmpty == true { current?.content = displayText(text, asHTML: field.isHTML, limit: 4_000) }
        case "pubdate", "published", "date":
            if current?.publicationDate == nil { current?.publicationDate = date(text) }
        case "updated":
            if current?.updateDate == nil { current?.updateDate = date(text) }
        default:
            break
        }
    }

    private func append(_ article: Article) {
        let link = article.link ?? article.permalink
        let text = article.summary.isEmpty ? article.content : article.summary
        guard !article.title.isEmpty || !text.isEmpty || link != nil else { return }
        let date = article.publicationDate ?? article.updateDate
        let fallbackID = link?.absoluteString ?? "\(article.title)|\(date?.timeIntervalSince1970 ?? 0)|\(text.prefix(240))"
        let id = article.identifier.isEmpty ? fallbackID : article.identifier
        guard seen.insert(id).inserted else { return }
        let title = article.title.isEmpty ? (link?.host ?? "无标题") : article.title
        articles.append(SyndicatedArticle(id: id, title: title, summary: text, url: link, date: date))
    }

    private func displayText(_ text: String, asHTML: Bool, limit: Int) -> String {
        let plain = asHTML ? SourceHTML.plainText(text) : text
        let lines = plain.components(separatedBy: .newlines).map { line in
            line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }.filter { !$0.isEmpty }
        return String(lines.joined(separator: "\n\n").prefix(limit))
    }

    private func date(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        if let date = fractionalISODate.date(from: text) ?? regularISODate.date(from: text) { return date }
        for format in ["EEE, dd MMM yyyy HH:mm:ss z", "dd MMM yyyy HH:mm:ss z", "EEE, dd MMM yy HH:mm:ss z", "EEE, dd MMM yyyy HH:mm z"] {
            rssDate.dateFormat = format
            if let date = rssDate.date(from: text) { return date }
        }
        return nil
    }
}
