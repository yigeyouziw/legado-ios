import Foundation

enum SourceJSON: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([SourceJSON])
    case object([String: SourceJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SourceJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: SourceJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var text: String? {
        switch self {
        case .null, .array, .object: nil
        case .bool(let value): String(value)
        case .integer(let value): String(value)
        case .number(let value): String(value)
        case .string(let value): value
        }
    }

    var items: [SourceJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var fields: [String: SourceJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var objectOrEncodedObject: [String: SourceJSON]? {
        if let fields { return fields }
        guard let text else { return nil }
        return try? JSONDecoder().decode([String: SourceJSON].self, from: Data(text.utf8))
    }

    var boolean: Bool? {
        switch text?.lowercased() {
        case "true", "1": true
        case "false", "0": false
        default: nil
        }
    }
}

public struct BookSource: Codable, Hashable, Identifiable, Sendable {
    private var definition: [String: SourceJSON]

    public var id: String { bookSourceUrl }
    public var bookSourceUrl: String {
        get { definition["bookSourceUrl"]?.text?.sourceTrimmed ?? "" }
        set { definition["bookSourceUrl"] = .string(newValue.sourceTrimmed) }
    }
    public var bookSourceName: String {
        get { definition["bookSourceName"]?.text?.sourceTrimmed ?? "" }
        set { definition["bookSourceName"] = .string(newValue.sourceTrimmed) }
    }
    public var bookSourceGroup: String? {
        get { definition["bookSourceGroup"]?.text }
        set { definition["bookSourceGroup"] = newValue.map(SourceJSON.string) }
    }
    public var enabled: Bool {
        get { definition["enabled"]?.boolean ?? true }
        set { definition["enabled"] = .bool(newValue) }
    }
    public var enabledExplore: Bool {
        get { definition["enabledExplore"]?.boolean ?? true }
        set { definition["enabledExplore"] = .bool(newValue) }
    }
    public var bookSourceType: Int { Int(definition["bookSourceType"]?.text ?? "") ?? 0 }
    public var searchUrl: String? { definition["searchUrl"]?.text?.sourceNonempty }
    public var exploreUrl: String? { definition["exploreUrl"]?.text?.sourceNonempty }
    public var bookSourceComment: String? { definition["bookSourceComment"]?.text?.sourceNonempty }

    public init(bookSourceUrl: String, bookSourceName: String, bookSourceGroup: String? = nil, enabled: Bool = true) {
        definition = [:]
        self.bookSourceUrl = bookSourceUrl
        self.bookSourceName = bookSourceName
        self.bookSourceGroup = bookSourceGroup
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        definition = try container.decode([String: SourceJSON].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(definition)
    }

    public static func decodeImport(_ data: Data) throws -> [BookSource] {
        let decoder = JSONDecoder()
        let normalized = data.starts(with: [0xef, 0xbb, 0xbf]) ? Data(data.dropFirst(3)) : data
        let sources: [BookSource]
        if let array = try? decoder.decode([BookSource].self, from: normalized) {
            sources = array
        } else if let source = try? decoder.decode(BookSource.self, from: normalized) {
            sources = [source]
        } else {
            throw SourceError.invalidImport("需要 Legado JSON 单个书源或书源数组")
        }
        guard !sources.isEmpty else { throw SourceError.invalidImport("书源列表为空") }
        for (index, source) in sources.enumerated() {
            guard !source.bookSourceName.isEmpty,
                  let url = URL(string: source.bookSourceUrl), url.isSourceHTTP else {
                throw SourceError.invalidImport("第 \(index + 1) 个书源需要名称和有效的 HTTP(S) 地址")
            }
        }
        return sources
    }

    func rule(_ key: String) -> [String: SourceJSON] { definition[key]?.objectOrEncodedObject ?? [:] }
    func value(_ key: String) -> SourceJSON? { definition[key] }
}

public struct SourceSearchResult: Hashable, Identifiable, Sendable {
    public let sourceID: String
    public let bookURL: String
    public let name: String
    public let author: String
    public let coverURL: String?
    public let intro: String?
    public var id: String { sourceID + "\u{001F}" + bookURL }

    public init(sourceID: String, bookURL: String, name: String, author: String, coverURL: String? = nil, intro: String? = nil) {
        self.sourceID = sourceID
        self.bookURL = bookURL
        self.name = name
        self.author = author
        self.coverURL = coverURL
        self.intro = intro
    }
}

public struct SourceBookDetail: Hashable, Sendable {
    public let sourceID: String
    public let bookURL: String
    public let tocURL: String
    public let name: String
    public let author: String
    public let coverURL: String?
    public let intro: String?

    public init(sourceID: String, bookURL: String, tocURL: String, name: String, author: String, coverURL: String? = nil, intro: String? = nil) {
        self.sourceID = sourceID
        self.bookURL = bookURL
        self.tocURL = tocURL
        self.name = name
        self.author = author
        self.coverURL = coverURL
        self.intro = intro
    }
}

public struct RemoteChapter: Hashable, Identifiable, Sendable {
    public let title: String
    public let url: String
    public let isVolume: Bool
    public var id: String { url + "\u{001F}" + title }

    public init(title: String, url: String, isVolume: Bool = false) {
        self.title = title
        self.url = url
        self.isVolume = isVolume
    }
}

public struct SourceExploreCategory: Hashable, Identifiable, Sendable {
    public let title: String
    public let url: String
    public var id: String { title + "\u{001F}" + url }

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

public enum SourceError: LocalizedError, Equatable, Sendable {
    case invalidImport(String)
    case missingRule(String)
    case unsupportedRule(String)
    case invalidURL(String)
    case badResponse
    case httpStatus(Int)
    case unsupportedEncoding(String)
    case emptyResult(String)
    case tooManyPages

    public var errorDescription: String? {
        switch self {
        case .invalidImport(let message): "书源导入失败：\(message)"
        case .missingRule(let name): "书源缺少\(name)规则"
        case .unsupportedRule(let name): "暂不支持该书源的\(name)规则"
        case .invalidURL(let url): "书源地址无效：\(url)"
        case .badResponse: "书源未返回有效的 HTTP 响应"
        case .httpStatus(let status): "书源返回 HTTP \(status)"
        case .unsupportedEncoding(let charset): "无法解码书源字符集：\(charset)"
        case .emptyResult(let name): "书源未返回\(name)，请检查规则"
        case .tooManyPages: "书源分页超出限制，请检查下一页规则"
        }
    }
}

extension String {
    var sourceTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var sourceNonempty: String? { sourceTrimmed.isEmpty ? nil : sourceTrimmed }
}

extension URL {
    var isSourceHTTP: Bool {
        guard let scheme = scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return host?.isEmpty == false
    }
}
