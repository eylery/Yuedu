import UIKit

enum Theme {
    static let bg = UIColor(hex: "F7F8F2")
    static let surface = UIColor(hex: "FFFFFF")
    static let ink = UIColor(hex: "263C32")
    static let secondary = UIColor(hex: "8B9289")
    static let accent = UIColor(hex: "456C53")
    static let line = UIColor(hex: "E5E8DF")
    static let pale = UIColor(hex: "EAF0E4")
}

extension UIColor {
    convenience init(hex: String) {
        let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
        self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

extension UIFont {
    static func readingSerif(_ size: CGFloat) -> UIFont {
        UIFont(name: "STSongti-SC-Regular", size: size)
            ?? UIFont(name: "SongtiSC-Regular", size: size)
            ?? .systemFont(ofSize: size, weight: .regular)
    }
}

extension UIView {
    func pinEdges(to view: UIView, insets: UIEdgeInsets = .zero) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: view.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -insets.bottom)
        ])
    }
}

extension UIViewController {
    func showMessage(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

func textLabel(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = Theme.ink) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.numberOfLines = 0
    return label
}

func symbolButton(_ symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
    let button = UIButton(type: .system)
    button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)), for: .normal)
    button.tintColor = Theme.ink
    button.accessibilityLabel = label
    button.backgroundColor = Theme.surface.withAlphaComponent(0.8)
    button.layer.cornerRadius = 22
    button.widthAnchor.constraint(equalToConstant: 44).isActive = true
    button.heightAnchor.constraint(equalToConstant: 44).isActive = true
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
}

func hstack(_ views: [UIView], spacing: CGFloat = 8, alignment: UIStackView.Alignment = .center) -> UIStackView {
    let stack = UIStackView(arrangedSubviews: views)
    stack.axis = .horizontal
    stack.spacing = spacing
    stack.alignment = alignment
    return stack
}

func vstack(_ views: [UIView] = [], spacing: CGFloat = 8) -> UIStackView {
    let stack = UIStackView(arrangedSubviews: views)
    stack.axis = .vertical
    stack.spacing = spacing
    return stack
}

class LibraryPageController: UIViewController {
    let scroll = UIScrollView()
    let content = UIStackView()
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.bg
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        view.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        content.axis = .vertical
        content.spacing = 25
        scroll.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 25),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -25)
        ])
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }
    func pageHeader(title: String, subtitle: String, actions: [UIView] = []) -> UIView {
        let eyebrow = textLabel("Y U E D U   /   阅 读", size: 10, weight: .semibold, color: Theme.accent)
        let titleLabel = textLabel(title, size: 34, weight: .bold)
        let row = hstack([titleLabel, UIView()] + actions, spacing: 10)
        let sub = textLabel(subtitle, size: 13, color: Theme.secondary)
        return vstack([eyebrow, row, sub], spacing: 10)
    }
    func pushReader(_ book: Book) {
        navigationController?.pushViewController(ReaderViewController(bookID: book.id), animated: true)
    }
}

final class BookCoverView: UIView {
    var book: Book? { didSet { setNeedsDisplay(); accessibilityLabel = book?.title } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.accent
        layer.cornerRadius = 5
        clipsToBounds = true
        isAccessibilityElement = false
    }
    convenience init(book: Book) { self.init(frame: .zero); self.book = book }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        guard let book, let context = UIGraphicsGetCurrentContext() else { return }
        let base = UIColor(hex: book.coverColor)
        base.setFill(); context.fill(rect)
        let w = rect.width, h = rect.height
        context.setFillColor(UIColor.black.withAlphaComponent(0.11).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: w * 0.06, height: h))
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.17).cgColor)
        context.setLineWidth(0.7)
        context.stroke(CGRect(x: w * 0.11, y: h * 0.055, width: w * 0.80, height: h * 0.89))
        let style = book.title.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 3
        if style == 0 {
            for index in 0..<7 {
                let path = UIBezierPath()
                let y = h * 0.65 + CGFloat(index) * h * 0.046
                path.move(to: CGPoint(x: -10, y: y + 30))
                path.addCurve(to: CGPoint(x: w + 20, y: y - 10), controlPoint1: CGPoint(x: w * 0.3, y: y - 70), controlPoint2: CGPoint(x: w * 0.55, y: y + 40))
                UIColor.white.withAlphaComponent(0.21).setStroke(); path.lineWidth = 0.9; path.stroke()
            }
        } else if style == 1 {
            for index in 0..<5 {
                let radius = w * 0.22 + CGFloat(index) * 10
                let circle = UIBezierPath(ovalIn: CGRect(x: w * 0.72 - radius, y: h * 0.82 - radius, width: radius * 2, height: radius * 2))
                UIColor.white.withAlphaComponent(0.15).setStroke(); circle.lineWidth = 0.7; circle.stroke()
            }
        } else {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: w * 0.16, y: h * 0.86))
            path.addLine(to: CGPoint(x: w * 0.49, y: h * 0.6))
            path.addLine(to: CGPoint(x: w * 0.88, y: h * 0.86))
            path.close(); UIColor.white.withAlphaComponent(0.09).setFill(); path.fill()
            let moon = UIBezierPath(ovalIn: CGRect(x: w * 0.62, y: h * 0.56, width: w * 0.16, height: w * 0.16))
            UIColor.white.withAlphaComponent(0.35).setFill(); moon.fill()
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .left
        let fontSize = min(27, w * 0.218)
        let characters = Array(book.title.prefix(10))
        let isChineseTitle = characters.contains { $0.unicodeScalars.contains { $0.value >= 0x3400 && $0.value <= 0x9FFF } }
        let title = isChineseTitle && characters.count >= 4
            ? stride(from: 0, to: characters.count, by: 2).map { String(characters[$0..<min($0 + 2, characters.count)]) }.joined(separator: "\n")
            : book.title
        (title as NSString).draw(in: CGRect(x: w * 0.19, y: h * 0.17, width: w * 0.7, height: h * 0.48), withAttributes: [.font: UIFont.readingSerif(fontSize), .foregroundColor: UIColor.white.withAlphaComponent(0.96), .paragraphStyle: paragraph])
        (book.author as NSString).draw(in: CGRect(x: w * 0.20, y: h * 0.53, width: w * 0.66, height: 20), withAttributes: [.font: UIFont.systemFont(ofSize: max(8, w * 0.075)), .foregroundColor: UIColor.white.withAlphaComponent(0.72)])
        ("阅 读 · 藏 书" as NSString).draw(in: CGRect(x: w * 0.2, y: h * 0.86, width: w * 0.65, height: 12), withAttributes: [.font: UIFont.systemFont(ofSize: max(6, w * 0.052)), .foregroundColor: UIColor.white.withAlphaComponent(0.58)])
    }
}

