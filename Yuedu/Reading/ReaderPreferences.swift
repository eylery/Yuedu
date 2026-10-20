import UIKit

/// Shared by the reader and the standalone reading preferences screen.
struct ReaderPreferences {
    enum TurnStyle: String, CaseIterable {
        case scroll, curl
        var title: String { self == .scroll ? "上下滚动" : "仿真翻页" }
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

    static func load(defaults: UserDefaults = .standard) -> ReaderPreferences {
        let size = defaults.object(forKey: "reader.fontSize") as? Double ?? 21
        let spacing = defaults.object(forKey: "reader.lineSpacing") as? Double ?? 11
        return ReaderPreferences(
            fontSize: CGFloat(size.isFinite ? min(30, max(16, size)) : 21),
            lineSpacing: CGFloat(spacing.isFinite ? min(22, max(4, spacing)) : 11),
            paper: Paper(rawValue: defaults.string(forKey: "reader.paper") ?? "") ?? .ivory,
            turnStyle: TurnStyle(rawValue: defaults.string(forKey: "reader.turnStyle") ?? "") ?? .scroll
        )
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(Double(fontSize), forKey: "reader.fontSize")
        defaults.set(Double(lineSpacing), forKey: "reader.lineSpacing")
        defaults.set(paper.rawValue, forKey: "reader.paper")
        defaults.set(turnStyle.rawValue, forKey: "reader.turnStyle")
    }

    func attributedText(_ text: String, size: CGFloat? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = lineSpacing + 9
        paragraph.lineBreakMode = .byWordWrapping
        // Source files often separate paragraphs with blank lines. Use paragraph
        // spacing once instead of rendering those empty lines a second time.
        let normalized = text.replacingOccurrences(of: #"\n[\t ]*\n+"#, with: "\n", options: .regularExpression)
        return NSAttributedString(string: normalized, attributes: [
            .font: UIFont.readingSerif(size ?? fontSize),
            .foregroundColor: paper.ink,
            .paragraphStyle: paragraph
        ])
    }
}
