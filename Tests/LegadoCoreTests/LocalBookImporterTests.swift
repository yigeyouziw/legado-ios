import Foundation
import XCTest
@testable import LegadoCore

final class LocalBookImporterTests: XCTestCase {
    func testUTF16TextSplitsChineseChapterHeadingsAndKeepsIntroduction() throws {
        let text = "作者的话。\r\n\r\n第一章 风起\r\n第一段。\r\n\r\n第二段。\r\n第二章 雨来\r\n正文。"
        let data = try XCTUnwrap(text.data(using: .utf16))
        let book = try LocalBookImporter.importBook(data: data, filename: "测试.TXT")
        XCTAssertEqual(book.title, "测试")
        XCTAssertEqual(book.chapters, [
            LocalChapter(title: "正文", text: "作者的话。"),
            LocalChapter(title: "第一章 风起", text: "第一段。\n\n第二段。"),
            LocalChapter(title: "第二章 雨来", text: "正文。")
        ])
    }

    func testLongUnsectionedTextSplitsWithoutLosingCharacters() throws {
        let source = String(repeating: "春", count: 39_000)
        let book = try LocalBookImporter.importBook(data: Data(source.utf8), filename: "spring.txt")
        XCTAssertEqual(book.chapters.count, 3)
        XCTAssertEqual(book.chapters.map(\.text).joined(), source)
    }

    func testLargeNamedChapterSplitsAtParagraphsWithoutLosingWhitespace() throws {
        let paragraph = String(repeating: "😀", count: 12_000)
        let source = "\(paragraph)\n\n\(paragraph)"
        let data = Data("第一章 山路\n\(source)".utf8)
        let book = try LocalBookImporter.importBook(data: data, filename: "Long.txt")
        XCTAssertEqual(book.chapters.map(\.title), ["第一章 山路", "第一章 山路（续 2）"])
        XCTAssertEqual(book.chapters.map(\.text).joined(), source)
        XCTAssertTrue(book.chapters[0].text.hasSuffix("\n\n"))
    }

    func testGB18030TextSupportsRareChineseCharacters() throws {
        let data = try XCTUnwrap(Data(base64Encoded: "tdrSu9XCILfnxvAK1f3OxJUygjahow=="))
        let book = try LocalBookImporter.importBook(data: data, filename: "GB18030.txt")
        XCTAssertEqual(book.chapters, [LocalChapter(title: "第一章 风起", text: "正文𠀀。")])
    }

