import Foundation

/// Small, atomic checkpoint tied to one committed library generation.
/// A new catalog commit invalidates older checkpoints even after a crash.
struct YueduReadingCheckpoint: Codable {
    struct Position: Codable {
        let chapterID: UUID
        let fraction: Double
        let readAt: Date

        func apply(to book: inout Book) {
            guard fraction.isFinite,
                  let index = book.chapters.firstIndex(where: { $0.id == chapterID }) else { return }
            book.progress = ReadingProgress(chapterIndex: index, scrollFraction: min(1, max(0, fraction)))
            book.lastReadAt = readAt
            book.consumeReadUpdates()
            if book.shelf?.state == .wanted { book.shelf?.state = .reading }
        }
    }

    var generation: UUID?
    var positions: [UUID: Position] = [:]
    var seconds: Double
    var dates: [String]
}

extension Notification.Name {
    static let yueduReadingSaveChanged = Notification.Name("Yuedu.readingSaveChanged")
}
