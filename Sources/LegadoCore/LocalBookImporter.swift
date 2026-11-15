import CoreFoundation
import Foundation

public struct LocalBook: Equatable, Sendable {
    public let title: String
    public let author: String
    public let chapters: [LocalChapter]
    public let cover: Data?

    public init(title: String, author: String = "", chapters: [LocalChapter], cover: Data? = nil) {
        self.title = title
        self.author = author
        self.chapters = chapters
        self.cover = cover
    }
}

public struct LocalChapter: Equatable, Sendable {
    public let title: String
    public let text: String

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }

    static func sections(_ text: String, title: String, numbered: Bool = false) -> [LocalChapter] {
        // Bound a single layout pass when a plain book or a spine document has very long chapters.
        let limit = 16_000
        guard let firstEnd = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex),
              firstEnd < text.endIndex else { return [Self(title: title, text: text)] }
        var chapters: [LocalChapter] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            let part = text[start ..< end]
            let lineEnd = part.suffix(limit / 3).lastIndex(of: "\n").map { text.index(after: $0) }
            let boundary = end == text.endIndex ? end : (lineEnd ?? end)
            let ordinal = chapters.count + 1
            let label: String
            if numbered { label = "第 \(ordinal) 节" }
            else { label = ordinal == 1 ? title : "\(title)（续 \(ordinal)）" }
            chapters.append(Self(title: label, text: String(text[start ..< boundary])))
            start = boundary
        }
        return chapters
    }
}

public enum LocalBookImportError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat
    case unsupportedEncoding
    case emptyBook
    case invalidEPUB
    case encryptedEPUB
    case fileTooLarge

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "请选择 TXT 或 EPUB 文件。"
        case .unsupportedEncoding: "无法识别文本编码。请将文件转换为 UTF-8 后重试。"
        case .emptyBook: "书籍没有可读取的文本。"
        case .invalidEPUB: "EPUB 文件已损坏，或使用了无法读取的 ZIP 格式。"
        case .encryptedEPUB: "此 EPUB 的正文已加密。"
        case .fileTooLarge: "书籍或书内资源超过本地导入的大小限制。"
        }
    }
}

public enum LocalBookImporter {
    public static func importBook(data: Data, filename: String) throws -> LocalBook {
        guard data.count <= 128 * 1024 * 1024 else { throw LocalBookImportError.fileTooLarge }
        let file = URL(fileURLWithPath: filename)
        let title = file.deletingPathExtension().lastPathComponent
        switch file.pathExtension.lowercased() {
        case "txt":
            guard data.count <= 64 * 1024 * 1024 else { throw LocalBookImportError.fileTooLarge }
            return try importText(data, title: title)
        case "epub":
            return try EPUBBookImporter.read(data, fallbackTitle: title)
        default:
            throw LocalBookImportError.unsupportedFormat
        }
    }

    private static func importText(_ data: Data, title: String) throws -> LocalBook {
        guard let decoded = decodeText(data) else { throw LocalBookImportError.unsupportedEncoding }
        let withoutBOM = decoded.first == "\u{feff}" ? String(decoded.dropFirst()) : decoded
        let text = withoutBOM.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalBookImportError.emptyBook }

        // Cover common Chinese web-novel headings and English chapter markers on their own lines.
        let pattern = #"(?im)^\h*(?:第\h*[0-9０-９零〇一二三四五六七八九十百千万萬亿億兩两壹贰貳叁參肆伍陆陸柒捌玖拾佰仟廿卅]+\h*[章回节節卷篇部集](?:\h|[：:、．.﹕–—-])?[^\r\n]{0,65}|(?:楔子|序[章言幕]?|前言|引子|尾声|尾聲|后记|後記|终章|終章|番外)(?:(?:\h+|[：:、．.﹕–—-])[^\r\n]{0,65}|[0-9一二三四五六七八九十]+[^\r\n]{0,55})?|(?:chapter|part|book)\h+(?:[0-9]+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty)\b[^\r\n]{0,65}|(?:prologue|epilogue|preface)\b(?:\h*[:.\-–—][^\r\n]{0,65})?)\h*$"#
        let expression = try NSRegularExpression(pattern: pattern)
        let body = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: body.length))
        var chapters: [LocalChapter] = []
        var start = 0
        var heading: String?
        for match in matches {
            let section = body.substring(with: NSRange(location: start, length: match.range.location - start))
            let content = section.trimmingCharacters(in: .whitespacesAndNewlines)
            if let heading {
                chapters.append(contentsOf: LocalChapter.sections(content, title: heading))
            } else if !content.isEmpty {
                chapters.append(contentsOf: LocalChapter.sections(content, title: "正文", numbered: true))
            }
            heading = body.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            start = NSMaxRange(match.range)
        }
        let remaining = body.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
        if let heading {
            chapters.append(contentsOf: LocalChapter.sections(remaining, title: heading))
        } else {
            chapters.append(contentsOf: LocalChapter.sections(remaining, title: "正文", numbered: true))
        }
        return LocalBook(title: title, chapters: chapters)
    }

    private static func decodeText(_ data: Data) -> String? {
        let prefix = Array(data.prefix(4_096))
        let positivePrefix = prefix.count / 2
        let evenZeros = stride(from: 0, to: prefix.count, by: 2).filter { prefix[$0] == 0 }.count
        let oddZeros = stride(from: 1, to: prefix.count, by: 2).filter { prefix[$0] == 0 }.count
        var encodings: [String.Encoding] = []
        if prefix.starts(with: [0xff, 0xfe, 0x00, 0x00]) || prefix.starts(with: [0x00, 0x00, 0xfe, 0xff]) {
            encodings = [.utf32]
        } else if prefix.starts(with: [0xff, 0xfe]) || prefix.starts(with: [0xfe, 0xff]) {
            encodings = [.utf16]
        } else {
            if positivePrefix >= 2 {
                if oddZeros > positivePrefix / 4, evenZeros == 0 { encodings.append(.utf16LittleEndian) }
                if evenZeros > positivePrefix / 4, oddZeros == 0 { encodings.append(.utf16BigEndian) }
            }
            encodings.append(.utf8)
            encodings.append(String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0632))) // GB 18030
            encodings.append(String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0a03))) // Big5
            encodings.append(contentsOf: [.windowsCP1252, .isoLatin1])
        }
        for encoding in encodings {
            guard let text = String(data: data, encoding: encoding) else { continue }
            let hasBinaryControls = text.unicodeScalars.prefix(4_096).contains { scalar in
                scalar.value < 32 && ![9, 10, 12, 13].contains(scalar.value)
            }
            if !hasBinaryControls { return text }
        }
        return nil
    }
}
