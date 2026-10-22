import XCTest
import UIKit
@testable import Yuedu

@MainActor
final class YueduAsyncPaginationTests: XCTestCase {
    func testBackgroundLayoutMatchesUnicodeRangesAndCancels() async throws {
        let preferences = ReaderPreferences(fontSize: 23, lineSpacing: 11, paper: .ivory)
        let text = preferences.attributedText(String(repeating: "中文分页 👨‍👩‍👧‍👦 e\u{301}，段落与标点。\n", count: 200))
        let size = CGSize(width: 320, height: 500)
        let expected = YueduPagination.ranges(for: text, size: size)
        let actual = try await YueduPagination.layoutInBackground(for: text, size: size)
        XCTAssertEqual(actual.ranges, expected)
        XCTAssertEqual(actual.ranges.map { (text.string as NSString).substring(with: $0) }.joined(), text.string)
        let task = Task { try await YueduPagination.layoutInBackground(for: text, size: size) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled chapter must not publish a layout")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testRapidChapterChangesDiscardOldLayoutWithoutBlockingConfigure() async throws {
        let reader = YueduPageReaderController()
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        let preferences = ReaderPreferences(fontSize: 23, lineSpacing: 11, paper: .ivory)
        let old = preferences.attributedText(String(repeating: "过期的超长章节。\n", count: 20_000))
        configure(reader, text: old, fraction: 0.7)
        XCTAssertFalse(reader.isReady, "Configuring must schedule work and return before pagination completes")
        XCTAssertEqual(reader.fraction, 0.7, "Keep saved progress while waiting for layout")
        let current = preferences.attributedText("新章节唯一内容")
        configure(reader, text: current, fraction: 0)
        try await waitUntilReady(reader)
        XCTAssertEqual(reader.totalPageCount, 1)
        XCTAssertEqual(findText(in: reader.view), "新章节唯一内容")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(findText(in: reader.view), "新章节唯一内容")
    }

    func testRotationAndTypographyKeepAnchorAndCancelledWorkCanResume() async throws {
        let reader = YueduPageReaderController()
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        let preferences = ReaderPreferences(fontSize: 23, lineSpacing: 11, paper: .ivory)
        let text = preferences.attributedText((0..<300).map { "第\($0)行文字。长章节应保持阅读位置。\n" }.joined())
        configure(reader, text: text, fraction: 0.6)
        try await waitUntilReady(reader)
        let oldCount = reader.totalPageCount
        reader.view.frame.size = CGSize(width: 800, height: 390)
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
        XCTAssertFalse(reader.isReady)
        reader.cancelPagination()
        reader.configure(text: text, paper: .ivory,
                         insets: UIEdgeInsets(top: 20, left: 28, bottom: 32, right: 28),
                         fraction: 0.6, minimumContentSize: CGSize(width: 84, height: 60),
                         preservePosition: true, hasPrevious: false, hasNext: true)
        reader.view.layoutIfNeeded()
        try await waitUntilReady(reader)
        XCTAssertGreaterThan(reader.currentPageNumber, 1)
        XCTAssertNotEqual(reader.totalPageCount, oldCount)
        XCTAssertEqual(reader.fraction, 0.6, accuracy: 0.08)
    }

    private func configure(_ reader: YueduPageReaderController, text: NSAttributedString, fraction: Double) {
        reader.configure(text: text, paper: .ivory,
                         insets: UIEdgeInsets(top: 20, left: 28, bottom: 32, right: 28),
                         fraction: fraction, minimumContentSize: CGSize(width: 84, height: 60),
                         preservePosition: false, hasPrevious: false, hasNext: true)
        reader.view.layoutIfNeeded()
    }

    private func waitUntilReady(_ reader: YueduPageReaderController) async throws {
        for _ in 0..<300 {
            if reader.isReady { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Pagination did not finish")
    }

    private func findText(in view: UIView) -> String? {
        if view.accessibilityIdentifier == "reader.pageText", !view.isHidden { return view.accessibilityLabel }
        for child in view.subviews {
            if let text = findText(in: child) { return text }
        }
        return nil
    }
}