    func testEPUBThreeReadsSpineMetadataCoverAndFragmentChapters() throws {
        let archive = makeZIP([
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(container.utf8)),
            ("OPS/package.opf", Data("""
                <package xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
                  <metadata><dc:title id="subtitle">副题</dc:title><dc:title id="title">故事</dc:title>
                    <meta refines="#title" property="title-type">main</meta><dc:creator>作者</dc:creator></metadata>
                  <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                    <item id="one" href="chapters/one%20two.xhtml" media-type="application/xhtml+xml"/>
                    <item id="three" href="chapters/three.xhtml" media-type="application/xhtml+xml"/>
                    <item id="cover" href="images/cover.png" media-type="image/png" properties="cover-image"/></manifest>
                  <spine><itemref idref="one"/><itemref idref="nav" linear="no"/><itemref idref="three"/></spine>
                </package>
                """.utf8)),
            ("OPS/nav.xhtml", Data("""
                <html xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol>
                  <li><a href="chapters/one%20two.xhtml#one">一</a></li>
                  <li><a href="chapters/one%20two.xhtml#two">二</a></li><li><a href="chapters/three.xhtml">三</a></li>
                </ol></nav></body></html>
                """.utf8)),
            ("OPS/chapters/one two.xhtml", Data("""
                <html><head><title>隐藏标题</title></head><body>
                <h1 id="one">一</h1><p>苹果&nbsp;和梨。<br/>下一行。</p>
                <h1 id="two">二</h1><p>月亮。</p><script>hidden text</script></body></html>
                """.utf8)),
            ("OPS/chapters/three.xhtml", Data("<html><body><h1>三</h1><p>第三章。</p></body></html>".utf8)),
            ("OPS/images/cover.png", Data([137, 80, 78, 71]))
        ])
        let book = try LocalBookImporter.importBook(data: archive, filename: "ignored.epub")
        XCTAssertEqual(book.title, "故事")
        XCTAssertEqual(book.author, "作者")
        XCTAssertEqual(book.cover, Data([137, 80, 78, 71]))
        XCTAssertEqual(book.chapters, [
            LocalChapter(title: "一", text: "苹果 和梨。\n下一行。"),
            LocalChapter(title: "二", text: "月亮。"),
            LocalChapter(title: "三", text: "第三章。")
        ])
    }

    func testEPUBTwoReadsNCXAndSkipsUnwantedAuxiliaryFiles() throws {
        let archive = makeZIP([
            ("META-INF/container.xml", Data(container.utf8)),
            ("OPS/package.opf", Data("""
                <package version="2.0"><manifest>
                  <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                  <item id="story" href="story.xhtml" media-type="application/xhtml+xml"/>
                  <item id="note" href="note.xhtml" media-type="application/xhtml+xml"/>
                </manifest><spine toc="ncx"><itemref idref="story"/><itemref idref="note" linear="no"/></spine></package>
                """.utf8)),
            ("OPS/toc.ncx", Data("""
                <ncx><navMap><navPoint><navLabel><text>Named in NCX</text></navLabel>
                  <content src="story.xhtml"/></navPoint></navMap></ncx>
                """.utf8)),
            ("OPS/story.xhtml", Data("<html><body><p>Content.</p></body></html>".utf8)),
            ("OPS/note.xhtml", Data("<html><body><p>Auxiliary only.</p></body></html>".utf8))
        ])
        let book = try LocalBookImporter.importBook(data: archive, filename: "Fallback.epub")
        XCTAssertEqual(book.title, "Fallback")
        XCTAssertEqual(book.chapters, [LocalChapter(title: "Named in NCX", text: "Content.")])
    }

    func testDeflateReadsAllBlockTypesAndRejectsUnexpectedSize() throws {
        let fixtures = [
            ("y0jNyclXyECQAA==", "hello hello hello"),
            ("7c3BCcIwFAbgVf4J3MFRYvKggfAiyTPYW9GbBxcQQfDYHj0UOo7ROIZT9Pa+Bb42TXUe2vjA937+XG51vv5ez7os7+G0RfK2Cz2EjnJI5MCxUMAuELuMYpInB9uZvVACFWLJMOxgIxdK2YiPnDdoeuihhx566KHHuObxBw==",
             String(repeating: "第一章 权力与责任。A richly textured novel blends varied chapter events and conversations. ", count: 20)),
            ("AQkA9v9yYXcgYnl0ZXM=", "raw bytes")
        ]
        for (base64, result) in fixtures {
            let compressed = Array(try XCTUnwrap(Data(base64Encoded: base64)))
            let block = (compressed[0] >> 1) & 3
            XCTAssertEqual(try EPUBDeflate.decode(compressed[...], expectedSize: result.utf8.count), Array(result.utf8), "block \(block)")
            XCTAssertThrowsError(try EPUBDeflate.decode(compressed[...], expectedSize: result.utf8.count - 1))
        }
    }

    func testArchiveRejectsCorruptContents() throws {
        var archive = makeZIP([("file", Data("abc".utf8))])
        archive[34] = 100
        let parsed = try EPUBArchive(data: archive)
        XCTAssertThrowsError(try parsed.data(at: "file")) { error in
            XCTAssertEqual(error as? LocalBookImportError, .invalidEPUB)
        }
    }

    func testArchiveReadsDeflatedResources() throws {
        let source = Data("hello hello hello".utf8)
        let compressed = try XCTUnwrap(Data(base64Encoded: "y0jNyclXyECQAA=="))
        let archive = try EPUBArchive(data: makeZIP([("content", source)], compressed: ["content": compressed]))
        XCTAssertEqual(try archive.data(at: "content"), source)
    }

    private let container = """
        <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
        <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """

    private func makeZIP(_ resources: [(String, Data)], compressed: [String: Data] = [:]) -> Data {
        var archive = Data()
        var directory = Data()
        for (path, data) in resources {
            let name = Data(path.utf8)
            let crc = checksum(data)
            let body = compressed[path] ?? data
            let method = compressed[path] == nil ? 0 : 8
            let localHeader = archive.count
            archive += le32(0x0403_4b50) + le16(20) + le16(0) + le16(method) + le32(0)
            archive += le32(crc) + le32(body.count) + le32(data.count) + le16(name.count) + le16(0)
            archive += name + body

            directory += le32(0x0201_4b50) + le16(20) + le16(20) + le16(0) + le16(method) + le32(0)
            directory += le32(crc) + le32(body.count) + le32(data.count) + le16(name.count)
            directory += Data(repeating: 0, count: 12) + le32(localHeader) + name
        }
        let offset = archive.count
        archive += directory + le32(0x0605_4b50) + le16(0) + le16(0) + le16(resources.count) + le16(resources.count)
        archive += le32(directory.count) + le32(offset) + le16(0)
        return archive
    }

    private func le16(_ value: Int) -> Data {
        Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
    }

    private func le32(_ value: Int) -> Data {
        le16(value) + le16(value >> 16)
    }

    private func checksum(_ data: Data) -> Int {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb8_8320) }
        }
        return Int(crc ^ UInt32.max)
    }
}
