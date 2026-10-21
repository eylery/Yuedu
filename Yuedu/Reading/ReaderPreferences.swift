import UIKit

/// Shared by the reader and the standalone reading preferences screen.
struct ReaderPreferences {
    enum TurnStyle: String, CaseIterable {
        case scroll, slide

        var title: String { self == .scroll ? "上下滚动" : "平移翻页" }
    }
    enum Paper: String, CaseIterable {
        case ivory, white, night

        var title: String {
            switch self {
            case .ivory: return "纸间"
            case .white: return "素白"
            case .night: return "夜读"
            }
        }
        var background: UIColor {
            switch self {
            case .ivory: return UIColor(red: 0.97, green: 0.95, blue: 0.90, alpha: 1)
            case .white: return UIColor(red: 1, green: 1, blue: 0.99, alpha: 1)
            case .night: return UIColor(red: 0.10, green: 0.12, blue: 0.12, alpha: 1)
            }
        }
        var toolbarBackground: UIColor {
            switch self {
            case .ivory: return UIColor(red: 0.91, green: 0.89, blue: 0.83, alpha: 1)
            case .white: return UIColor(red: 0.92, green: 0.94, blue: 0.93, alpha: 1)
            case .night: return UIColor(red: 0.17, green: 0.20, blue: 0.19, alpha: 1)
            }
        }
        var toolbarSeparator: UIColor { ink.withAlphaComponent(self == .night ? 0.22 : 0.18) }

        var ink: UIColor {
            switch self {
            case .ivory, .white: return UIColor(red: 0.20, green: 0.24, blue: 0.22, alpha: 1)
            case .night: return UIColor(red: 0.77, green: 0.79, blue: 0.75, alpha: 1)
            }
        }
        var secondary: UIColor { ink.withAlphaComponent(0.58) }
        var rule: UIColor { ink.withAlphaComponent(0.11) }
    }

    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var paper: Paper
    var turnStyle: TurnStyle = .scroll
    var fullScreen = false
    var showsStatusBarInFullScreen = true
    var typography = YueduTypography()
    var titleFontSize: CGFloat { min(42, fontSize + 7) }
    var minimumPageContentSize: CGSize {
        CGSize(width: fontSize * 4,
               height: ceil(typography.font(size: titleFontSize).lineHeight + lineSpacing + 4))
    }

    static func load(defaults: UserDefaults = .standard) -> ReaderPreferences {
        let size = defaults.object(forKey: "reader.fontSize") as? Double ?? 21
        let spacing = defaults.object(forKey: "reader.lineSpacing") as? Double ?? 11
        let safeSpacing = spacing.isFinite ? min(24, max(0, spacing)) : 11
        // Preserve the previous paragraph spacing until the user customizes it.
        let typography = defaults.data(forKey: "reader.typography")
            .flatMap { try? JSONDecoder().decode(YueduTypography.self, from: $0) }
            ?? YueduTypography(paragraphSpacing: CGFloat(safeSpacing + 9))
        let savedTurnStyle = defaults.string(forKey: "reader.turnStyle") ?? ""
        // Existing paged readers keep their mode when upgrading from page curl.
        let turnStyle: TurnStyle = savedTurnStyle == "curl"
            ? .slide : TurnStyle(rawValue: savedTurnStyle) ?? .scroll
        return ReaderPreferences(
            fontSize: CGFloat(size.isFinite ? min(36, max(14, size)) : 21),
            lineSpacing: CGFloat(safeSpacing),
            paper: Paper(rawValue: defaults.string(forKey: "reader.paper") ?? "") ?? .ivory,
            turnStyle: turnStyle,
            fullScreen: defaults.bool(forKey: "reader.fullScreen"),
            showsStatusBarInFullScreen: defaults.object(forKey: "reader.fullScreenStatusBar") as? Bool ?? true,
            typography: typography.sanitized()
        )
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(Double(fontSize), forKey: "reader.fontSize")
        defaults.set(Double(lineSpacing), forKey: "reader.lineSpacing")
        defaults.set(paper.rawValue, forKey: "reader.paper")
        defaults.set(turnStyle.rawValue, forKey: "reader.turnStyle")
        defaults.set(fullScreen, forKey: "reader.fullScreen")
        defaults.set(showsStatusBarInFullScreen, forKey: "reader.fullScreenStatusBar")
        if let data = try? JSONEncoder().encode(typography.sanitized()) {
            defaults.set(data, forKey: "reader.typography")
        }
    }

    func attributedText(_ text: String, size: CGFloat? = nil, isTitle: Bool = false) -> NSAttributedString {
        let pointSize = size ?? fontSize
        let font = typography.font(size: pointSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = isTitle ? typography.paragraphSpacing + 8 : typography.paragraphSpacing
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = isTitle ? (typography.centeredTitle ? .center : .left) : typography.alignment.value
        paragraph.firstLineHeadIndent = !isTitle && typography.firstLineIndent ? pointSize * 2 : 0
        // Source files often separate paragraphs with blank lines. Use paragraph
        // spacing once instead of rendering those empty lines a second time.
        let normalized = text.replacingOccurrences(of: #"\n[\t ]*\n+"#, with: "\n", options: .regularExpression)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: paper.ink,
            .paragraphStyle: paragraph,
            .kern: typography.characterSpacing
        ]
        // Some installed faces have no bold variant. Keep the selected family
        // and thicken its strokes rather than silently switching fonts.
        if typography.bold && !font.fontDescriptor.symbolicTraits.contains(.traitBold) {
            attributes[.strokeWidth] = -2.0
        }
        let result = NSMutableAttributedString(string: normalized, attributes: attributes)
        if !isTitle, typography.firstLineIndent,
           let whitespace = try? NSRegularExpression(pattern: #"(?m)^[\t \u3000]+"#) {
            let string = normalized as NSString
            for match in whitespace.matches(in: normalized, range: NSRange(location: 0, length: string.length)) {
                let existingIndent = paragraph.mutableCopy() as! NSMutableParagraphStyle
                existingIndent.firstLineHeadIndent = 0
                result.addAttribute(.paragraphStyle, value: existingIndent, range: string.paragraphRange(for: match.range))
            }
        }
        return result
    }
}
