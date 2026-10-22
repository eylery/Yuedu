import UIKit

final class ProfileViewController: LibraryPageController {
    override func viewDidLoad() { super.viewDidLoad(); render() }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); render() }
    private func render() {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        content.addArrangedSubview(pageHeader(title: "我的", subtitle: "每一页，都算数。"))
        let avatar = UIImageView(image: UIImage(systemName: "leaf.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 54)))
        avatar.tintColor = Theme.accent; avatar.contentMode = .scaleAspectFit
        avatar.widthAnchor.constraint(equalToConstant: 62).isActive = true
        let identity = vstack([textLabel("自在阅读的人", size: 23, weight: .semibold), textLabel("不急不徐，自有收获", size: 12, color: Theme.secondary)], spacing: 9)
        content.addArrangedSubview(hstack([avatar, identity, UIView()], spacing: 17))
        let stats = hstack([], spacing: 0)
        stats.distribution = .fillEqually; stats.backgroundColor = Theme.pale; stats.layer.cornerRadius = 20
        stats.isLayoutMarginsRelativeArrangement = true; stats.layoutMargins = UIEdgeInsets(top: 25, left: 8, bottom: 25, right: 8)
        for (value, label) in [("\(LibraryStore.shared.books.count)", "书架藏书"), ("\(Int(LibraryStore.shared.readingSeconds / 60))", "阅读分钟"), ("\(LibraryStore.shared.readingDates.count)", "阅读天数")] {
            let number = textLabel(value, size: 29, weight: .light, color: Theme.accent); number.textAlignment = .center
            let caption = textLabel(label, size: 11, color: Theme.secondary); caption.textAlignment = .center
            stats.addArrangedSubview(vstack([number, caption], spacing: 8))
        }
        content.addArrangedSubview(stats)
        let actions = vstack([], spacing: 12)
        actions.addArrangedSubview(ActionCard(icon: "bookmark", title: "我的书签", subtitle: "收藏那些想再读一遍的地方") { [weak self] in self?.navigationController?.pushViewController(AllBookmarksViewController(), animated: true) })
        actions.addArrangedSubview(ActionCard(icon: "internaldrive", title: "缓存管理", subtitle: "空间占用、下载任务与章节清理") { [weak self] in
            self?.navigationController?.pushViewController(YueduCacheViewController(), animated: true)
        })
        actions.addArrangedSubview(ActionCard(icon: "textformat.size", title: "阅读设置", subtitle: "字号、行距与纸张，调成喜欢的样子") { [weak self] in self?.navigationController?.pushViewController(ReadingSettingsViewController(), animated: true) })
        actions.addArrangedSubview(ActionCard(icon: "text.badge.checkmark", title: "正文净化", subtitle: "替换规则、效果预览与恢复原文") { [weak self] in
            self?.navigationController?.pushViewController(YueduPurificationViewController(), animated: true)
        })
        actions.addArrangedSubview(ActionCard(icon: "square.and.arrow.down", title: "导入本地书籍", subtitle: "支持 TXT 与 EPUB 格式") { [weak self] in
            guard let tabs = self?.tabBarController as? MainTabBarController else { return }
            tabs.selectedIndex = 0
            (tabs.selectedViewController as? UINavigationController)?.popToRootViewController(animated: false)
            tabs.bookshelf.presentImporter()
        })
        actions.addArrangedSubview(ActionCard(icon: "square.stack.3d.up", title: "管理我的书源", subtitle: "导入、编辑与分享你的书源配置") { [weak self] in self?.tabBarController?.selectedIndex = 2 })
        actions.addArrangedSubview(ActionCard(icon: "externaldrive", title: "备份与恢复", subtitle: "保存书架、进度、书签与离线正文") { [weak self] in
            self?.navigationController?.pushViewController(YueduBackupViewController(), animated: true)
        })
        actions.addArrangedSubview(ActionCard(icon: "info.circle", title: "关于阅读", subtitle: "一个安静、自由的阅读空间") { [weak self] in self?.showAbout() })
        content.addArrangedSubview(actions)
        let foot = textLabel("阅 读  Y U E D U\nVersion 1.0 · 为每一次沉浸而作", size: 11, color: Theme.secondary); foot.textAlignment = .center
        content.addArrangedSubview(foot)
    }
    private func showAbout() {
        showMessage("阅读 · Yuedu", "以 Legado 的自定义书源理念为参考，使用 UIKit 独立开发的 iPhone 阅读器。\n\n支持 TXT、未加密 EPUB，以及 CSS、XPath、JSONPath、JavaScript 等文字书源规则。可更新目录、批量缓存、换源续读和备份书架。规则支持不代表所有网站均可使用。\n\n本地数据保存在设备上，无需账号。内置内容为公版经典节选。漫画、有声、视频源不纳入文字书源库。\n\n参考项目：github.com/gedoor/legado")
    }
}

final class AllBookmarksViewController: UITableViewController {
    private var bookmarks: [Bookmark] = []
    override func viewDidLoad() {
        super.viewDidLoad(); title = "我的书签"; tableView.backgroundColor = Theme.bg
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "bookmark")
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); navigationController?.setNavigationBarHidden(false, animated: animated)
        reload()
    }
    private func reload() {
        bookmarks = LibraryStore.shared.bookmarks
        if bookmarks.isEmpty { let label = textLabel("还没有书签\n阅读时轻点书签图标，留住这一页。", size: 15, color: Theme.secondary); label.textAlignment = .center; tableView.backgroundView = label } else { tableView.backgroundView = nil }
        tableView.reloadData()
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { bookmarks.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let bookmark = bookmarks[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "bookmark", for: indexPath)
        var config = cell.defaultContentConfiguration()
        config.text = bookmark.title; config.secondaryText = LibraryStore.shared.book(id: bookmark.bookID)?.title
        config.image = UIImage(systemName: "bookmark.fill"); config.imageProperties.tintColor = Theme.accent
        cell.contentConfiguration = config; cell.backgroundColor = Theme.bg; cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let bookmark = bookmarks[indexPath.row]
        guard LibraryStore.shared.updateProgress(bookID: bookmark.bookID, chapterIndex: bookmark.chapterIndex, scrollFraction: bookmark.scrollFraction) else {
            showMessage("无法打开书签", LibraryStore.shared.persistenceError ?? "对应书籍或章节已不存在。")
            return
        }
        navigationController?.pushViewController(ReaderViewController(bookID: bookmark.bookID), animated: true)
    }
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        if !LibraryStore.shared.removeBookmark(id: bookmarks[indexPath.row].id) {
            showMessage("书签未能移除", LibraryStore.shared.persistenceError ?? "请稍后重试。")
        }
        reload()
    }
}
