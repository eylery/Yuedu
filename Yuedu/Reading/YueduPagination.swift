import UIKit
import CoreText

enum YueduPagination {
    static func ranges(for text: NSAttributedString, size: CGSize) -> [NSRange] {
        guard text.length > 0, size.width >= 40, size.height >= 40 else { return [] }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        let string = text.string as NSString
        var result: [NSRange] = []
        var offset = 0
        while offset < text.length {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            // Keep surrogate pairs and composed characters intact even with a
            // viewport too short for one line at the selected font size.
            let length = visible.length > 0 ? visible.length : string.rangeOfComposedCharacterSequence(at: offset).length
            result.append(NSRange(location: offset, length: min(length, text.length - offset)))
            offset += length
        }
        return result
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
