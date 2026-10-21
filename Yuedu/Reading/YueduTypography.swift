import UIKit

struct YueduTypography: Codable, Equatable {
    enum Family: String, Codable, CaseIterable {
        case song, system, kai, selected

        var title: String {
            switch self {
            case .song: return "宋体"
            case .system: return "系统黑体"
            case .kai: return "楷体"
            case .selected: return "自选字体"
            }
        }

        func font(size: CGFloat) -> UIFont? {
            switch self {
            case .song:
                return UIFont(name: "STSongti-SC-Regular", size: size)
                    ?? UIFont(name: "SongtiSC-Regular", size: size)
            case .system:
                return .systemFont(ofSize: size)
            case .kai:
                return UIFont(name: "STKaitiSC-Regular", size: size)
                    ?? UIFont(name: "KaitiSC-Regular", size: size)
            case .selected:
                return nil
            }
        }
    }

    enum Alignment: String, Codable, CaseIterable {
        case left, justified
        var title: String { self == .left ? "左对齐" : "两端对齐" }
        var value: NSTextAlignment { self == .left ? .left : .justified }
    }

    var family: Family = .song
    var selectedFontName: String?
    var bold = false
    var characterSpacing: CGFloat = 0
    var paragraphSpacing: CGFloat = 20
    var firstLineIndent = false
    var alignment: Alignment = .left
    var centeredTitle = false
    var horizontalMargin: CGFloat = 28
    var topMargin: CGFloat = 20
    var bottomMargin: CGFloat = 32

    var insets: UIEdgeInsets {
        UIEdgeInsets(top: topMargin, left: horizontalMargin, bottom: bottomMargin, right: horizontalMargin)
    }

    static func fittedPageInsets(_ requested: UIEdgeInsets, viewport: CGSize, minimumContent: CGSize) -> UIEdgeInsets {
        var result = requested
        let horizontal = requested.left + requested.right
        let vertical = requested.top + requested.bottom
        let horizontalBudget = max(0, viewport.width - minimumContent.width)
        let verticalBudget = max(0, viewport.height - minimumContent.height)
        if horizontal > horizontalBudget, horizontal > 0 {
            result.left *= horizontalBudget / horizontal
            result.right *= horizontalBudget / horizontal
        }
        if vertical > verticalBudget, vertical > 0 {
            result.top *= verticalBudget / vertical
            result.bottom *= verticalBudget / vertical
        }
        return result
    }

    var isFontAvailable: Bool {
        if family == .selected {
            return selectedFontName.flatMap { UIFont(name: $0, size: 21) } != nil
        }
        return family.font(size: 21) != nil
    }

    var fontTitle: String {
        guard family == .selected else { return family.title }
        return selectedFontName.flatMap { UIFont(name: $0, size: 21)?.familyName } ?? "自选字体不可用"
    }

    func font(size: CGFloat) -> UIFont {
        let base = family == .selected
            ? selectedFontName.flatMap { UIFont(name: $0, size: size) }
            : family.font(size: size)
        let fallback = UIFont.readingSerif(size)
        let font = base ?? fallback
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        else { traits.remove(.traitBold) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: size)
    }

    func sanitized() -> YueduTypography {
        var result = self
        result.characterSpacing = Self.clamp(characterSpacing, to: 0...4, fallback: 0)
        result.paragraphSpacing = Self.clamp(paragraphSpacing, to: 0...40, fallback: 20)
        result.horizontalMargin = Self.clamp(horizontalMargin, to: 12...56, fallback: 28)
        result.topMargin = Self.clamp(topMargin, to: 8...56, fallback: 20)
        result.bottomMargin = Self.clamp(bottomMargin, to: 8...56, fallback: 32)
        return result
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>, fallback: CGFloat) -> CGFloat {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

extension ReaderPreferences {
    enum TypographyPreset: String, CaseIterable {
        case comfortable, compact, large
        var title: String {
            switch self {
            case .comfortable: return "舒适"
            case .compact: return "紧凑"
            case .large: return "大字"
            }
        }
    }

    mutating func resetTypography() {
        fontSize = 21
        lineSpacing = 11
        typography = YueduTypography()
    }

    mutating func apply(_ preset: TypographyPreset) {
        resetTypography()
        typography.firstLineIndent = true
        switch preset {
        case .comfortable:
            typography.alignment = .justified
        case .compact:
            fontSize = 18
            lineSpacing = 5
            typography.family = .system
            typography.paragraphSpacing = 10
            typography.horizontalMargin = 18
            typography.topMargin = 12
            typography.bottomMargin = 16
            typography.alignment = .justified
        case .large:
            fontSize = 28
            lineSpacing = 14
            typography.family = .system
            typography.paragraphSpacing = 24
            typography.characterSpacing = 0.5
            typography.horizontalMargin = 24
        }
    }
}
