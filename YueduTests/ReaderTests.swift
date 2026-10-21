import XCTest
import UIKit
@testable import Yuedu

final class ReaderTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ReaderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testReadingPreferencesSurviveReload() {
        let preferences = ReaderPreferences(fontSize: 26, lineSpacing: 17, paper: .night)
        preferences.save(defaults: defaults)
        let restored = ReaderPreferences.load(defaults: defaults)
        XCTAssertEqual(restored.fontSize, 26)
        XCTAssertEqual(restored.lineSpacing, 17)
        XCTAssertEqual(restored.paper, .night)
    }

    func testOutOfRangeSettingsRemainReadable() {
        defaults.set(300, forKey: "reader.fontSize")
        defaults.set(-50, forKey: "reader.lineSpacing")
        defaults.set("unavailable-theme", forKey: "reader.paper")
        let restored = ReaderPreferences.load(defaults: defaults)
        XCTAssertEqual(restored.fontSize, 36)
        XCTAssertEqual(restored.lineSpacing, 0)
        XCTAssertEqual(restored.paper, .ivory)
    }

    func testFullScreenPreferencesDefaultAndSurviveReload() {
        let original = ReaderPreferences.load(defaults: defaults)
        XCTAssertFalse(original.fullScreen)
        XCTAssertTrue(original.showsStatusBarInFullScreen)
        var updated = original
        updated.fullScreen = true
        updated.showsStatusBarInFullScreen = false
        updated.save(defaults: defaults)
        let restored = ReaderPreferences.load(defaults: defaults)
        XCTAssertTrue(restored.fullScreen)
        XCTAssertFalse(restored.showsStatusBarInFullScreen)
        var withStatusBar = restored
        withStatusBar.showsStatusBarInFullScreen = true
        withStatusBar.save(defaults: defaults)
        XCTAssertTrue(ReaderPreferences.load(defaults: defaults).showsStatusBarInFullScreen)
    }

    func testInvalidStoredTypesUseReadableDefaults() {
        defaults.set("invalid-number", forKey: "reader.fontSize")
        defaults.set(["invalid"], forKey: "reader.lineSpacing")
        let restored = ReaderPreferences.load(defaults: defaults)
        XCTAssertEqual(restored.fontSize, 21)
        XCTAssertEqual(restored.lineSpacing, 11)
    }
}

final class YueduReaderOverlayTests: XCTestCase {
    @MainActor
    func testToolbarVisibilityKeepsScrollGeometryOffsetAndHitTesting() async throws {
        try await verifyOverlay(style: .scroll)
    }

    @MainActor
    func testToolbarVisibilityKeepsPageInstanceAndPagination() async throws {
        try await verifyOverlay(style: .slide)
    }

