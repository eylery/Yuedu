import UIKit

final class YueduFollowingViewController: UITableViewController {
    private let filters = UISegmentedControl(items: ["追更中", "有更新", "检查失败", "已暂停"])
    private var books: [Book] = []
    private var observers: [NSObjectProtocol] = []
    private let manager = YueduFollowingManager.shared

    init() {
        super.init(style: .insetGrouped)
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "追更管理"
        tableView.backgroundColor = Theme.bg
        tableView.accessibilityIdentifier = "following.list"
        filters.selectedSegmentIndex = 0
        filters.accessibilityIdentifier = "following.filters"
        filters.addAction(UIAction { [weak self] _ in self?.render() }, for: .valueChanged)
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 56))
        header.addSubview(filters)
        filters.pinEdges(to: header, insets: UIEdgeInsets(top: 8, left: 20, bottom: 8, right: 20))
        tableView.tableHeaderView = header
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(checkAll), for: .valueChanged)
        for name in [Notification.Name.libraryChanged, .yueduFollowingChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            })
        }
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        render()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func render() {
        guard isViewLoaded else { return }
        books = LibraryStore.shared.books.filter { book in
            guard book.canFollow else { return false }
            switch filters.selectedSegmentIndex {
            case 1: return book.unreadUpdateCount > 0
            case 2: return book.isFollowing && book.following?.error != nil
            case 3: return !book.isFollowing
            default: return book.isFollowing
            }
        }.sorted {
            if ($0.unreadUpdateCount > 0) != ($1.unreadUpdateCount > 0) { return $0.unreadUpdateCount > 0 }
            return ($0.following?.updatedAt ?? $0.addedAt) > ($1.following?.updatedAt ?? $1.addedAt)
        }
        let check = UIBarButtonItem(title: manager.isRunning ? "停止" : "检查更新", primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            if self.manager.isRunning { self.manager.cancel() }
            else { self.checkAll() }
        })
        check.accessibilityIdentifier = "following.check"
        let menu = UIMenu(children: [
            UIAction(title: "重试失败书籍", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                let ids = Set(LibraryStore.shared.books.filter { $0.isFollowing && $0.following?.error != nil }.map(\.id))
                self?.manager.start(ids: ids)
            },
            UIAction(title: "全部开始追更", image: UIImage(systemName: "bell")) { [weak self] _ in self?.setAllFollowing(true) },
            UIAction(title: "全部暂停追更", image: UIImage(systemName: "bell.slash")) { [weak self] _ in self?.setAllFollowing(false) }
        ])
        let options = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: menu)
        options.accessibilityLabel = "追更选项"
        navigationItem.rightBarButtonItems = [check, options]
        if !manager.isRunning { refreshControl?.endRefreshing() }
        tableView.reloadData()
    }

    @objc private func checkAll() { manager.start() }

    private func setAllFollowing(_ enabled: Bool) {
        save { try LibraryStore.shared.setFollowing(Set(LibraryStore.shared.books.map(\.id)), enabled: enabled) }
    }

    private func save(_ action: () throws -> Void) {
        do { try action() }
        catch { showMessage("未能保存", error.localizedDescription) }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 2 : max(1, books.count)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? "\(filters.titleForSegment(at: filters.selectedSegmentIndex) ?? "书籍") · \(books.count) 本" : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "自动检查仅在打开应用或返回前台时运行，同一本书间隔至少 30 分钟。新加入的在线书籍默认追更；标为已读的书默认暂停，可单独重新开启。" : "轻点书籍继续阅读；左滑或长按可暂停追更、查看详情或清除更新标记。更新标记随阅读进度消除。"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        cell.textLabel?.textColor = Theme.ink
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = Theme.secondary
        cell.detailTextLabel?.numberOfLines = 0
        if indexPath.section == 0 {
            cell.selectionStyle = .none
            if indexPath.row == 0 {
                cell.textLabel?.text = "返回前台自动检查"
                let toggle = UISwitch()
                toggle.isOn = UserDefaults.standard.bool(forKey: "following.autoCheck")
                toggle.accessibilityIdentifier = "following.autoCheck"
                toggle.accessibilityLabel = "返回前台自动检查"
                toggle.addAction(UIAction { [weak self, weak toggle] _ in
                    let enabled = toggle?.isOn == true
                    UserDefaults.standard.set(enabled, forKey: "following.autoCheck")
                    if enabled { self?.manager.start(automatic: true) }
                }, for: .valueChanged)
                cell.accessoryView = toggle
            } else {
                cell.textLabel?.text = manager.message
                cell.textLabel?.font = .systemFont(ofSize: 13)
                cell.accessibilityIdentifier = "following.status"
            }
        } else if books.isEmpty {
            cell.textLabel?.text = ["还没有追更中的书", "暂时没有未读更新", "没有检查失败的书", "没有暂停追更的书"][filters.selectedSegmentIndex]
            cell.detailTextLabel?.text = "可从发现页或在线搜索加入喜欢的网文。"
            cell.selectionStyle = .none
        } else {
            let book = books[indexPath.row]
            cell.textLabel?.text = book.title
            let badge = book.unreadUpdateCount > 0 ? "\(book.unreadUpdateCount) 章未读更新" : "暂无未读更新"
            let checked = book.following?.checkedAt.map { Self.dateText($0) } ?? "尚未检查"
            cell.detailTextLabel?.text = "\(badge) · \(book.sourceName)\n最新：\(book.latestChapterTitle)\n检查：\(checked)" + (book.following?.error.map { "\n检查失败：\($0)" } ?? "")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "following.book.\(book.title)"
        }
        return cell
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1, books.indices.contains(indexPath.row) else { return }
        navigationController?.pushViewController(ReaderViewController(bookID: books[indexPath.row].id), animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1, books.indices.contains(indexPath.row) else { return nil }
        let book = books[indexPath.row]
        let toggle = UIContextualAction(style: .normal, title: book.isFollowing ? "暂停追更" : "开始追更") { [weak self] _, _, completion in
            self?.save { try LibraryStore.shared.setFollowing([book.id], enabled: !book.isFollowing) }
            completion(true)
        }
        toggle.backgroundColor = Theme.accent
        let configuration = UISwipeActionsConfiguration(actions: [toggle])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.section == 1, books.indices.contains(indexPath.row) else { return nil }
        let book = books[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: book.isFollowing ? "暂停追更" : "开始追更", image: UIImage(systemName: "bell")) { _ in
                    self?.save { try LibraryStore.shared.setFollowing([book.id], enabled: !book.isFollowing) }
                },
                UIAction(title: "清除更新标记", image: UIImage(systemName: "checkmark.circle")) { _ in
                    self?.save { try LibraryStore.shared.clearUpdateMarks([book.id]) }
                },
                UIAction(title: "书籍详情与缓存", image: UIImage(systemName: "book")) { _ in
                    self?.navigationController?.pushViewController(YueduBookDetailViewController(bookID: book.id), animated: true)
                }
            ])
        }
    }
}
