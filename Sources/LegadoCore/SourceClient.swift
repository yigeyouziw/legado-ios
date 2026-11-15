import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SourceClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func supportsPagination(_ expression: String?) -> Bool {
        SourceRequest.supportsPagination(expression)
    }

    public func search(source: BookSource, keyword: String, page: Int = 1) async throws -> [SourceSearchResult] {
        try requireText(source)
        guard let keyword = keyword.sourceNonempty else { return [] }
        guard let request = source.searchUrl else { throw SourceError.missingRule("搜索地址") }
        let firstPage = try await fetch(request, source: source, key: keyword, page: page)
        let bookPattern = source.value("bookUrlPattern")?.text?.sourceNonempty
        if let bookPattern, firstPage.url.absoluteString.range(of: bookPattern, options: .regularExpression) != nil {
            let detail = try extractDetails(source: source, bookURL: firstPage.url.absoluteString, page: firstPage)
            if !detail.name.isEmpty {
                return [SourceSearchResult(sourceID: source.id, bookURL: detail.bookURL, name: detail.name,
                                           author: detail.author, coverURL: detail.coverURL, intro: detail.intro)]
            }
        }
        return try extractList(source: source, rules: source.rule("ruleSearch"), page: firstPage)
    }

    public func exploreCategories(source: BookSource) throws -> [SourceExploreCategory] {
        try requireText(source)
        guard source.enabledExplore, let raw = source.exploreUrl else { return [] }
        guard !SourceRequest.isScript(raw) else { throw SourceError.unsupportedRule("JavaScript 发现分类") }
        if raw.hasPrefix("[") {
            guard let categories = try? JSONDecoder().decode([SourceJSON].self, from: Data(raw.utf8)) else {
                throw SourceError.unsupportedRule("发现分类 JSON")
            }
            return categories.compactMap { category in
                if let fields = category.fields, let url = fields["url"]?.text?.sourceNonempty {
                    let title = fields["title"]?.text?.sourceNonempty ?? fields["name"]?.text?.sourceNonempty ?? url
                    return SourceExploreCategory(title: title, url: url)
                }
                return category.text.flatMap(parseCategory)
            }
        }
        return raw.components(separatedBy: .newlines)
            .flatMap { splitSourceRule($0, on: "&&") }
            .compactMap(parseCategory)
    }

    public func explore(source: BookSource, category: SourceExploreCategory, page: Int = 1) async throws -> [SourceSearchResult] {
        try requireText(source)
        let response = try await fetch(category.url, source: source, page: page)
        return try extractList(source: source, rules: source.rule("ruleExplore"), page: response)
    }

    public func detail(source: BookSource, bookURL: String) async throws -> SourceBookDetail {
        try requireText(source)
        let response = try await fetch(bookURL, source: source)
        return try extractDetails(source: source, bookURL: bookURL, page: response)
    }

    public func chapters(source: BookSource, tocURL: String) async throws -> [RemoteChapter] {
        try requireText(source)
        let rules = source.rule("ruleToc")
        if rules["preUpdateJs"]?.text?.sourceNonempty != nil || rules["formatJs"]?.text?.sourceNonempty != nil {
            throw SourceError.unsupportedRule("目录脚本")
        }
        guard let listRule = rules["chapterList"]?.text?.sourceNonempty else { throw SourceError.missingRule("目录") }
        let reverse = listRule.hasPrefix("-")
        let selector = reverse || listRule.hasPrefix("+") ? String(listRule.dropFirst()) : listRule
        let engine = SourceRuleEngine()
        let base = try baseURL(source)
        let titleRule = rules["chapterName"]?.text?.sourceNonempty
        var pending = try initialQueue(tocURL, base: base)
        var seenPages = Set(pending)
        var seenChapters = Set<String>()
        var chapters: [RemoteChapter] = []
        var pageIndex = 0
        while pageIndex < pending.count {
            try Task.checkCancellation()
            let response = try await fetch(pending[pageIndex], source: source)
            pageIndex += 1
            let root = SourceRuleEngine.root(response.text)
            let pageBase = resolveBase(root, response: response.url)
            let items = try engine.list(selector, from: root)
            for item in items {
                let title = titleRule == nil ? item.string.sourceNonempty : try engine.text(titleRule, from: item)
                guard let title else { continue }
                let volumeValue = try engine.text(rules["isVolume"]?.text, from: item)?.lowercased()
                let volume = ["1", "true", "yes"].contains(volumeValue ?? "")
                let link = try urlValue(rules["chapterUrl"]?.text, from: item, engine: engine)
                let url = SourceRequest.absolute(link, relativeTo: pageBase)
                    ?? (volume ? response.url.absoluteString + "#volume-\(chapters.count)" : nil)
                guard let url else { continue }
                let chapter = RemoteChapter(title: title, url: url, isVolume: volume)
                let identity = volume ? chapter.id : url
                if seenChapters.insert(identity).inserted { chapters.append(chapter) }
            }
            let pages = try engine.texts(rules["nextTocUrl"]?.text, from: root)
            try enqueue(pages, relativeTo: pageBase, maxPages: 80, pending: &pending, seen: &seenPages)
        }
        guard chapters.contains(where: { !$0.isVolume }) else { throw SourceError.emptyResult("可读章节") }
        return reverse ? Array(chapters.reversed()) : chapters
    }

    public func content(source: BookSource, chapterURL: String, nextChapterURL: String? = nil) async throws -> String {
        try requireText(source)
        let rules = source.rule("ruleContent")
        guard let contentRule = rules["content"]?.text?.sourceNonempty else { throw SourceError.missingRule("正文") }
        if rules["webJs"]?.text?.sourceNonempty != nil { throw SourceError.unsupportedRule("网页正文脚本") }
        let base = try baseURL(source)
        let engine = SourceRuleEngine()
        var pending = try initialQueue(chapterURL, base: base)
        var seen = Set(pending)
        if let nextChapter = SourceRequest.absolute(nextChapterURL, relativeTo: base) { seen.insert(nextChapter) }
        var sections: [String] = []
        var seenSections = Set<String>()
        var pageIndex = 0
        while pageIndex < pending.count {
            try Task.checkCancellation()
            let response = try await fetch(pending[pageIndex], source: source)
            pageIndex += 1
            let root = SourceRuleEngine.root(response.text)
            let pageBase = resolveBase(root, response: response.url)
            if let text = try engine.text(contentRule, from: root, paragraphs: true) {
                var result = SourceHTML.plainText(text)
                if let replace = rules["replaceRegex"]?.text?.sourceNonempty {
                    if replace.hasPrefix("##") {
                        result = try engine.text(replace, from: .text(result)) ?? ""
                    } else {
                        let parts = replace.components(separatedBy: "##")
                        result = SourceRuleEngine.replace(in: result, pattern: parts[0], replacement: parts.count > 1 ? parts[1] : "")
                    }
                }
                if let result = result.sourceNonempty, seenSections.insert(result).inserted { sections.append(result) }
            }
            if let subContent = try engine.text(rules["subContent"]?.text, from: root, paragraphs: true),
               let plain = SourceHTML.plainText(subContent).sourceNonempty,
               seenSections.insert(plain).inserted {
                sections.append(plain)
            }
            let pages = try engine.texts(rules["nextContentUrl"]?.text, from: root)
            try enqueue(pages, relativeTo: pageBase, maxPages: 24, pending: &pending, seen: &seen)
        }
        guard !sections.isEmpty else { throw SourceError.emptyResult("正文") }
        return sections.joined(separator: "\n\n")
    }

    private func requireText(_ source: BookSource) throws {
        guard source.bookSourceType == 0 else { throw SourceError.unsupportedRule("非文本书源") }
    }

    private func baseURL(_ source: BookSource) throws -> URL {
        guard let url = URL(string: source.bookSourceUrl), url.isSourceHTTP else {
            throw SourceError.invalidURL(source.bookSourceUrl)
        }
        return url
    }

    private func initialQueue(_ target: String, base: URL) throws -> [String] {
        guard let target = SourceRequest.absolute(target, relativeTo: base) else { throw SourceError.invalidURL(target) }
        return [target]
    }

    private func enqueue(
        _ raw: [String],
        relativeTo base: URL,
        maxPages: Int,
        pending: inout [String],
        seen: inout Set<String>
    ) throws {
        for value in raw {
            guard !value.hasPrefix("#"), let target = SourceRequest.absolute(value, relativeTo: base),
                  seen.insert(target).inserted else { continue }
            guard pending.count < maxPages else { throw SourceError.tooManyPages }
            pending.append(target)
        }
    }

    private func parseCategory(_ line: String) -> SourceExploreCategory? {
        guard let line = line.sourceNonempty else { return nil }
        let parts = splitSourceRule(line, on: "::", limit: 2)
        if parts.count == 2, let name = parts[0].sourceNonempty, let url = parts[1].sourceNonempty {
            return SourceExploreCategory(title: name, url: url)
        }
        if line.hasPrefix("/") || line.hasPrefix("https://") || line.hasPrefix("http://") {
            return SourceExploreCategory(title: "浏览", url: line)
        }
        return nil
    }

    private func resolveBase(_ root: SourceRuleValue, response: URL) -> URL {
        guard case .node(let document) = root, let href = document.descendants.first(where: { $0.tag == "base" })?.attributes["href"],
              let base = URL(string: href, relativeTo: response)?.absoluteURL, base.isSourceHTTP else { return response }
        return base
    }

    private func urlValue(_ rule: String?, from root: SourceRuleValue, engine: SourceRuleEngine) throws -> String? {
        let url = try engine.texts(rule, from: root).first
        if let url { return url }
        if rule?.sourceNonempty == nil, case .node(let node) = root {
            return node.attributes["href"] ?? node.descendants.first(where: { $0.tag == "a" })?.attributes["href"]
        }
        return nil
    }

    private func extractList(
        source: BookSource,
        rules: [String: SourceJSON],
        page: Page
    ) throws -> [SourceSearchResult] {
        guard let list = rules["bookList"]?.text?.sourceNonempty else { throw SourceError.missingRule("书籍列表") }
        let engine = SourceRuleEngine()
        let root = SourceRuleEngine.root(page.text)
        let base = resolveBase(root, response: page.url)
        let reverse = list.hasPrefix("-")
        let selector = reverse || list.hasPrefix("+") ? String(list.dropFirst()) : list
        let items = try engine.list(selector, from: root)
        let nameRule = rules["name"]?.text?.sourceNonempty
        var seen = Set<String>()
        var results: [SourceSearchResult] = []
        for item in items {
            let name = nameRule == nil ? item.string.sourceNonempty : try engine.text(nameRule, from: item)
            guard let name,
                  let rawURL = try urlValue(rules["bookUrl"]?.text, from: item, engine: engine),
                  let url = SourceRequest.absolute(rawURL, relativeTo: base),
                  seen.insert(url).inserted else { continue }
            let author = optionalText(rules["author"]?.text, from: item, engine: engine) ?? ""
            let cover = SourceRequest.absolute(try? urlValue(rules["coverUrl"]?.text ?? "src", from: item, engine: engine), relativeTo: base)
            let intro = optionalText(rules["intro"]?.text, from: item, engine: engine).map(SourceHTML.plainText)
            results.append(SourceSearchResult(sourceID: source.id, bookURL: url, name: name, author: author,
                                              coverURL: cover.map { SourceRequest.split($0).address }, intro: intro))
        }
        return reverse ? Array(results.reversed()) : results
    }

    private func extractDetails(source: BookSource, bookURL: String, page: Page) throws -> SourceBookDetail {
        let rules = source.rule("ruleBookInfo")
        let engine = SourceRuleEngine()
        let root = SourceRuleEngine.root(page.text)
        let base = resolveBase(root, response: page.url)
        let item: SourceRuleValue
        if let selection = rules["init"]?.text?.sourceNonempty {
            item = try engine.list(selection, from: root).first ?? root
        } else {
            item = root
        }
        let name = optionalText(rules["name"]?.text, from: item, engine: engine)
            ?? optionalText("@CSS:meta[property='og:title']@content", from: root, engine: engine)
            ?? ""
        let author = optionalText(rules["author"]?.text, from: item, engine: engine)
            ?? optionalText("@CSS:meta[name='author']@content", from: root, engine: engine)
            ?? ""
        let customCover = try? urlValue(rules["coverUrl"]?.text ?? "src", from: item, engine: engine)
        let defaultCover = optionalText("@CSS:meta[property='og:image']@content", from: root, engine: engine)
        let cover = SourceRequest.absolute(customCover ?? defaultCover, relativeTo: base)
        let intro = optionalText(rules["intro"]?.text, from: item, engine: engine)
            ?? optionalText("@CSS:meta[name='description']@content", from: root, engine: engine)
        let resolvedBookURL = SourceRequest.absolute(bookURL, relativeTo: try baseURL(source)) ?? page.url.absoluteString
        let tocRule = rules["tocUrl"]?.text?.sourceNonempty
        let toc = try tocRule.flatMap { try urlValue($0, from: item, engine: engine) }
        let fallback = SourceRequest.split(resolvedBookURL).options == nil ? page.url.absoluteString : resolvedBookURL
        let tocURL = SourceRequest.absolute(toc, relativeTo: base) ?? fallback
        return SourceBookDetail(sourceID: source.id, bookURL: resolvedBookURL, tocURL: tocURL, name: name, author: author,
                                coverURL: cover.map { SourceRequest.split($0).address }, intro: intro.map(SourceHTML.plainText))
    }

    private func optionalText(_ rule: String?, from item: SourceRuleValue, engine: SourceRuleEngine) -> String? {
        try? engine.text(rule, from: item)
    }

    private struct Page {
        let url: URL
        let text: String
    }

    private func fetch(
        _ expression: String,
        source: BookSource,
        key: String = "",
        page: Int = 1
    ) async throws -> Page {
        let prepared = try SourceRequest(expression, base: try baseURL(source), source: source, key: key, page: page)
        for attempt in 0...prepared.retryCount {
            do {
                let (data, response) = try await session.data(for: prepared.request)
                guard let http = response as? HTTPURLResponse,
                      let url = http.url, url.isSourceHTTP else { throw SourceError.badResponse }
                guard (200...299).contains(http.statusCode) else { throw SourceError.httpStatus(http.statusCode) }
                guard data.count <= 12 * 1024 * 1024 else { throw SourceError.unsupportedRule("超过 12 MB 的网页响应") }
                let text = try SourceEncoding.text(data, declared: http.textEncodingName, preferred: prepared.responseCharset)
                return Page(url: url, text: text)
            } catch {
                if attempt == prepared.retryCount || !isRetryable(error) { throw error }
                try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        throw SourceError.badResponse
    }

    private func isRetryable(_ error: Error) -> Bool {
        if case SourceError.httpStatus(let status) = error { return (500...599).contains(status) }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code)
    }
}