    @MainActor
    private func verifyOverlay(style: ReaderPreferences.TurnStyle) async throws {
        let original = ReaderPreferences.load()
        defer { original.save() }
        var preferences = ReaderPreferences(fontSize: 21, lineSpacing: 11, paper: .ivory, turnStyle: style)
        preferences.showsStatusBarInFullScreen = false
        preferences.save()
        let library = LibraryStore.shared
        let book = library.add(Book(title: "功能栏分层验证", author: "测试", summary: "", category: "",
                                    coverColor: "517A65", coverSymbol: "book",
                                    chapters: [BookChapter(title: "第一章", content: String(repeating: "阅读位置不随功能栏显隐而变化。\n", count: 100)),
                                               BookChapter(title: "空章节", content: "")],
                                    sourceName: "本地"))
        let reader = ReaderViewController(bookID: book.id)
        defer {
            reader.beginAppearanceTransition(false, animated: false)
            reader.endAppearanceTransition()
            library.remove(id: book.id)
        }
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.beginAppearanceTransition(true, animated: false)
        reader.view.layoutIfNeeded()
        let body = try XCTUnwrap(find("reader.text", in: reader.view) as? UILabel)
        for _ in 0..<100 {
            if body.text?.contains("阅读位置") == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(body.text?.contains("阅读位置") == true)
        reader.view.layoutIfNeeded()
        reader.endAppearanceTransition()
        let surface = try XCTUnwrap(find("reader.surface", in: reader.view))
        let overlay = try XCTUnwrap(find("reader.chrome", in: reader.view))
        let toggle = try XCTUnwrap(find("reader.fullScreen", in: overlay) as? UIButton)
        let scroll = try XCTUnwrap(find("reader.content", in: surface) as? UIScrollView)
        let pageReader = try XCTUnwrap(reader.children.first as? YueduPageReaderController)
        if style == .scroll {
            scroll.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
        }
        let chapterInfo = try XCTUnwrap(find("reader.chapterInfo", in: reader.view) as? UILabel)
        let pageInfo = try XCTUnwrap(find("reader.pageInfo", in: reader.view) as? UILabel)
        let infoBar = try XCTUnwrap(find("reader.bottomInfo", in: reader.view))
        XCTAssertFalse(infoBar.isDescendant(of: overlay))
        XCTAssertTrue(infoBar.superview === surface.superview,
                      "Chapter information and text belong to the same reading layer")
        let readingLayer = try XCTUnwrap(surface.superview)
        XCTAssertLessThan(try XCTUnwrap(reader.view.subviews.firstIndex(of: readingLayer)),
                          try XCTUnwrap(reader.view.subviews.firstIndex(of: overlay)))
        XCTAssertNil(find("reader.progress", in: overlay))
        let infoFrame = infoBar.frame
        let infoPoint = infoBar.convert(CGPoint(x: infoBar.bounds.midX, y: infoBar.bounds.midY), to: reader.view)
        XCTAssertTrue(try XCTUnwrap(reader.view.hitTest(infoPoint, with: nil)).isDescendant(of: overlay),
                      "Expanded tools must cover the reading information rather than sit above it")
        XCTAssertEqual(infoBar.frame.minY, surface.frame.maxY)
        XCTAssertEqual(chapterInfo.text, "第 1 章 · 第一章")
        XCTAssertNotEqual(pageInfo.text, "— / — 页")
        if style == .slide {
            XCTAssertEqual(pageInfo.text, "\(pageReader.currentPageNumber) / \(pageReader.totalPageCount) 页")
        } else {
            scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
            let parts = try XCTUnwrap(pageInfo.text).replacingOccurrences(of: " 页", with: "").components(separatedBy: " / ")
            XCTAssertEqual(parts.count, 2)
            XCTAssertEqual(parts.first, parts.last, "The end of a scroll chapter must show its last page")
            scroll.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
        }
        let pageInfoText = pageInfo.text
        let frame = surface.frame
        let offset = scroll.contentOffset
        let contentSize = scroll.contentSize
        let page = find("reader.pageText", in: surface)
        let pageDescription = pageReader.pageDescription
        let fraction = pageReader.fraction
        let center = CGPoint(x: reader.view.bounds.midX, y: reader.view.bounds.midY)
        let hit = try XCTUnwrap(reader.view.hitTest(center, with: nil))
        XCTAssertTrue(hit.isDescendant(of: surface), "The uncovered overlay must pass reading gestures through")
        let buttonCenter = toggle.convert(CGPoint(x: toggle.bounds.midX, y: toggle.bounds.midY), to: reader.view)
        let buttonHit = try XCTUnwrap(reader.view.hitTest(buttonCenter, with: nil))
        XCTAssertTrue(buttonHit === toggle || buttonHit.isDescendant(of: toggle))
        XCTAssertFalse(scroll.isDescendant(of: overlay))
        if style == .slide { XCTAssertNotNil(page) }
        for iteration in 0..<6 {
            toggle.sendActions(for: .touchUpInside)
            // Emulate system-bar safe-area callbacks without changing the window.
            reader.additionalSafeAreaInsets.top = iteration.isMultiple(of: 2) ? 20 : 0
            reader.view.layoutIfNeeded()
            XCTAssertEqual(overlay.isHidden, iteration.isMultiple(of: 2))
            XCTAssertEqual(reader.prefersStatusBarHidden, overlay.isHidden)
            XCTAssertEqual(surface.frame, frame)
            XCTAssertFalse(infoBar.isHidden)
            XCTAssertEqual(infoBar.frame, infoFrame)
            XCTAssertEqual(infoBar.accessibilityElementsHidden, !overlay.isHidden)
            XCTAssertEqual(pageInfo.text, pageInfoText)
            XCTAssertEqual(scroll.contentOffset, offset)
            XCTAssertEqual(scroll.contentSize, contentSize)
            XCTAssertEqual(pageReader.pageDescription, pageDescription)
            XCTAssertEqual(pageReader.fraction, fraction)
            if style == .slide {
                XCTAssertTrue(find("reader.pageText", in: surface) === page,
                              "Showing tools must not replace or repaginate the visible page")
            }
        }
        let next = try XCTUnwrap(find("reader.nextChapter", in: overlay) as? UIButton)
        next.sendActions(for: .touchUpInside)
        XCTAssertEqual(chapterInfo.text, "第 2 章 · 空章节")
        XCTAssertEqual(pageInfo.text, "— / — 页", "Do not retain the previous chapter's page count")
    }

    @MainActor
    private func find(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        return view.subviews.lazy.compactMap { self.find(identifier, in: $0) }.first
    }
}

final class YueduReadingPagePositionTests: XCTestCase {
    func testScrollPagesCoverShortExactAndPartialChapters() {
        XCTAssertEqual(YueduReadingPagePosition.scrolling(chapterHeight: 300, viewportHeight: 600, offset: 0),
                       YueduReadingPagePosition(current: 1, total: 1))
        XCTAssertEqual(YueduReadingPagePosition.scrolling(chapterHeight: 1800, viewportHeight: 600, offset: 600),
                       YueduReadingPagePosition(current: 2, total: 3))
        XCTAssertEqual(YueduReadingPagePosition.scrolling(chapterHeight: 1900, viewportHeight: 600, offset: 1300),
                       YueduReadingPagePosition(current: 4, total: 4))
    }

    func testScrollPagesClampBounceAndRecalculateForViewport() {
        XCTAssertEqual(YueduReadingPagePosition.scrolling(chapterHeight: 1900, viewportHeight: 600, offset: -100)?.current, 1)
        XCTAssertEqual(YueduReadingPagePosition.scrolling(chapterHeight: 1900, viewportHeight: 600, offset: 2500)?.current, 4)
        XCTAssertEqual(YueduReadingPagePosition.scrolling(chapterHeight: 1900, viewportHeight: 300, offset: 0)?.total, 7)
    }

    func testUnavailableLayoutDoesNotInventPageNumbers() {
        XCTAssertNil(YueduReadingPagePosition.scrolling(chapterHeight: 0, viewportHeight: 600, offset: 0))
        XCTAssertNil(YueduReadingPagePosition.scrolling(chapterHeight: 100, viewportHeight: 0, offset: 0))
        XCTAssertNil(YueduReadingPagePosition.scrolling(chapterHeight: .infinity, viewportHeight: 600, offset: 0))
        XCTAssertNil(YueduReadingPagePosition.scrolling(chapterHeight: 100, viewportHeight: 600, offset: .nan))
    }
}