final class BookCard: UIControl {
    init(book: Book, action: @escaping () -> Void, remove: (() -> Void)? = nil, details: (() -> Void)? = nil) {
        super.init(frame: .zero)
        let cover = BookCoverView(book: book)
        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.heightAnchor.constraint(equalTo: cover.widthAnchor, multiplier: 1.43).isActive = true
        let name = textLabel(book.title, size: 14, weight: .semibold)
        name.numberOfLines = 1
        let author = textLabel(book.author, size: 11, color: Theme.secondary); author.numberOfLines = 1
        let status = textLabel(book.lastReadAt == nil ? (book.isSample ? "经典节选" : "未开始") : "已读 \(Int(book.fractionRead * 100))%", size: 10, color: Theme.accent)
        let stack = vstack([cover, name, author, status], spacing: 6)
        stack.isUserInteractionEnabled = false
        addSubview(stack); stack.pinEdges(to: self)
        addAction(UIAction { _ in action() }, for: .touchUpInside)
        accessibilityLabel = "\(book.title)，\(book.author)"
        accessibilityIdentifier = "book.\(book.title)"
        isAccessibilityElement = true
        accessibilityTraits = .button
        if let remove {
            let interaction = UIContextMenuInteraction(delegate: MenuDelegate.shared)
            menuAction = remove
            addInteraction(interaction)
        }
        detailAction = details
    }
    var customMenu: (() -> UIMenu)?
    var menuAction: (() -> Void)?
    var detailAction: (() -> Void)?
    required init?(coder: NSCoder) { fatalError() }
    private final class MenuDelegate: NSObject, UIContextMenuInteractionDelegate {
        static let shared = MenuDelegate()
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard let card = interaction.view as? BookCard else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                if let customMenu = card.customMenu { return customMenu() }
                var actions: [UIAction] = []
                if card.detailAction != nil {
                    actions.append(UIAction(title: "书籍详情与缓存", image: UIImage(systemName: "book")) { _ in card.detailAction?() })
                }
                actions.append(UIAction(title: "从书架移除", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in card.menuAction?() })
                return UIMenu(children: actions)
            }
        }
    }
}

final class ActionCard: UIControl {
    init(icon: String, title: String, subtitle: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        backgroundColor = Theme.surface
        layer.cornerRadius = 17
        let symbol = UIImageView(image: UIImage(systemName: icon)); symbol.tintColor = Theme.accent
        symbol.contentMode = .scaleAspectFit
        symbol.widthAnchor.constraint(equalToConstant: 27).isActive = true
        let chevronConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let chevron = UIImageView(
            image: UIImage(systemName: "chevron.right", withConfiguration: chevronConfiguration)
        )
        chevron.tintColor = Theme.secondary
        chevron.contentMode = .scaleAspectFit
        // Keep spare row width in the labels instead of stretching the disclosure icon.
        NSLayoutConstraint.activate([
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 18)
        ])
        let labels = vstack([textLabel(title, size: 15, weight: .semibold), textLabel(subtitle, size: 12, color: Theme.secondary)], spacing: 6)
        let stack = hstack([symbol, labels, chevron], spacing: 15)
        stack.isUserInteractionEnabled = false
        addSubview(stack); stack.pinEdges(to: self, insets: UIEdgeInsets(top: 20, left: 19, bottom: 20, right: 19))
        addAction(UIAction { _ in action() }, for: .touchUpInside)
        accessibilityLabel = title
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError() }
}
