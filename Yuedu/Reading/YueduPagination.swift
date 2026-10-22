import UIKit
import CoreText

/// Only value data crosses the worker boundary. Core Text layout objects stay
/// in the operation that created them (Apple's Core Text threading contract).
struct YueduPaginationLayout: Sendable {
    let ranges: [NSRange]
}

enum YueduPagination {
    static func ranges(for text: NSAttributedString, size: CGSize) -> [NSRange] {
        (try? calculate(text: text, size: size, checkCancellation: {}))?.ranges ?? []
    }

    static func layoutInBackground(for text: NSAttributedString, size: CGSize) async throws -> YueduPaginationLayout {
        let immutable = NSAttributedString(attributedString: text)
        let task = Task.detached(priority: .userInitiated) {
            try calculate(text: immutable, size: size, checkCancellation: { try Task.checkCancellation() })
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func calculate(text: NSAttributedString, size: CGSize,
                                  checkCancellation: () throws -> Void) throws -> YueduPaginationLayout {
        try checkCancellation()
        guard text.length > 0, size.width >= 40, size.height >= 40 else {
            return YueduPaginationLayout(ranges: [])
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        let string = text.string as NSString
        var result: [NSRange] = []
        var offset = 0
        while offset < text.length {
            try checkCancellation()
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            // Keep surrogate pairs and composed characters intact even with a
            // viewport too short for one line at the selected font size.
            let length = visible.length > 0 ? visible.length : string.rangeOfComposedCharacterSequence(at: offset).length
            result.append(NSRange(location: offset, length: min(length, text.length - offset)))
            offset += length
        }
        try checkCancellation()
        return YueduPaginationLayout(ranges: result)
    }

    static func page(containing offset: Int, in ranges: [NSRange]) -> Int {
        ranges.firstIndex { NSLocationInRange(offset, $0) } ?? max(0, ranges.count - 1)
    }

    static func page(for fraction: Double, count: Int) -> Int {
        guard count > 1, fraction.isFinite else { return 0 }
        let clamped = min(1, max(0, fraction))
        return min(count - 1, Int((clamped * Double(count - 1)).rounded()))
    }
}
