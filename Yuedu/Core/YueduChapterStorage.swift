import Foundation
import CryptoKit

extension CodingUserInfoKey {
    static let yueduChapterDirectory = CodingUserInfoKey(rawValue: "Yuedu.chapterDirectory")!
    static let yueduMetadataOnly = CodingUserInfoKey(rawValue: "Yuedu.metadataOnly")!
}

/// Immutable body files let metadata commits reuse cached text without reading it.
struct YueduChapterReference: Codable, Hashable {
    let file: UUID
    let bytes: Int
    let hasText: Bool
    let digest: String
}

struct YueduChapterBody: Hashable {
    private static let emptyDigest = digest(Data())
    let inline: String?
    private let inlineDigest: String?
    let reference: YueduChapterReference?
    let directory: URL?

    init(_ text: String) {
        inline = text
        inlineDigest = text.isEmpty ? Self.emptyDigest : Self.digest(Data(text.utf8))
        reference = nil
        directory = nil
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var digest: String { reference?.digest ?? inlineDigest ?? "" }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.digest == rhs.digest && lhs.byteCount == rhs.byteCount
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(digest)
        hasher.combine(byteCount)
    }

    init(reference: YueduChapterReference, directory: URL) {
        self.reference = reference
        self.directory = directory
        inline = nil
        inlineDigest = nil
    }

    var byteCount: Int { reference?.bytes ?? inline?.utf8.count ?? 0 }
    var hasText: Bool {
        reference?.hasText ?? !(inline ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func read() throws -> String {
        if let inline { return inline }
        guard let reference, let directory else { return "" }
        let data = try Data(contentsOf: directory.appendingPathComponent(reference.file.uuidString))
        guard data.count == reference.bytes, Self.digest(data) == reference.digest, let text = String(data: data, encoding: .utf8) else {
            throw SourceError.invalid("章节缓存损坏，请重新下载或恢复备份。")
        }
        return text
    }

    func readAsync() async throws -> String {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let text = try read()
            try Task.checkCancellation()
            return text
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// One serial writer, immutable bodies first, atomic metadata last. A crash can
/// leave unreferenced files, but can never publish references to unwritten text.
final class YueduChapterStorage {
    private let queue = DispatchQueue(label: "Yuedu.library.storage", qos: .userInitiated)
    private let file: URL
    private(set) var migrationError: String?
    let directory: URL

    init(directory: URL) {
        file = directory.appendingPathComponent("library.json")
        self.directory = directory.appendingPathComponent("chapter-content", isDirectory: true)
    }

    func load() throws -> LibraryStore.Snapshot? {
        try queue.sync {
            let manager = FileManager.default
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard manager.fileExists(atPath: file.path) else { return nil }
            let data = try Data(contentsOf: file)
            let decoder = JSONDecoder()
            decoder.userInfo[.yueduChapterDirectory] = directory
            let saved = try decoder.decode(LibraryStore.Snapshot.self, from: data)
            if let version = saved.storageVersion, version != 2 {
                throw SourceError.invalid("书架存储版本不受支持，原文件已保留。")
            }
            if saved.storageVersion == 2 {
                removeUnreferencedFiles(keeping: references(in: saved))
                return saved
            }
            // Keep the exact legacy file, including local books, until the user
            // has a verified independent backup. A failed migration leaves it active.
            do {
                try preserveLegacy(data)
                return try write(saved)
            } catch {
                migrationError = "正文存储升级未完成，旧书库仍可阅读，保存时会重试：\(error.localizedDescription)"
                return saved
            }
        }
    }

    func save(_ snapshot: LibraryStore.Snapshot) throws -> LibraryStore.Snapshot {
        try queue.sync {
            if migrationError != nil { try preserveLegacy(Data(contentsOf: file)) }
            let saved = try write(snapshot)
            migrationError = nil
            return saved
        }
    }

    private func preserveLegacy(_ data: Data) throws {
        let backup = file.deletingLastPathComponent().appendingPathComponent("library-before-body-split.json")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try data.write(to: backup, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    @MainActor
    func export(_ backup: YueduLibraryBackup) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let data = try JSONEncoder().encode(backup)
                    guard data.count <= YueduLibraryBackup.maximumBytes else {
                        throw SourceError.invalid("书架备份超过 200 MB 上限，暂无法导出。")
                    }
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func write(_ snapshot: LibraryStore.Snapshot) throws -> LibraryStore.Snapshot {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw SourceError.invalid("章节存储路径不是文件夹。") }
        } else {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        var metadata = snapshot
        metadata.storageVersion = 2
        var created: [URL] = []
        do {
            for book in metadata.books.indices {
                for chapter in metadata.books[book].chapters.indices {
                    let body = metadata.books[book].chapters[chapter].body
                    if body.reference != nil, body.directory == directory { continue }
                    if body.byteCount == 0 { continue }
                    let text = try body.read()
                    let data = Data(text.utf8)
                    let reference = YueduChapterReference(file: UUID(), bytes: data.count, hasText: body.hasText, digest: body.digest)
                    let destination = directory.appendingPathComponent(reference.file.uuidString)
                    try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    created.append(destination)
                    metadata.books[book].chapters[chapter].body = YueduChapterBody(reference: reference, directory: directory)
                }
            }
            let encoder = JSONEncoder()
            encoder.userInfo[.yueduMetadataOnly] = true
            try encoder.encode(metadata).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            for url in created { try? manager.removeItem(at: url) }
            throw error
        }
        return metadata
    }

    /// Reclaim only after metadata and live state have committed. Portable
    /// exports enqueued earlier finish before this retirement job executes.
    func removeRetiredFiles(from old: LibraryStore.Snapshot, keeping current: LibraryStore.Snapshot) {
        let retired = references(in: old).subtracting(references(in: current))
        queue.async { [directory] in
            for id in retired { try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString)) }
        }
    }

    private func references(in snapshot: LibraryStore.Snapshot) -> Set<UUID> {
        Set(snapshot.books.flatMap { $0.chapters.compactMap { $0.body.reference?.file } })
    }

    private func removeUnreferencedFiles(keeping ids: Set<UUID>) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in files {
            if let id = UUID(uuidString: url.lastPathComponent), !ids.contains(id) { try? manager.removeItem(at: url) }
        }
    }
}
