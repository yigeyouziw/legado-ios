import Foundation
import XCTest
@testable import LegadoCore

final class SyndicationTests: XCTestCase {
    func testRSSParsesLinksAndSummariesAndDeduplicatesGuid() throws {
        let rss = """
            <?xml version="1.0"?>
            <rss version="2.0"><channel><title>News &amp; reads</title><item>
              <title>First article</title><description><![CDATA[<p>A &amp; B</p><script>invisible()</script><p>Second line.</p>]]></description>
              <link>/articles/one</link><guid isPermaLink="false">item-1</guid>
              <pubDate>Mon, 09 Nov 2026 17:00:00 GMT</pubDate>
            </item><item><title>Duplicate</title><guid>item-1</guid></item>
            <item><title>Article 2</title><link>javascript:alert(1)</link><guid isPermaLink="false">002</guid></item></channel></rss>
            """
        let feed = try parse(rss)
        XCTAssertEqual(feed.title, "News & reads")
        XCTAssertEqual(feed.articles.map(\.id), ["item-1", "002"])
        XCTAssertEqual(feed.articles[0].summary, "A & B\n\nSecond line.")
        XCTAssertEqual(feed.articles[0].url?.absoluteString, "https://example.org/articles/one")
        XCTAssertEqual(feed.articles[0].date, ISO8601DateFormatter().date(from: "2026-11-09T17:00:00Z"))
        XCTAssertNil(feed.articles[1].url)
    }

    func testAtomUsesAlternateLinkAndAppliesXMLBase() throws {
        let atom = """
            <feed xmlns="http://www.w3.org/2005/Atom" xml:base="https://site.example/base/">
              <title>Entries</title><entry xml:base="section/">
                <id>urn:entry:1</id><title type="html">&lt;i&gt;Example&lt;/i&gt;</title>
                <link rel="self" href="entry.xml"/><link href="entry.html"/>
                <summary type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>First.</p><p>Second.</p></div></summary>
                <published>2026-11-14T00:04:00.151Z</published><updated>2026-11-15T13:14:00Z</updated>
              </entry>
            </feed>
            """
        let feed = try parse(atom)
        let article = try XCTUnwrap(feed.articles.first)
        XCTAssertEqual(article.id, "urn:entry:1")
        XCTAssertEqual(article.title, "Example")
        XCTAssertEqual(article.summary, "First.\n\nSecond.")
        XCTAssertEqual(article.url?.absoluteString, "https://site.example/base/section/entry.html")
        XCTAssertEqual(article.date?.timeIntervalSince1970 ?? 0, 1_794_614_640.151, accuracy: 0.001)
    }

    func testRejectsNonFeedAndNonWebURLs() throws {
        XCTAssertThrowsError(try parse("<html><title>Website</title></html>")) { error in
            XCTAssertEqual(error as? SyndicationError, .invalidFeed)
        }
        XCTAssertNil(SyndicationReader.webURL("file:///tmp/feed.xml"))
        XCTAssertNil(SyndicationReader.webURL("https://user:password@example.org/feed"))
    }

    private func parse(_ xml: String) throws -> SyndicationFeed {
        let base = try XCTUnwrap(URL(string: "https://example.org/feed.xml"))
        return try SyndicationReader.parse(Data(xml.utf8), baseURL: base)
    }
}
