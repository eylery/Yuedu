import UIKit

/// Reuses its cover and labels as books move through the viewport.
final class YueduShelfBookCell: UICollectionViewCell, UIContextMenuInteractionDelegate {
    private let button = UIControl()
    private let cover = BookCoverView(frame: .zero)
    private let name = textLabel("", size: 14, weight: .semibold)
    private let author = textLabel("", size: 11, color: Theme.secondary)
    private let progress = textLabel("", size: 10, color: Theme.accent)
    private let badge = textLabel("", size: 11, weight: .medium, color: Theme.accent)
    private let latest = textLabel("", size: 10, color: Theme.secondary)
    private var action: (() -> Void)?
    private var menu: (() -> UIMenu)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        name.numberOfLines = 1
        author.numberOfLines = 1
        latest.numberOfLines = 2
        cover.heightAnchor.constraint(equalTo: cover.widthAnchor, multiplier: 1.43).isActive = true
        let stack = vstack([cover, name, author, progress, badge, latest], spacing: 6)
        stack.isUserInteractionEnabled = false
        button.addSubview(stack)
        stack.pinEdges(to: button)
        contentView.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor)
        ])
        button.isAccessibilityElement = true
        button.addAction(UIAction { [weak self] _ in self?.action?() }, for: .touchUpInside)
        button.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(book: Book, managing: Bool, selected: Bool,
                   action: @escaping () -> Void, menu: @escaping () -> UIMenu) {
        self.action = action
        self.menu = menu
        cover.book = book
        name.text = book.title
        author.text = book.author
        progress.text = book.lastReadAt == nil ? (book.isSample ? "经典节选" : "未开始")
            : "已读 \(Int(book.fractionRead * 100))%"
        let updates = book.unreadUpdateCount > 0 ? " · \(book.unreadUpdateCount) 章更新" : ""
        badge.text = managing ? (selected ? "✓ 已选择" : "○ 选择")
            : (book.shelfInfo.pinned ? "置顶 · " : "") + book.readingState.title + updates
        latest.text = book.canFollow ? "最新：\(book.latestChapterTitle)" : nil
        latest.isHidden = !book.canFollow
        button.accessibilityIdentifier = "book.\(book.title)"
        button.accessibilityLabel = "\(book.title)，\(book.author)"
        button.accessibilityValue = managing ? (selected ? "已选择" : "未选择") : badge.text
        button.accessibilityTraits = managing && selected ? [.button, .selected] : .button
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        action = nil
        menu = nil
        cover.book = nil
        button.accessibilityIdentifier = nil
        button.accessibilityLabel = nil
        button.accessibilityValue = nil
        button.accessibilityTraits = .button
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu else { return nil }
        // Capture the menu for this book before reuse can change the cell.
        let contents = menu()
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in contents }
    }
}
