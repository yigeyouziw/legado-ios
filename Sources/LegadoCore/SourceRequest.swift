import CoreFoundation
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct SourceRequest {
    let url: URL
    let request: URLRequest
    let responseCharset: String?
    let retryCount: Int

    private static let optionsPattern = try! NSRegularExpression(pattern: #"\s*,\s*(?=\{)"#)
    private static let templates = try! NSRegularExpression(pattern: #"(?s)\{\{(.*?)\}\}|\$\{(key|page)\}"#)
    private static let choices = try! NSRegularExpression(pattern: #"<([^<>]*,[^<>]*)>"#)

    init(_ expression: String, base: URL?, source: BookSource, key: String = "", page: Int = 1) throws {
        guard !Self.isScript(expression) else { throw SourceError.unsupportedRule("JavaScript 地址") }
        let pieces = Self.split(expression)
        let options: [String: SourceJSON]
        if let rawOptions = pieces.options {
            if let decoded = try? JSONDecoder().decode([String: SourceJSON].self, from: Data(rawOptions.utf8)) {
                options = decoded
            } else {
                let expanded = try Self.interpolate(rawOptions, key: Self.jsonEscape(key), page: page)
                guard let decoded = try? JSONDecoder().decode([String: SourceJSON].self, from: Data(expanded.utf8)) else {
                    throw SourceError.unsupportedRule("URL 请求选项")
                }
                options = decoded
            }
        } else {
            options = [:]
        }
        if options["webView"]?.boolean == true || options["webview"]?.boolean == true ||
            ["webJs", "bodyJs", "js"].contains(where: { options[$0]?.text?.sourceNonempty != nil }) {
            throw SourceError.unsupportedRule("网页执行")
        }
        if source.value("loginCheckJs")?.text?.sourceNonempty != nil {
            throw SourceError.unsupportedRule("登录验证脚本")
        }

        let charset = options["charset"]?.text?.sourceNonempty
        let escaped = try Self.encodedParameter(key, charset: charset)
        let expanded = try Self.interpolate(pieces.address, key: escaped, page: page, encodedKey: escaped)
        guard let url = URL(string: expanded.sourceTrimmed, relativeTo: base)?.absoluteURL, url.isSourceHTTP else {
            throw SourceError.invalidURL(expanded)
        }
        self.url = url
        responseCharset = options["responseCharset"]?.text?.sourceNonempty ?? charset
        retryCount = max(0, min(2, Int(options["retry"]?.text ?? "") ?? 0))

        var request = URLRequest(url: url, timeoutInterval: 25)
        let method = options["method"]?.text?.uppercased() ?? "GET"
        guard ["GET", "POST", "HEAD"].contains(method) else { throw SourceError.unsupportedRule("HTTP \(method)") }
        request.httpMethod = method
        request.setValue("Mozilla/5.0 (iPhone; Mobile) AppleWebKit/605.1.15 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/json,application/xhtml+xml,text/plain,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let sourceHeader = source.value("header") ?? source.value("headers")
        if let raw = sourceHeader?.text, raw.sourceNonempty != nil, sourceHeader?.objectOrEncodedObject == nil {
            throw SourceError.unsupportedRule("动态请求头")
        }
        let headers = (sourceHeader?.objectOrEncodedObject ?? [:])
            .merging((options["headers"] ?? options["header"])?.objectOrEncodedObject ?? [:]) { _, new in new }
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            guard let raw = value.text, !name.isEmpty,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }) else { continue }
            let rendered = try Self.interpolate(raw, key: key, page: page)
            guard !rendered.contains(where: \.isNewline) else { throw SourceError.unsupportedRule("请求头 \(name)") }
            request.setValue(rendered, forHTTPHeaderField: name)
        }
        if method == "POST", let body = options["body"] {
            switch body {
            case .object, .array:
                request.httpBody = try JSONEncoder().encode(Self.interpolate(body, key: key, page: page))
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            default:
                let template = body.text ?? ""
                let trimmed = template.sourceTrimmed
                let contentType = request.value(forHTTPHeaderField: "Content-Type")?.lowercased()
                if ["{", "["].contains(where: { trimmed.hasPrefix($0) }) || contentType?.contains("json") == true {
                    let rendered = try Self.interpolate(template, key: Self.jsonEscape(key), page: page, encodedKey: escaped)
                    request.httpBody = Data(rendered.utf8)
                    if contentType == nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
                } else if trimmed.hasPrefix("<") || (contentType != nil && contentType?.contains("x-www-form-urlencoded") == false) {
                    let rendered = try Self.interpolate(template, key: key, page: page, encodedKey: escaped)
                    request.httpBody = try SourceEncoding.data(rendered, charset: charset)
                    if contentType == nil { request.setValue("application/xml", forHTTPHeaderField: "Content-Type") }
                } else {
                    let encoded = escaped.replacingOccurrences(of: "%20", with: "+")
                    let rendered = try Self.interpolate(template, key: encoded, page: page, encodedKey: escaped)
                    request.httpBody = Data(rendered.utf8)
                    if contentType == nil {
                        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    }
                }
            }
        }
        self.request = request
    }

    static func split(_ expression: String) -> (address: String, options: String?) {
        if let match = optionsPattern.firstMatch(in: expression, range: NSRange(expression.startIndex..., in: expression)),
           let range = Range(match.range, in: expression) {
            return (String(expression[..<range.lowerBound]).sourceTrimmed, String(expression[range.upperBound...]).sourceTrimmed)
        }
        return (expression.sourceTrimmed, nil)
    }

    static func absolute(_ expression: String?, relativeTo base: URL) -> String? {
        guard let expression = expression?.sourceNonempty else { return nil }
        let pieces = split(expression)
        guard let url = URL(string: pieces.address, relativeTo: base)?.absoluteURL, url.isSourceHTTP else { return nil }
        if let options = pieces.options { return "\(url.absoluteString),\(options)" }
        return url.absoluteString
    }

    static func isScript(_ expression: String) -> Bool {
        let raw = expression.lowercased()
        return raw.contains("@js:") || raw.contains("<js>") || raw.contains("@webjs:") || raw.contains("<webjs>")
    }

    static func supportsPagination(_ expression: String?) -> Bool {
        guard let expression else { return false }
        let range = NSRange(expression.startIndex..., in: expression)
        let raw = expression as NSString
        return choices.firstMatch(in: expression, range: range) != nil ||
            templates.matches(in: expression, range: range).contains { match in
                raw.substring(with: match.range).range(of: #"\bpage\b"#, options: .regularExpression) != nil
            }
    }

    private static func encodedParameter(_ text: String, charset: String?) throws -> String {
        let bytes = try SourceEncoding.data(text, charset: charset)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~".utf8)
        return bytes.map { allowed.contains($0) ? String(Unicode.Scalar($0)) : String(format: "%%%02X", $0) }.joined()
    }

    private static func interpolate(_ json: SourceJSON, key: String, page: Int) throws -> SourceJSON {
        switch json {
        case .string(let value): return .string(try interpolate(value, key: key, page: page))
        case .object(let values): return .object(try values.mapValues { try interpolate($0, key: key, page: page) })
        case .array(let values): return .array(try values.map { try interpolate($0, key: key, page: page) })
        default: return json
        }
    }

    private static func interpolate(_ text: String, key: String, page: Int, encodedKey: String? = nil) throws -> String {
        let page = max(1, min(page, 1_000_000))
        let input = text as NSString
        let selection = NSMutableString(string: text)
        for match in choices.matches(in: text, range: NSRange(location: 0, length: input.length)).reversed() {
            let candidates = input.substring(with: match.range(at: 1)).components(separatedBy: ",")
            selection.replaceCharacters(in: match.range, with: candidates[min(page - 1, candidates.count - 1)].sourceTrimmed)
        }

        let selected = selection as String
        let originals = selected as NSString
        let rendered = NSMutableString(string: selected)
        for match in templates.matches(in: selected, range: NSRange(location: 0, length: originals.length)).reversed() {
            let group = match.range(at: 1).location == NSNotFound ? 2 : 1
            let expression = originals.substring(with: match.range(at: group)).sourceTrimmed
                .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            let value: String
            switch expression {
            case "key", "keyword": value = key
            case "page": value = String(page)
            case "encodeURI(key)", "encodeURIComponent(key)", "java.encodeURI(key)", "java.encodeURIComponent(key)":
                value = try encodedKey ?? encodedParameter(key, charset: nil)
            default:
                if let parsed = pageExpression(expression, page: page) {
                    value = String(parsed)
                } else {
                    throw SourceError.unsupportedRule("地址表达式 \(expression)")
                }
            }
            rendered.replaceCharacters(in: match.range, with: value)
        }
        return rendered as String
    }

    private static func pageExpression(_ expression: String, page: Int) -> Int? {
        if let match = sourceCaptures(#"^(?:\(page(?:([+-])(\d+))\)|page)(?:([+*-])(\d+))?$"#, in: expression) {
            let offset = Int(match[2]) ?? 0
            let parameter = Int(match[4]) ?? 0
            guard offset <= 1_000_000, parameter <= 1_000_000 else { return nil }
            let base = match[1] == "-" ? page - offset : page + offset
            switch match[3] {
            case "+": return base + parameter
            case "-": return base - parameter
            case "*": return base * parameter
            default: return base
            }
        }
        return Int(expression)
    }

    private static func jsonEscape(_ text: String) -> String {
        guard let encoded = try? JSONEncoder().encode(text),
              let escaped = String(data: encoded, encoding: .utf8) else { return text }
        return String(escaped.dropFirst().dropLast())
    }
}

enum SourceEncoding {
    static func text(_ data: Data, declared: String?, preferred: String?) throws -> String {
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]),
           let decoded = String(data: data, encoding: .utf16) { return decoded }
        let bom = data.starts(with: [0xef, 0xbb, 0xbf])
        let clean = bom ? Data(data.dropFirst(3)) : data
        if bom, let decoded = String(data: clean, encoding: .utf8) { return decoded }
        let sample = String(decoding: clean.prefix(8_192), as: UTF8.self)
        let meta = sourceCaptures(#"(?is)<(?:meta|xml|\?xml)\b[^>]*?(?:charset|encoding)\s*=\s*["']?([\w-]+)"#, in: sample)?[1]
        let hints = [declared, meta, preferred].compactMap { $0?.sourceNonempty }
        for charset in hints {
            if let encoding = encoding(charset), let decoded = String(data: clean, encoding: encoding) { return decoded }
        }
        if let utf8 = String(data: clean, encoding: .utf8) { return utf8 }
        if let chinese = encoding("GB18030"), let decoded = String(data: clean, encoding: chinese) { return decoded }
        if let western = String(data: clean, encoding: .windowsCP1252) { return western }
        throw SourceError.unsupportedEncoding(hints.first ?? "未知")
    }

    static func data(_ text: String, charset: String?) throws -> Data {
        guard let charset = charset?.sourceNonempty else { return Data(text.utf8) }
        if text.isEmpty { return Data() }
        if charset.lowercased() == "escape" { return Data(text.utf8) }
        guard let encoding = encoding(charset), let data = text.data(using: encoding) else {
            throw SourceError.unsupportedEncoding(charset)
        }
        return data
    }

    private static func encoding(_ name: String) -> String.Encoding? {
        let charset: String
        switch name.lowercased() {
        case "gbk", "gb2312", "x-gbk", "cp936", "gb_2312-80": charset = "GB18030"
        case "utf8": charset = "UTF-8"
        default: charset = name
        }
        guard let label = charset.withCString({ CFStringCreateWithCString(nil, $0, CFStringBuiltInEncodings.UTF8.rawValue) }) else { return nil }
        let value = CFStringConvertIANACharSetNameToEncoding(label)
        guard value != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value))
    }
}
