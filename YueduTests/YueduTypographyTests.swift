import XCTest
import CoreText
@testable import Yuedu

@MainActor
final class YueduTypographyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testLegacyParagraphSpacingMigratesWithoutChangingOtherPreferences() {
        defaults.set(8.0, forKey: "reader.lineSpacing")
        defaults.set("night", forKey: "reader.paper")
        defaults.set("curl", forKey: "reader.turnStyle")
        let prefs = ReaderPreferences.load(defaults: defaults)
        XCTAssertEqual(prefs.typography.paragraphSpacing, 17)
        XCTAssertEqual(prefs.typography.family, .song)
        XCTAssertFalse(prefs.typography.firstLineIndent)
        XCTAssertEqual(prefs.paper, .night)
        XCTAssertEqual(prefs.turnStyle, .slide)
        prefs.save(defaults: defaults)
        defaults.set(22.0, forKey: "reader.lineSpacing")
        XCTAssertEqual(ReaderPreferences.load(defaults: defaults).typography.paragraphSpacing, 17,
                       "The new paragraph setting must be independent of line spacing")
    }

    func testTypographyRoundTripsIncludingSystemSelectedFont() {
        var prefs = ReaderPreferences(fontSize: 32, lineSpacing: 2, paper: .night)
        prefs.typography = YueduTypography(family: .selected, selectedFontName: UIFont.systemFont(ofSize: 21).fontName,
                                          bold: true, characterSpacing: 1.5, paragraphSpacing: 26, firstLineIndent: true,
                                          alignment: .justified, centeredTitle: true, horizontalMargin: 40,
                                          topMargin: 12, bottomMargin: 48)
        prefs.save(defaults: defaults)
        let restored = ReaderPreferences.load(defaults: defaults)
        XCTAssertEqual(restored.typography, prefs.typography)
        XCTAssertEqual(restored.fontSize, 32)
        XCTAssertEqual(restored.lineSpacing, 2)
        XCTAssertTrue(restored.typography.isFontAvailable)
    }

    func testCorruptedAndOutOfRangeTypographyRemainsReadable() throws {
        defaults.set(Data("bad json".utf8), forKey: "reader.typography")
        XCTAssertEqual(ReaderPreferences.load(defaults: defaults).typography, YueduTypography())
        let bad = YueduTypography(characterSpacing: -50, paragraphSpacing: 300, horizontalMargin: 1000,
                                 topMargin: -100, bottomMargin: 200)
        defaults.set(try JSONEncoder().encode(bad), forKey: "reader.typography")
        let repaired = ReaderPreferences.load(defaults: defaults).typography
        XCTAssertEqual(repaired.characterSpacing, 0)
        XCTAssertEqual(repaired.paragraphSpacing, 40)
        XCTAssertEqual(repaired.insets, UIEdgeInsets(top: 8, left: 56, bottom: 56, right: 56))
        var nonFinite = bad
        nonFinite.characterSpacing = .infinity
        nonFinite.topMargin = .nan
        XCTAssertEqual(nonFinite.sanitized().characterSpacing, 0)
        XCTAssertEqual(nonFinite.sanitized().topMargin, 20)
    }

    func testBodyAndTitleUseIndependentIndentAndAlignment() throws {
        var prefs = ReaderPreferences(fontSize: 24, lineSpacing: 7, paper: .night)
        prefs.typography = YueduTypography(family: .system, bold: true, characterSpacing: 1.5,
                                          paragraphSpacing: 30, firstLineIndent: true, alignment: .justified,
                                          centeredTitle: true)
        let body = prefs.attributedText("夜色渐深。\n新的故事开始。")
        let paragraph = try XCTUnwrap(body.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.firstLineHeadIndent, 48)
        XCTAssertEqual(paragraph.paragraphSpacing, 30)
        XCTAssertEqual(paragraph.lineSpacing, 7)
        XCTAssertEqual(paragraph.alignment, .justified)
        XCTAssertEqual(body.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat, 1.5)
        let font = try XCTUnwrap(body.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        let title = prefs.attributedText("第一章 灯火", size: prefs.titleFontSize, isTitle: true)
        let titleStyle = try XCTUnwrap(title.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(titleStyle.firstLineHeadIndent, 0)
        XCTAssertEqual(titleStyle.alignment, .center)
        XCTAssertEqual((title.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize, 31)
    }

    func testExistingParagraphWhitespaceIsNotDoubleIndentedOrRemoved() throws {
        var prefs = ReaderPreferences(fontSize: 21, lineSpacing: 11, paper: .ivory)
        prefs.typography.firstLineIndent = true
        let source = "　　原有全角缩进。\n  原有空格。\n无缩进。\n\t原有制表符。"
        let text = prefs.attributedText(source)
        XCTAssertEqual(text.string, source)
        for (needle, expected) in [("　　原有", 0.0), ("  原有", 0.0), ("无缩进", 42.0), ("\t原有", 0.0)] {
            let index = (source as NSString).range(of: needle).location
            let style = try XCTUnwrap(text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(style.firstLineHeadIndent, expected)
        }
    }

    func testUnavailableSelectedFontFallsBackWithoutErasingChoice() {
        let typography = YueduTypography(family: .selected, selectedFontName: "Missing-Yuedu-Font", bold: true)
        XCTAssertFalse(typography.isFontAvailable)
        XCTAssertEqual(typography.font(size: 26).pointSize, 26)
        XCTAssertEqual(typography.selectedFontName, "Missing-Yuedu-Font")
        let text = ReaderPreferences(fontSize: 26, lineSpacing: 11, paper: .ivory, typography: typography).attributedText("汉字与 emoji 🌱")
        XCTAssertEqual(text.string, "汉字与 emoji 🌱")
    }

    func testPresetsAndResetPreserveThemeTurnStyleAndFullScreen() {
        var prefs = ReaderPreferences(fontSize: 16, lineSpacing: 4, paper: .night, turnStyle: .slide,
                                      fullScreen: true, showsStatusBarInFullScreen: false)
        prefs.apply(.compact)
        XCTAssertEqual(prefs.fontSize, 18)
        XCTAssertEqual(prefs.typography.horizontalMargin, 18)
        prefs.apply(.large)
        XCTAssertEqual(prefs.fontSize, 28)
        prefs.resetTypography()
        XCTAssertEqual(prefs.typography, YueduTypography())
        XCTAssertEqual(prefs.fontSize, 21)
        XCTAssertEqual(prefs.lineSpacing, 11)
        XCTAssertEqual(prefs.paper, .night)
        XCTAssertEqual(prefs.turnStyle, .slide)
        XCTAssertTrue(prefs.fullScreen)
        XCTAssertFalse(prefs.showsStatusBarInFullScreen)
    }

    func testExtremeTypographyPagesFitAndPreserveUnicode() {
        for family in [YueduTypography.Family.system, .song, .kai] {
            var prefs = ReaderPreferences(fontSize: 36, lineSpacing: 24, paper: .ivory)
            prefs.typography = YueduTypography(family: family, bold: true, characterSpacing: 4,
                                              paragraphSpacing: 40, firstLineIndent: true, alignment: .justified,
                                              horizontalMargin: 56, topMargin: 56, bottomMargin: 56)
            let source = String(repeating: "长夜里的灯火，👨‍👩‍👧‍👦 与 e\u{301} 一起等待。\n新的故事在细雨中开始。\n", count: 12)
            let text = prefs.attributedText(source)
            let size = CGSize(width: 208, height: 150)
            let ranges = YueduPagination.ranges(for: text, size: size)
            XCTAssertGreaterThan(ranges.count, 2)
            XCTAssertEqual(ranges.map { (text.string as NSString).substring(with: $0) }.joined(), source)
            for range in ranges {
                let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text),
                                                    CFRange(location: range.location, length: range.length),
                                                    CGPath(rect: CGRect(origin: .zero, size: size), transform: nil), nil)
                XCTAssertEqual(CTFrameGetVisibleStringRange(frame).length, range.length)
                XCTAssertEqual((source as NSString).rangeOfComposedCharacterSequences(for: range), range)
            }
        }
    }

    func testShortLandscapeViewportFitsTextInsteadOfBlankPages() {
        var prefs = ReaderPreferences(fontSize: 36, lineSpacing: 24, paper: .ivory)
        prefs.typography.topMargin = 56
        prefs.typography.bottomMargin = 56
        let viewport = CGSize(width: 540, height: 135)
        let fitted = YueduTypography.fittedPageInsets(prefs.typography.insets, viewport: viewport,
                                                     minimumContent: prefs.minimumPageContentSize)
        let size = CGSize(width: viewport.width - fitted.left - fitted.right,
                          height: viewport.height - fitted.top - fitted.bottom)
        XCTAssertLessThan(fitted.top, 56)
        XCTAssertGreaterThanOrEqual(size.height, prefs.minimumPageContentSize.height - 0.001)
        let text = prefs.attributedText("第一章 灯火\n", size: prefs.titleFontSize, isTitle: true)
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(location: 0, length: 0),
                                            CGPath(rect: CGRect(origin: .zero, size: size), transform: nil), nil)
        XCTAssertGreaterThan(CTFrameGetVisibleStringRange(frame).length, 0)
        XCTAssertEqual(prefs.typography.topMargin, 56, "Adapting the viewport must not overwrite the chosen margins")
    }
}
