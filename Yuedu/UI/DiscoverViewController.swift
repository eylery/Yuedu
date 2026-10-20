import UIKit

final class DiscoverViewController: LibraryPageController {
    private var selectedCategory = "全部"
    override func viewDidLoad() { super.viewDidLoad(); render() }
    private func render() {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        content.addArrangedSubview(pageHeader(title: "发现", subtitle: "与好文字，不期而遇。", actions: [symbolButton("magnifyingglass", label: "搜索在线书源") { [weak self] in self?.navigationController?.pushViewController(OnlineSearchViewController(), animated: true) }]))
        let feature = UIView(); feature.backgroundColor = Theme.ink; feature.layer.cornerRadius = 22
        let eyebrow = textLabel("THE QUIET CHAPTER  /  静读时刻", size: 10, weight: .medium, color: UIColor(hex: "B9CAA7"))
        let quote = textLabel("且停亭台，\n听一页书的回响。", size: 29, color: UIColor(hex: "F2F2DE")); quote.font = .readingSerif(29)
        let note = textLabel("在忙碌的世界，留一处安静给自己。", size: 12, color: UIColor(hex: "B0BCAF"))
        let stack = vstack([eyebrow, quote, note], spacing: 23)
        feature.addSubview(stack); stack.pinEdges(to: feature, insets: UIEdgeInsets(top: 27, left: 25, bottom: 27, right: 25))
        content.addArrangedSubview(feature)
        content.addArrangedSubview(ActionCard(icon: "globe.asia.australia", title: "探索你的书源", subtitle: "连接自定义书源，搜索更多好书") { [weak self] in self?.navigationController?.pushViewController(OnlineSearchViewController(), animated: true) })
        content.addArrangedSubview(hstack([textLabel("经典，常读常新", size: 20, weight: .semibold), UIView(), textLabel("编辑精选", size: 11, color: Theme.secondary)]))
        let description = textLabel("精选公版作品节选，离线也能随时翻开。", size: 12, color: Theme.secondary)
        content.addArrangedSubview(description)
        content.setCustomSpacing(10, after: content.arrangedSubviews[content.arrangedSubviews.count - 2])
        let books = SampleLibrary.books
        for book in books {
            let card = UIControl()
            let cover = BookCoverView(book: book)
            cover.widthAnchor.constraint(equalToConstant: 74).isActive = true
            cover.heightAnchor.constraint(equalToConstant: 105).isActive = true
            let name = textLabel(book.title, size: 18, weight: .semibold)
            let author = textLabel("\(book.author)  /  \(book.category)", size: 11, color: Theme.secondary)
            let summary = textLabel(book.summary, size: 12, color: Theme.secondary); summary.numberOfLines = 2
            let read = textLabel("翻开这本书  ↗", size: 11, weight: .medium, color: Theme.accent)
            let labels = vstack([name, author, summary, read], spacing: 7)
            let row = hstack([cover, labels], spacing: 18)
            row.isUserInteractionEnabled = false
            card.addSubview(row); row.pinEdges(to: card)
            card.addAction(UIAction { [weak self] _ in let saved = LibraryStore.shared.add(book); self?.pushReader(saved) }, for: .touchUpInside)
            card.accessibilityLabel = "阅读\(book.title)节选"
            card.isAccessibilityElement = true
            card.accessibilityTraits = .button
            content.addArrangedSubview(card)
        }
        let foot = textLabel("好书无需赶路，随时都能出发。", size: 11, color: Theme.secondary); foot.textAlignment = .center
        content.addArrangedSubview(foot)
    }
}
