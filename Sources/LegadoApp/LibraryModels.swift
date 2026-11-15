import Foundation
import LegadoCore

struct LibraryBook: Codable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var author: String
    var intro: String?
    var coverURL: String?
    var sourceID: String?
    var bookURL: String?
    var tocURL: String?
    var chapters: [LibraryChapter]
    var addedAt = Date()
    var lastRead: Date?
    var progress: ReaderProgress?
    var bookmarks: [BookBookmark] = []
    var note = ""
    var storageID: UUID?
    var localFingerprint: String?

    var isLocal: Bool { sourceID == nil }
    var diskID: UUID { storageID ?? id }
    var currentChapter: LibraryChapter? { chapters.first { $0.id == progress?.chapterID } }

    var readingFraction: Double {
        guard let index = chapters.firstIndex(where: { $0.id == progress?.chapterID }), !chapters.isEmpty else {
            return 0
        }
        return Double(index + 1) / Double(chapters.count)
    }
}

struct LibraryChapter: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    var remoteURL: String?
}

struct BookBookmark: Codable, Identifiable, Sendable {
    let id: UUID
    let progress: ReaderProgress
    let date: Date

    init(progress: ReaderProgress, id: UUID = UUID(), date: Date = .now) {
        self.id = id
        self.date = date
        self.progress = progress
    }
}

struct LibraryIndex: Codable, Sendable {
    var version = 1
    var books: [LibraryBook] = []
    var sources: [BookSource] = []
    var replacements: [TextReplacement] = []
}

struct LibraryBackup: Codable, Sendable {
    static let maxBytes = 256 * 1024 * 1024
    static let feedDefaultsKey = "readerFeedSubscriptions"
    var format = "legado-ios-backup"
    var index: LibraryIndex
    var payloads: [UUID: [String: Data]]
    var feedSubscriptions: Data?
}

struct LibraryMessage: Identifiable {
    var id = UUID()
    var title: String
    var detail: String
}

enum LibraryError: LocalizedError {
    case noChapters, missingSource, missingContent, invalidURL, invalidSource, invalidBackup, tooLarge, duplicateBook
    case rejectedHTTP(Int)

    var errorDescription: String? {
        switch self {
        case .noChapters: "没有找到可阅读的章节。请检查目录规则。"
        case .missingSource: "书源已移除。重新导入对应书源后可继续加载在线章节。"
        case .missingContent: "该章节的文件缺失，或书源返回了空正文。"
        case .invalidURL: "请输入有效的 HTTP 或 HTTPS 地址。"
        case .invalidSource: "请输入有效的书源名称和 HTTP 或 HTTPS 书源地址。"
        case .invalidBackup: "无法恢复此备份。请使用此应用导出的备份文件。"
        case .tooLarge: "文件超过支持的大小。"
        case .duplicateBook: "候选书源的这本书已在书架中。"
        case .rejectedHTTP(let status): "服务器返回 HTTP \(status)。"
        }
    }
}
