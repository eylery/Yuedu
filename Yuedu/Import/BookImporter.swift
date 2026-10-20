import Foundation
import CoreFoundation

enum BookImportError: LocalizedError {
    case unsupportedFormat
    case tooLarge
    case unreadableText
    case emptyBook
    case invalidArchive(String)
    case encryptedEPUB
    case invalidEPUB(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "请选择 TXT 或 EPUB 文件。"
        case .tooLarge: return "文件过大。TXT 限制为 20 MB，EPUB 限制为 50 MB，解压后的内容限制为 64 MB。"
        case .unreadableText: return "无法识别文本编码，或文件包含二进制内容。请使用 UTF-8、UTF-16 或 GB18030 编码的 TXT。"
        case .emptyBook: return "这本书没有可阅读的正文。"
        case .invalidArchive(let reason): return "EPUB 压缩包无法读取：\(reason)"
        case .encryptedEPUB: return "这本 EPUB 包含加密或 DRM 保护的内容，暂不支持导入。"
        case .invalidEPUB(let reason): return "EPUB 内容无法读取：\(reason)"
        }
    }
}

enum BookImporter {
    static func importBook(from url: URL) async throws -> Book {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let ext = url.pathExtension.lowercased()
            guard ext == "txt" || ext == "epub" else { throw BookImportError.unsupportedFormat }
            let maximumSize = ext == "txt" ? 20 * 1_024 * 1_024 : 50 * 1_024 * 1_024
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard attributes.isRegularFile == true else { throw BookImportError.unsupportedFormat }
            guard let size = attributes.fileSize, size <= maximumSize else { throw BookImportError.tooLarge }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= maximumSize else { throw BookImportError.tooLarge }
            let title = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
            return try ext == "txt" ? parseTXT(data, title: title) : EPUBReader.read(data, fallbackTitle: title)
        }.value
    }

    static func parseTXT(_ data: Data, title: String) throws -> Book {
        guard data.count <= 20 * 1_024 * 1_024 else { throw BookImportError.tooLarge }
        var decoded: String?
        if data.starts(with: [0xFF, 0xFE]) {
            decoded = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            decoded = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            decoded = String(data: data.dropFirst(3), encoding: .utf8)
        } else {
            decoded = String(data: data, encoding: .utf8)
            if decoded == nil {
                let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
                decoded = String(data: data, encoding: String.Encoding(rawValue: encoding))
            }
        }
        guard let decoded else { throw BookImportError.unreadableText }
        let controlCount = decoded.unicodeScalars.reduce(into: 0) { count, scalar in
            if scalar.value == 0 || (scalar.value < 32 && scalar.value != 9 && scalar.value != 10 && scalar.value != 13 && scalar.value != 12) { count += 1 }
        }
        guard controlCount == 0 else { throw BookImportError.unreadableText }
        let text = decoded.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BookImportError.emptyBook }
        let chapters = splitChapters(text)
        guard chapters.contains(where: { !$0.content.isEmpty }) else { throw BookImportError.emptyBook }
        return Book(title: title.isEmpty ? "未命名书籍" : title, author: "未知作者", summary: "从本地 TXT 导入，共 \(chapters.count) 章。", category: "本地书籍", coverColor: "#517A65", coverSymbol: "text.book.closed", chapters: chapters, sourceName: "本地 TXT")
    }

    private static func splitChapters(_ text: String) -> [BookChapter] {
        let pattern = #"(?m)^[\t 　]*(?:第[零〇一二三四五六七八九十百千万两0-9０-９]{1,20}[章回节卷部篇][^\n]{0,60}|Chapter[\t ]+[0-9IVXLCDMivxlcdm]{1,12}[^\n]{0,60})[\t 　]*$"#
        let expression = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let string = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: string.length))
        guard !matches.isEmpty, matches.count <= 10_000 else { return chunk(text, title: "正文") }
        var result: [BookChapter] = []
        if let first = matches.first, first.range.location > 0 {
            let preface = string.substring(to: first.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
            if !preface.isEmpty { result += chunk(preface, title: "前言") }
        }
        for (index, match) in matches.enumerated() {
            let end = index + 1 < matches.count ? matches[index + 1].range.location : string.length
            let start = NSMaxRange(match.range)
            let title = string.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            let content = string.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
            result += chunk(content, title: title)
        }
        return result
    }

    private static func chunk(_ text: String, title: String) -> [BookChapter] {
        let maximumCharacters = 12_000
        guard text.count > maximumCharacters else { return [BookChapter(title: title, content: text)] }
        var remaining = text[...]
        var chunks: [String] = []
        while !remaining.isEmpty {
            let limit = remaining.index(remaining.startIndex, offsetBy: maximumCharacters, limitedBy: remaining.endIndex) ?? remaining.endIndex
            var end = limit
            if limit != remaining.endIndex {
                let lower = remaining.index(remaining.startIndex, offsetBy: maximumCharacters / 2)
                if let newline = remaining[lower..<limit].lastIndex(of: "\n") { end = remaining.index(after: newline) }
            }
            let content = remaining[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { chunks.append(content) }
            remaining = remaining[end...]
        }
        return chunks.enumerated().map { BookChapter(title: "\(title) · \($0.offset + 1)", content: $0.element) }
    }
}
