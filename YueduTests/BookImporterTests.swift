import XCTest
import CoreFoundation
import zlib
@testable import Yuedu

final class BookImporterTests: XCTestCase {
    func testUTF8BOMAndChineseChapterHeadings() throws {
        let text = "序言\r\n\r\n第一章 春日\r\n春风又绿江南岸。\r\n第二章 秋夜\r\n明月何时照我还。"
        let book = try BookImporter.parseTXT(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8), title: "江南")
        XCTAssertEqual(book.title, "江南")
        XCTAssertEqual(book.chapters.map(\.title), ["前言", "第一章 春日", "第二章 秋夜"])
        XCTAssertEqual(book.chapters[1].content, "春风又绿江南岸。")
        XCTAssertFalse(book.isSample)
    }

    func testUTF16AndGB18030() throws {
        let text = "第一章 山水\n山川与湖泊。"
        for (bom, encoding) in [([UInt8](arrayLiteral: 0xFF, 0xFE), String.Encoding.utf16LittleEndian), ([UInt8](arrayLiteral: 0xFE, 0xFF), String.Encoding.utf16BigEndian)] {
            let data = try XCTUnwrap(text.data(using: encoding))
            XCTAssertEqual(try BookImporter.parseTXT(Data(bom) + data, title: "测试").chapters.first?.content, "山川与湖泊。")
        }
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let gbData = try XCTUnwrap(text.data(using: encoding))
        XCTAssertEqual(try BookImporter.parseTXT(gbData, title: "测试").chapters.first?.content, "山川与湖泊。")
    }

    func testLargeUnchapteredTextIsSplitWithoutLosingContent() throws {
        let text = String(repeating: "读书📚山川", count: 6_000)
        let book = try BookImporter.parseTXT(Data(text.utf8), title: "长文")
        XCTAssertGreaterThan(book.chapters.count, 1)
        XCTAssertEqual(book.chapters.map(\.content).joined(), text)
        XCTAssertTrue(book.chapters.allSatisfy { $0.content.count <= 12_000 })
    }

    func testBinaryAndEmptyTXTRejected() {
        XCTAssertThrowsError(try BookImporter.parseTXT(Data([0, 1, 2, 3, 4]), title: "二进制"))
        XCTAssertThrowsError(try BookImporter.parseTXT(Data(" \n\t ".utf8), title: "空文"))
        XCTAssertThrowsError(try BookImporter.parseTXT(Data("第一章 空\n第二章 空".utf8), title: "空文"))
    }

    func testEPUBDeflateMetadataSpineOrderAndParagraphs() throws {
        let data = try makeEPUB()
        let book = try EPUBReader.read(data, fallbackTitle: "备用")
        XCTAssertEqual(book.title, "测试山河")
        XCTAssertEqual(book.author, "测试作者")
        XCTAssertEqual(book.chapters.map(\.title), ["第一章 山", "第二章 河"])
        XCTAssertEqual(book.chapters[0].content, "青山不改。\n\n白云悠悠。")
        XCTAssertEqual(book.chapters[1].content, "流水向东。")
        XCTAssertFalse(book.chapters[0].content.contains("hidden"))
    }

    func testEPUBChapterEncryptionRejected() throws {
        let data = try makeEPUB(extra: [("META-INF/encryption.xml", "<encryption><EncryptedData><CipherData><CipherReference URI=\"OPS/one.xhtml\"/></CipherData></EncryptedData></encryption>")])
        XCTAssertThrowsError(try EPUBReader.read(data, fallbackTitle: "加密")) { error in
            guard case BookImportError.encryptedEPUB = error else { return XCTFail("Expected an explicit DRM error: \(error)") }
        }
    }

    func testEPUBFontObfuscationDoesNotBlockPlaintext() throws {
        let data = try makeEPUB(extra: [("META-INF/encryption.xml", "<encryption><EncryptedData><CipherData><CipherReference URI=\"OPS/font.otf\"/></CipherData></EncryptedData></encryption>")])
        XCTAssertEqual(try EPUBReader.read(data, fallbackTitle: "测试").chapters.count, 2)
    }

    func testInvalidAndTruncatedArchiveRejected() throws {
        let data = try makeEPUB()
        for prefixCount in [0, 4, 21, 22, data.count / 2, data.count - 1] {
            XCTAssertThrowsError(try EPUBArchive(data: data.prefix(prefixCount)))
        }
        var damaged = data
        // The first stored resource begins after its local header and filename.
        damaged[30 + "mimetype".utf8.count] ^= 0x01
        let archive = try EPUBArchive(data: damaged)
        XCTAssertThrowsError(try archive.read("mimetype"))
    }

    func testTraversalAndForgedExpandedSizeRejected() throws {
        let traversal = try makeZIP([(path: "../outside.txt", data: Data("x".utf8), compress: false)])
        XCTAssertThrowsError(try EPUBArchive(data: traversal))
        XCTAssertThrowsError(try EPUBArchive.resolve("../../outside.xhtml", relativeTo: "OPS/book.opf"))
        XCTAssertThrowsError(try EPUBArchive.resolve("https://example.org/book.xhtml", relativeTo: "OPS/book.opf"))
        XCTAssertEqual(try EPUBArchive.resolve("../Text/a%20b.xhtml#chapter", relativeTo: "OPS/Package/book.opf"), "OPS/Text/a b.xhtml")

        var forged = try makeZIP([(path: "large.txt", data: Data("tiny".utf8), compress: false)])
        let central = try XCTUnwrap(findSignature([0x50, 0x4B, 0x01, 0x02], in: forged))
        forged.replaceSubrange((central + 24)..<(central + 28), with: [0x00, 0x00, 0x00, 0x40])
        XCTAssertThrowsError(try EPUBArchive(data: forged))
    }

    func testSamplesAreHonestOfflineExcerpts() {
        let books = SampleLibrary.books
        XCTAssertEqual(books.count, 6)
        XCTAssertTrue(books.allSatisfy { $0.isSample && $0.sourceName == "内置节选" && $0.chapters.count >= 2 })
        XCTAssertTrue(books.flatMap(\.chapters).allSatisfy { !$0.content.isEmpty && $0.url == nil })
    }

    func testInternalXMLEntitiesAreRejected() throws {
        let archive = try makeZIP([
            (path: "META-INF/container.xml", data: Data("<!DOCTYPE container [<!ENTITY payload 'expanded'>]><container>&payload;</container>".utf8), compress: false)
        ])
        XCTAssertThrowsError(try EPUBReader.read(archive, fallbackTitle: "实体声明"))
    }

    private func makeEPUB(extra: [(String, String)] = []) throws -> Data {
        let container = "<container><rootfiles><rootfile full-path=\"OPS/book.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"
        let package = """
        <package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>测试山河</dc:title><dc:creator>测试作者</dc:creator></metadata><manifest><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>
        """
        let files = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", container),
            ("OPS/book.opf", package),
            ("OPS/two.xhtml", "<html><body><h1>第二章 河</h1><p>流水向东。</p></body></html>"),
            ("OPS/one.xhtml", "<html><head><title>hidden</title><style>hidden</style></head><body><h1>第一章 <span>山</span></h1><p>青山不改。</p><p>白云悠悠。</p><script>hidden</script></body></html>")
        ] + extra
        return try makeZIP(files.map { (path: $0.0, data: Data($0.1.utf8), compress: $0.0 != "mimetype") })
    }

    private func makeZIP(_ files: [(path: String, data: Data, compress: Bool)]) throws -> Data {
        var result = Data()
        var directory = Data()
        for file in files {
            let name = Data(file.path.utf8)
            let compressed = try file.compress ? rawDeflate(file.data) : file.data
            let checksum = file.data.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            let method: UInt16 = file.compress ? 8 : 0
            let offset = result.count
            result.appendLE(UInt32(0x04034B50)); result.appendLE(UInt16(20)); result.appendLE(UInt16(0x0800)); result.appendLE(method)
            result.appendLE(UInt16(0)); result.appendLE(UInt16(0)); result.appendLE(UInt32(checksum))
            result.appendLE(UInt32(compressed.count)); result.appendLE(UInt32(file.data.count)); result.appendLE(UInt16(name.count)); result.appendLE(UInt16(0))
            result.append(name); result.append(compressed)
            directory.appendLE(UInt32(0x02014B50)); directory.appendLE(UInt16(20)); directory.appendLE(UInt16(20)); directory.appendLE(UInt16(0x0800)); directory.appendLE(method)
            directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0)); directory.appendLE(UInt32(checksum)); directory.appendLE(UInt32(compressed.count)); directory.appendLE(UInt32(file.data.count))
            directory.appendLE(UInt16(name.count)); directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0)); directory.appendLE(UInt32(0)); directory.appendLE(UInt32(offset)); directory.append(name)
        }
        let directoryOffset = result.count
        result.append(directory)
        result.appendLE(UInt32(0x06054B50)); result.appendLE(UInt16(0)); result.appendLE(UInt16(0)); result.appendLE(UInt16(files.count)); result.appendLE(UInt16(files.count))
        result.appendLE(UInt32(directory.count)); result.appendLE(UInt32(directoryOffset)); result.appendLE(UInt16(0))
        return result
    }

    private func rawDeflate(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw BookImportError.invalidArchive("test compression failed") }
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: Int(compressBound(uLong(data.count))))
        let status = data.withUnsafeBytes { input in output.withUnsafeMutableBytes { buffer in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(buffer.count)
            return deflate(&stream, Z_FINISH)
        } }
        guard status == Z_STREAM_END else { throw BookImportError.invalidArchive("test compression failed") }
        return Data(output.prefix(Int(stream.total_out)))
    }

    private func findSignature(_ signature: [UInt8], in data: Data) -> Int? {
        let bytes = [UInt8](data)
        return (0...(bytes.count - signature.count)).first { Array(bytes[$0..<($0 + signature.count)]) == signature }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
