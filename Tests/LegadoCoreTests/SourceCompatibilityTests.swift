import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LegadoCore

struct SourceCompatibilityTests {
    @Test func importPreservesUnknownFieldsAndReadsStringRules() throws {
        let input = Data(#"{"bookSourceUrl":"https://example.test","bookSourceName":"测试源","enabled":0,"ruleSearch":"{\"bookList\":\"@CSS:.book\"}","unrecognized":{"number":42,"items":[true,"text"]}}"#.utf8)
        var source = try #require(BookSource.decodeImport(input).first)
        #expect(!source.enabled)
        #expect(source.rule("ruleSearch")["bookList"]?.text == "@CSS:.book")
        source.enabled = true
        let output = try JSONDecoder().decode(SourceJSON.self, from: JSONEncoder().encode(source))
        #expect(output.fields?["unrecognized"]?.fields?["number"] == .integer(42))
        #expect(output.fields?["enabled"] == .bool(true))
        #expect(throws: SourceError.self) { try BookSource.decodeImport(Data("[]".utf8)) }
    }

    @Test func selectsMalformedHTMLAndReadsJSONPaths() throws {
        let engine = SourceRuleEngine()
        let html = SourceRuleEngine.root("<ul><li class='pick'><a href='/p/1'>A &amp; B</a><li><a href='/p/2'>2</a></ul>")
        #expect(try engine.text("@CSS:ul > li:nth-child(2) a@href", from: html) == "/p/2")
        #expect(try engine.text("//li[@class='pick']/a/text()", from: html) == "A & B")
        #expect(try engine.text("tag.li.-1@tag.a@text", from: html) == "2")
        #expect(try engine.text("@CSS:.missing@text||@CSS:.pick@text", from: html) == "A & B")
        let json = SourceRuleEngine.root(#"{"catalog":{"books":[{"name":"甲","rank":1},{"name":"乙","rank":4}]}}"#)
        #expect(try engine.text("$.catalog.books[?(@.rank>=2)].name", from: json) == "乙")
        #expect(try engine.text("$..name", from: json) == "甲\n乙")
        #expect(try engine.text("$.catalog.books[-1].name", from: json) == "乙")
    }

    @Test func buildsRequestsWithOptionsChoicesAndEncoding() throws {
        let source = BookSource(bookSourceUrl: "https://books.example.test", bookSourceName: "示例")
        let request = try SourceRequest(
            #"/search/<main,more>?offset={{(page-1)*20}},{"method":"POST","body":"q={{key}}&page={{page}}","headers":{"X-Source":"fixture"}}"#,
            base: URL(string: source.bookSourceUrl), source: source, key: "你好 &", page: 3
        )
        #expect(request.url.absoluteString == "https://books.example.test/search/more?offset=40")
        #expect(request.request.httpMethod == "POST")
        #expect(request.request.value(forHTTPHeaderField: "X-Source") == "fixture")
        let body = try #require(request.request.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == "q=%E4%BD%A0%E5%A5%BD+%26&page=3")
        #expect(SourceClient.supportsPagination("/search?q={{key}}&p={{page}}"))
        #expect(!SourceClient.supportsPagination("/page?q={{key}}&page=1"))
    }

    @Test func readsAndEncodesLegacyChineseText() throws {
        let data = Data([0xD6, 0xD0, 0xCE, 0xC4])
        #expect(try SourceEncoding.text(data, declared: "GB2312", preferred: nil) == "中文")
        #expect(try SourceEncoding.data("中文", charset: "GBK") == data)
    }

    @Test func followsSearchDetailsCatalogAndChapterPagination() async throws {
        let source = try #require(BookSource.decodeImport(Data(Self.fixtureDefinition.utf8)).first)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BookFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = SourceClient(session: session)

        let result = try #require(try await client.search(source: source, keyword: "测试").first)
        #expect(result.name == "样书")
        #expect(result.author == "作者甲")
        #expect(result.coverURL == "https://books.example.test/covers/a.png")
        let detail = try await client.detail(source: source, bookURL: result.bookURL)
        #expect(detail.name == "样书")
        #expect(detail.tocURL == "https://books.example.test/toc")
        let chapters = try await client.chapters(source: source, tocURL: detail.tocURL)
        #expect(chapters.map(\.title) == ["第一章", "第二章"])
        let first = try #require(chapters.first)
        let content = try await client.content(source: source, chapterURL: first.url, nextChapterURL: chapters.last?.url)
        #expect(content == "首段\n第二行\n\n补页")
        let category = try #require(client.exploreCategories(source: source).first)
        #expect(category.title == "新书")
        let discovered = try #require(try await client.explore(source: source, category: category, page: 2).first)
        #expect(discovered.name == "发现样书")
    }

    private static let fixtureDefinition = #"""
    {
      "bookSourceUrl": "https://books.example.test",
      "bookSourceName": "示例",
      "searchUrl": "/search?q={{key}}",
      "exploreUrl": "新书::/explore?p={{page}}",
      "ruleSearch": {"bookList": "@CSS:.entry", "name": "@CSS:h2@text", "author": "@CSS:.by@text", "bookUrl": "@CSS:a@href", "coverUrl": "@CSS:img@src"},
      "ruleExplore": {"bookList": "$.items[*]", "name": "name", "bookUrl": "url"},
      "ruleBookInfo": {"name": "@CSS:h1@text", "tocUrl": "@CSS:.all@href"},
      "ruleToc": {"chapterList": "@CSS:.toc a", "chapterName": "text", "chapterUrl": "href", "nextTocUrl": "@CSS:.next@href"},
      "ruleContent": {"content": "@CSS:#story@html", "nextContentUrl": "@CSS:.next@href", "replaceRegex": "##广告##"}
    }
    """#
}

private final class BookFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "books.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let contents: String
        let type: String
        switch url.path {
        case "/search":
            contents = #"<article class="entry"><a href="/book"><h2>样书</h2></a><span class="by">作者甲</span><img src="covers/a.png"></article>"#
            type = "text/html"
        case "/book":
            contents = #"<h1>样书</h1><a class="all" href="/toc">目录</a>"#
            type = "text/html"
        case "/toc":
            contents = #"<div class="toc"><a href="/one">第一章</a></div><a class="next" href="/toc/2">下一页</a>"#
            type = "text/html"
        case "/toc/2":
            contents = #"<div class="toc"><a href="/two">第二章</a><a href="/one">重复</a></div><a class="next" href="/toc">循环</a>"#
            type = "text/html"
        case "/one":
            contents = #"<div id="story"><p>首段<br>第二行广告</p></div><a class="next" href="/one/2">下一页</a>"#
            type = "text/html"
        case "/one/2":
            contents = #"<div id="story"><p>补页</p></div><a class="next" href="/two">下一章</a>"#
            type = "text/html"
        case "/explore" where url.query == "p=2":
            contents = #"{"items":[{"name":"发现样书","url":"/book"}]}"#
            type = "application/json"
        default:
            client.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        guard let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": type + "; charset=utf-8"]
        ) else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data(contents.utf8))
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
