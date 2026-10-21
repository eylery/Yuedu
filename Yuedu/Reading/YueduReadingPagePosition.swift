import UIKit

struct YueduReadingPagePosition: Equatable {
    let current: Int
    let total: Int

    /// Continuous reading uses viewport-sized pages. Reaching the chapter's end
    /// includes its final partial page, even when it cannot scroll to the top.
    static func scrolling(chapterHeight: CGFloat, viewportHeight: CGFloat, offset: CGFloat) -> Self? {
        guard chapterHeight.isFinite, viewportHeight.isFinite, offset.isFinite,
              chapterHeight > 0, viewportHeight > 0 else { return nil }
        let count = ceil(chapterHeight / viewportHeight)
        guard count < CGFloat(Int.max) else { return nil }
        let total = max(1, Int(count))
        let position = min(chapterHeight, max(0, offset))
        let current = position + viewportHeight >= chapterHeight - 0.5
            ? total : min(total, Int(floor(position / viewportHeight)) + 1)
        return Self(current: current, total: total)
    }
}
