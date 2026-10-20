import Foundation

enum EPUBReader {
    static func read(_ data: Data, fallbackTitle: String) throws -> Book {
        let archive = try EPUBArchive(data: data)
        let container = ContainerParser()
        try parseXML(archive.read("META-INF/container.xml"), delegate: container)
        guard let packageReference = container.packagePath else { throw BookImportError.invalidEPUB("没有找到内容清单") }
        let packagePath = try EPUBArchive.resolve(packageReference)
        let package = PackageParser()
        try parseXML(archive.read(packagePath), delegate: package)
        guard !package.spine.isEmpty else { throw BookImportError.invalidEPUB("阅读顺序为空") }
        guard package.spine.count <= 10_000 else { throw BookImportError.tooLarge }

        var encryptedPaths = Set<String>()
        if archive.contains("META-INF/encryption.xml") {
            let encryption = EncryptionParser()
            try parseXML(archive.read("META-INF/encryption.xml"), delegate: encryption)
            // Font obfuscation is allowed; encrypted chapter/metadata resources are not.
            for reference in encryption.references { encryptedPaths.insert(try EPUBArchive.resolve(reference)) }
            if encryptedPaths.contains(packagePath) { throw BookImportError.encryptedEPUB }
        }

        var navigationTitles: [String: String] = [:]
        if let nav = package.items.values.first(where: { $0.properties.split(separator: " ").contains("nav") }),
           let navPath = try? EPUBArchive.resolve(nav.href, relativeTo: packagePath),
           !encryptedPaths.contains(navPath), let navData = try? archive.read(navPath) {
            let navigation = NavigationParser()
            if (try? parseXML(navData, delegate: navigation)) != nil {
                for (href, title) in navigation.links {
                    if let path = try? EPUBArchive.resolve(href, relativeTo: navPath), navigationTitles[path] == nil {
                        navigationTitles[path] = title
                    }
                }
            }
        }

        var chapters: [BookChapter] = []
        var totalTextSize = 0
        for id in package.spine {
            try Task.checkCancellation()
            guard let item = package.items[id] else { throw BookImportError.invalidEPUB("阅读顺序引用了缺失的章节") }
            guard item.mediaType == "application/xhtml+xml" || item.mediaType == "text/html" else { continue }
            let path = try EPUBArchive.resolve(item.href, relativeTo: packagePath)
            guard !encryptedPaths.contains(path) else { throw BookImportError.encryptedEPUB }
            let document = XHTMLParser()
            try parseXML(archive.read(path), delegate: document, htmlEntities: true)
            var content = document.plainText
            guard !content.isEmpty else { continue }
            let title = navigationTitles[path] ?? document.heading.nilIfBlank ?? "第 \(chapters.count + 1) 章"
            if content.components(separatedBy: "\n").first == title {
                content = String(content.dropFirst(title.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            totalTextSize += content.utf8.count
            guard totalTextSize <= 64 * 1_024 * 1_024 else { throw BookImportError.tooLarge }
            if !content.isEmpty { chapters.append(BookChapter(title: title, content: content)) }
        }
        guard !chapters.isEmpty else { throw BookImportError.emptyBook }
        let summary = package.bookDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return Book(title: package.title.nilIfBlank ?? fallbackTitle, author: package.author.nilIfBlank ?? "未知作者",
                    summary: summary.nilIfBlank ?? "从本地 EPUB 导入，共 \(chapters.count) 章。", category: "本地书籍",
                    coverColor: "#596780", coverSymbol: "book.closed", chapters: chapters, sourceName: "本地 EPUB")
    }

    private static func parseXML(_ data: Data, delegate: XMLParserDelegate, htmlEntities: Bool = false) throws {
        var data = data
        // EPUB text resources use UTF-8 or UTF-16. Refuse entity declarations before XMLParser sees them.
        let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
        guard var string, string.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
            throw BookImportError.invalidEPUB("XML 编码无效或包含不支持的实体声明")
        }
        if htmlEntities {
            for (entity, character) in ["&nbsp;": "\u{00A0}", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&ldquo;": "“", "&rdquo;": "”", "&lsquo;": "‘", "&rsquo;": "’", "&copy;": "©", "&reg;": "®", "&middot;": "·", "&bull;": "•", "&ensp;": " ", "&emsp;": "　"] {
                string = string.replacingOccurrences(of: entity, with: character)
            }
        }
        // Re-encode consistently with the declaration, including UTF-16 source documents.
        string = string.replacingOccurrences(of: #"(?i)(<\?xml[^>]*encoding\s*=\s*)["'][^"']+["']"#, with: "$1\"UTF-8\"", options: .regularExpression)
        data = Data(string.utf8)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw BookImportError.invalidEPUB("XML 或 XHTML 结构损坏") }
    }
}

private func localName(_ name: String) -> String { String(name.split(separator: ":").last ?? "").lowercased() }

private final class ContainerParser: NSObject, XMLParserDelegate {
    var packagePath: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if localName(elementName) == "rootfile", packagePath == nil,
           attributes["media-type"] == nil || attributes["media-type"] == "application/oebps-package+xml" {
            packagePath = attributes["full-path"]
        }
    }
}

private final class PackageParser: NSObject, XMLParserDelegate {
    struct Item { var href: String; var mediaType: String; var properties: String }
    var items: [String: Item] = [:]
    var spine: [String] = []
    var title = ""
    var author = ""
    var bookDescription = ""
    private var inMetadata = false
    private var capture: String?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let name = localName(elementName)
        if name == "metadata" { inMetadata = true }
        if inMetadata && ["title", "creator", "description"].contains(name) { capture = name; text = "" }
        if name == "item", let id = attributes["id"], let href = attributes["href"] {
            items[id] = Item(href: href, mediaType: attributes["media-type"] ?? "", properties: attributes["properties"] ?? "")
        }
        if name == "itemref", attributes["linear"] != "no", let id = attributes["idref"] { spine.append(id) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if capture != nil { text += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if capture != nil, let string = String(data: CDATABlock, encoding: .utf8) { text += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        if name == capture {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "title", title.isEmpty { title = value }
            if name == "creator", author.isEmpty { author = value }
            if name == "description", bookDescription.isEmpty { bookDescription = value }
            capture = nil
        }
        if name == "metadata" { inMetadata = false }
    }
}

private final class EncryptionParser: NSObject, XMLParserDelegate {
    var references: [String] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if localName(elementName) == "cipherreference", let uri = attributes["URI"] { references.append(uri) }
    }
}

private final class NavigationParser: NSObject, XMLParserDelegate {
    var links: [(String, String)] = []
    private var href: String?
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if localName(elementName) == "a" { href = attributes["href"]; text = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if href != nil { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if localName(elementName) == "a", let href {
            if let title = text.nilIfBlank { links.append((href, title)) }
            self.href = nil
        }
    }
}

private final class XHTMLParser: NSObject, XMLParserDelegate {
    private var text = ""
    private var skipDepth = 0
    private var headingDepth = 0
    private(set) var heading = ""
    private let blockElements: Set<String> = ["p", "div", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "li", "tr", "pre", "hr"]

    var plainText: String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let name = localName(elementName)
        if skipDepth > 0 { skipDepth += 1; return }
        if ["head", "script", "style", "svg"].contains(name) { skipDepth = 1; return }
        if blockElements.contains(name) { text += "\n\n" }
        if name == "br" { text += "\n" }
        if headingDepth > 0 { headingDepth += 1 }
        else if heading.isEmpty && ["h1", "h2"].contains(name) { headingDepth = 1 }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0 else { return }
        text += string
        if headingDepth > 0 { heading += string }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: string) }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if skipDepth > 0 { skipDepth -= 1; return }
        if headingDepth > 0 { headingDepth -= 1 }
        if blockElements.contains(localName(elementName)) { text += "\n\n" }
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
