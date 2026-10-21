import UIKit
import UniformTypeIdentifiers

final class BookshelfViewController: LibraryPageController, UIDocumentPickerDelegate {
    private var stateFilter: YueduReadingState?
    private var groupID: UUID?
    private var ungrouped = false
    private var sorting = YueduShelfSort(rawValue: UserDefaults.standard.string(forKey: "shelf.sort") ?? "") ?? .recent
    private var showSamples = UserDefaults.standard.bool(forKey: "shelf.showSamples")
    private var managing = false
    private var selectedIDs = Set<UUID>()
    private var visibleBooks: [Book] = []
    private var batchBar: UIView?
    private var observer: NSObjectProtocol?
    private var followingObserver: NSObjectProtocol?
    private var importing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        followingObserver = NotificationCenter.default.addObserver(forName: .yueduFollowingChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(checkUpdates), for: .valueChanged)
        scroll.refreshControl = refresh
        scroll.alwaysBounceVertical = true
        render()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let followingObserver { NotificationCenter.default.removeObserver(followingObserver) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let error = LibraryStore.shared.persistenceError { showMessage("存储提示", error) }
    }

    private func render() {
        guard isViewLoaded else { return }
        let store = LibraryStore.shared
        if let groupID, !store.shelfGroups.contains(where: { $0.id == groupID }) {
            self.groupID = nil
        }
        visibleBooks = YueduShelfQuery.books(store.books, state: stateFilter, groupID: groupID,
                                            ungrouped: ungrouped, sort: sorting, showSamples: showSamples)
        selectedIDs.formIntersection(visibleBooks.map(\.id))
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let search = symbolButton("magnifyingglass", label: "搜索书架") { [weak self] in
            self?.navigationController?.pushViewController(LibrarySearchViewController(), animated: true)
        }
        let add = symbolButton("plus", label: "添加书籍") { [weak self] in self?.showImportMenu() }
        content.addArrangedSubview(pageHeader(title: "书架", subtitle: "留下想读的，接着喜欢的。", actions: [search, add]))
        let following = YueduFollowingManager.shared
        if !following.isRunning { scroll.refreshControl?.endRefreshing() }
        if store.books.contains(where: \.canFollow) {
            let updates = store.books.filter { $0.unreadUpdateCount > 0 }.count
            let button = UIButton(type: .system)
            button.setTitle("追更管理 · \(updates) 本有更新  ›", for: .normal)
            button.contentHorizontalAlignment = .leading
            button.accessibilityIdentifier = "shelf.following"
            button.addAction(UIAction { [weak self] _ in self?.openFollowing() }, for: .touchUpInside)
            content.addArrangedSubview(button)
            if following.isRunning {
                content.addArrangedSubview(textLabel(following.message, size: 12, color: Theme.secondary))
            }
        }

        if !managing, stateFilter == nil, groupID == nil, !ungrouped,
           let current = store.books.filter({
            $0.isVisibleOnShelf(showSamples: showSamples) && $0.lastReadAt != nil && $0.readingState == .reading
        }).max(by: { ($0.lastReadAt ?? .distantPast) < ($1.lastReadAt ?? .distantPast) }) ?? YueduShelfQuery.books(store.books, showSamples: showSamples).first(where: { $0.readingState != .finished }) {
            content.addArrangedSubview(continueCard(current))
        }

        let filters = UISegmentedControl(items: ["全部"] + YueduReadingState.allCases.map(\.title))
        filters.selectedSegmentIndex = stateFilter.flatMap { YueduReadingState.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        filters.selectedSegmentTintColor = Theme.accent
        filters.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        filters.accessibilityIdentifier = "shelf.states"
        filters.addAction(UIAction { [weak self, weak filters] _ in
            guard let self, let filters else { return }
            self.stateFilter = filters.selectedSegmentIndex == 0 ? nil : YueduReadingState.allCases[filters.selectedSegmentIndex - 1]
            self.selectedIDs.removeAll()
            self.render()
        }, for: .valueChanged)
        content.addArrangedSubview(filters)

        let groupButton = UIButton(type: .system)
        let groupName = ungrouped ? "未分组" : store.shelfGroups.first(where: { $0.id == groupID })?.name ?? "全部分组"
        groupButton.setTitle(groupName + " ▾", for: .normal)
        groupButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        groupButton.titleLabel?.lineBreakMode = .byTruncatingTail
        groupButton.accessibilityIdentifier = "shelf.groups"
        groupButton.menu = groupFilterMenu()
        groupButton.showsMenuAsPrimaryAction = true
        let count = textLabel("\(visibleBooks.count) 本", size: 12, color: Theme.secondary)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        let manage = UIButton(type: .system)
        manage.setTitle(managing ? "完成" : "管理", for: .normal)
        manage.accessibilityIdentifier = "shelf.manage"
        manage.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.managing.toggle()
            self.selectedIDs.removeAll()
            self.render()
        }, for: .touchUpInside)
        let options = symbolButton("ellipsis", label: "书架选项") {}
        options.menu = optionsMenu()
        options.showsMenuAsPrimaryAction = true
        content.addArrangedSubview(hstack([groupButton, count, UIView(), manage, options], spacing: 10))

        if managing {
            let all = UIButton(type: .system)
            let allSelected = !visibleBooks.isEmpty && selectedIDs.count == visibleBooks.count
            all.setTitle(allSelected ? "取消全选" : "全选", for: .normal)
            all.accessibilityIdentifier = "shelf.selectAll"
            all.isEnabled = !visibleBooks.isEmpty
            all.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.selectedIDs = allSelected ? [] : Set(self.visibleBooks.map(\.id))
                self.render()
            }, for: .touchUpInside)
            let label = textLabel("已选 \(selectedIDs.count) 本", size: 13, color: Theme.secondary)
            label.accessibilityIdentifier = "shelf.selectionCount"
            content.addArrangedSubview(hstack([label, UIView(), all], spacing: 10))
        }

        if visibleBooks.isEmpty {
            content.addArrangedSubview(emptyState())
        } else {
            let grid = vstack([], spacing: 25)
            for start in stride(from: 0, to: visibleBooks.count, by: 3) {
                let row = hstack([], spacing: 19, alignment: .top)
                row.distribution = .fillEqually
                for book in visibleBooks[start..<min(start + 3, visibleBooks.count)] {
                    row.addArrangedSubview(makeCard(book))
                }
                while row.arrangedSubviews.count < 3 { row.addArrangedSubview(UIView()) }
                grid.addArrangedSubview(row)
            }
            content.addArrangedSubview(grid)
        }
        renderBatchBar()
    }

    private func makeCard(_ book: Book) -> UIView {
        let card = BookCard(book: book, action: { [weak self] in
            guard let self else { return }
            if self.managing {
                if !self.selectedIDs.insert(book.id).inserted { self.selectedIDs.remove(book.id) }
                self.render()
            } else {
                self.pushReader(book)
            }
        }, remove: { [weak self] in self?.confirmRemoveBooks([book.id]) })
        card.customMenu = { [weak self] in self?.bookMenu(book) ?? UIMenu() }
        let badge: String
        if managing {
            let selected = selectedIDs.contains(book.id)
            badge = selected ? "✓ 已选择" : "○ 选择"
            card.accessibilityValue = selected ? "已选择" : "未选择"
            if selected { card.accessibilityTraits.insert(.selected) }
        } else {
            let update = book.unreadUpdateCount > 0 ? " · \(book.unreadUpdateCount) 章更新" : ""
            badge = (book.shelfInfo.pinned ? "置顶 · " : "") + book.readingState.title + update
        }
        let label = textLabel(badge, size: 11, weight: .medium, color: Theme.accent)
        label.isAccessibilityElement = false
        if !managing { card.accessibilityValue = badge }
        var labels: [UIView] = [card, label]
        if book.canFollow {
            let latest = textLabel("最新：\(book.latestChapterTitle)", size: 10, color: Theme.secondary)
            latest.numberOfLines = 2
            labels.append(latest)
        }
        return vstack(labels, spacing: 7)
    }

    private func groupFilterMenu() -> UIMenu {
        let store = LibraryStore.shared
        var actions: [UIMenuElement] = [
            UIAction(title: "全部分组", state: groupID == nil && !ungrouped ? .on : .off) { [weak self] _ in self?.setGroupFilter(nil) },
            UIAction(title: "未分组", state: ungrouped ? .on : .off) { [weak self] _ in self?.setGroupFilter(nil, ungrouped: true) }
        ]
        actions += store.shelfGroups.map { group in
            UIAction(title: group.name, state: groupID == group.id ? .on : .off) { [weak self] _ in self?.setGroupFilter(group.id) }
        }
        actions.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "管理分组", image: UIImage(systemName: "folder.badge.gearshape")) { [weak self] _ in
                self?.navigationController?.pushViewController(YueduShelfGroupsViewController(), animated: true)
            }
        ]))
        return UIMenu(children: actions)
    }

    private func setGroupFilter(_ id: UUID?, ungrouped: Bool = false) {
        groupID = id
        self.ungrouped = ungrouped
        selectedIDs.removeAll()
        render()
    }

    private func optionsMenu() -> UIMenu {
        let sortActions = YueduShelfSort.allCases.map { sort in
            UIAction(title: sort.title, state: sorting == sort ? .on : .off) { [weak self] _ in
                self?.sorting = sort
                UserDefaults.standard.set(sort.rawValue, forKey: "shelf.sort")
                self?.render()
            }
        }
        let samples = UIAction(title: "显示未读示例书", state: showSamples ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.showSamples.toggle()
            UserDefaults.standard.set(self.showSamples, forKey: "shelf.showSamples")
            self.render()
        }
        let following = UIAction(title: "追更管理", image: UIImage(systemName: "bell")) { [weak self] _ in self?.openFollowing() }
        return UIMenu(children: [following, UIMenu(title: "排序 · 置顶优先", options: .displayInline, children: sortActions), samples])
    }

    private func bookMenu(_ book: Book) -> UIMenu {
        let ids: Set<UUID> = [book.id]
        return UIMenu(children: [
            UIAction(title: book.shelfInfo.pinned ? "取消置顶" : "置顶", image: UIImage(systemName: "pin")) { [weak self] _ in
                self?.apply(ids) { $0.pinned = !book.shelfInfo.pinned }
            },
            stateMenu(ids),
            moveMenu(ids),
            followingMenu(ids),
            UIAction(title: "书籍详情与缓存", image: UIImage(systemName: "book")) { [weak self] _ in
                self?.navigationController?.pushViewController(YueduBookDetailViewController(bookID: book.id), animated: true)
            },
            UIAction(title: "从书架移除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.confirmRemoveBooks(ids)
            }
        ])
    }

    private func stateMenu(_ ids: Set<UUID>) -> UIMenu {
        UIMenu(title: "阅读状态", image: UIImage(systemName: "book.closed"), children: YueduReadingState.allCases.map { state in
            let allMatch = !ids.isEmpty && LibraryStore.shared.books.filter { ids.contains($0.id) }.allSatisfy { $0.readingState == state }
            return UIAction(title: state.title, state: allMatch ? .on : .off) { [weak self] _ in
                self?.apply(ids) { $0.state = state }
            }
        })
    }

    @objc private func checkUpdates() {
        YueduFollowingManager.shared.start()
        if !YueduFollowingManager.shared.isRunning { scroll.refreshControl?.endRefreshing() }
    }

    private func openFollowing() {
        navigationController?.pushViewController(YueduFollowingViewController(), animated: true)
    }

    private func followingMenu(_ ids: Set<UUID>) -> UIMenu {
        let online = Set(LibraryStore.shared.books.filter { ids.contains($0.id) && $0.canFollow }.map(\.id))
        return UIMenu(title: "追更", image: UIImage(systemName: "bell"), children: [
            UIAction(title: "开始追更", attributes: online.isEmpty ? .disabled : []) { [weak self] _ in self?.setFollowing(online, enabled: true) },
            UIAction(title: "暂停追更", attributes: online.isEmpty ? .disabled : []) { [weak self] _ in self?.setFollowing(online, enabled: false) },
            UIAction(title: "检查所选追更书籍", attributes: online.isEmpty ? .disabled : []) { _ in YueduFollowingManager.shared.start(ids: online) }
        ])
    }

    private func setFollowing(_ ids: Set<UUID>, enabled: Bool) {
        do { try LibraryStore.shared.setFollowing(ids, enabled: enabled) }
        catch { showMessage("未能保存", error.localizedDescription) }
    }

    private func moveMenu(_ ids: Set<UUID>) -> UIMenu {
        var actions = [UIAction(title: "未分组") { [weak self] _ in self?.apply(ids) { $0.groupID = nil } }]
        actions += LibraryStore.shared.shelfGroups.map { group in
            UIAction(title: group.name) { [weak self] _ in self?.apply(ids) { $0.groupID = group.id } }
        }
        actions.append(UIAction(title: "新建分组并移入…", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
            self?.createGroupAndMove(ids)
        })
        return UIMenu(title: "移到分组", image: UIImage(systemName: "folder"), children: actions)
    }

    private func apply(_ ids: Set<UUID>, edit: (inout YueduBookShelfInfo) -> Void) {
        do {
            try LibraryStore.shared.organizeBooks(ids, edit: edit)
        } catch {
            showMessage("未能保存", error.localizedDescription)
        }
    }

    private func createGroupAndMove(_ ids: Set<UUID>) {
        let alert = UIAlertController(title: "新建分组", message: "为选中的书创建分组（1–20 个字）", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "例如：正在追更" }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "创建并移入", style: .default) { [weak self, weak alert] _ in
            do {
                let group = try LibraryStore.shared.saveShelfGroup(name: alert?.textFields?.first?.text ?? "")
                self?.apply(ids) { $0.groupID = group.id }
            } catch {
                self?.showMessage("未能创建分组", error.localizedDescription)
            }
        })
        present(alert, animated: true)
    }

    private func renderBatchBar() {
        batchBar?.removeFromSuperview()
        batchBar = nil
        scroll.contentInset.bottom = managing ? 80 : 0
        guard managing else { return }
        let ids = selectedIDs
        let pinMenu = UIMenu(children: [
            UIAction(title: "置顶") { [weak self] _ in self?.apply(ids) { $0.pinned = true } },
            UIAction(title: "取消置顶") { [weak self] _ in self?.apply(ids) { $0.pinned = false } }
        ])
        let buttons = [("分组", moveMenu(ids)), ("状态", stateMenu(ids)), ("置顶", pinMenu), ("追更", followingMenu(ids))].map { title, menu in
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.menu = menu
            button.showsMenuAsPrimaryAction = true
            button.isEnabled = !ids.isEmpty
            button.accessibilityIdentifier = "shelf.batch.\(title)"
            return button
        }
        let remove = UIButton(type: .system)
        remove.setTitle("移除", for: .normal)
        remove.tintColor = .systemRed
        remove.isEnabled = !ids.isEmpty
        remove.accessibilityIdentifier = "shelf.batch.remove"
        remove.addAction(UIAction { [weak self] _ in self?.confirmRemoveBooks(ids) }, for: .touchUpInside)
        let bar = hstack(buttons + [remove], spacing: 8)
        bar.distribution = .fillEqually
        bar.backgroundColor = Theme.surface
        bar.layer.cornerRadius = 15
        bar.isLayoutMarginsRelativeArrangement = true
        bar.layoutMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            bar.heightAnchor.constraint(equalToConstant: 56)
        ])
        batchBar = bar
    }

    private func confirmRemoveBooks(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let alert = UIAlertController(title: "移除 \(ids.count) 本书？", message: "这些书在应用中的进度、书签和缓存会一并移除。原始文件不受影响。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "移除", style: .destructive) { [weak self] _ in
            do {
                try LibraryStore.shared.removeBooks(ids)
                for id in ids { YueduDownloadManager.shared.pause(bookID: id) }
            } catch {
                self?.showMessage("未能移除", error.localizedDescription)
            }
        })
        present(alert, animated: true)
    }

    private func continueCard(_ book: Book) -> UIView {
        let card = UIControl()
        card.backgroundColor = UIColor(hex: "E8EDDF")
        card.layer.cornerRadius = 20
        let eyebrow = textLabel(book.lastReadAt == nil ? "从这一页开始  ·  START READING" : "接着上次，继续阅读", size: 10, weight: .medium, color: Theme.accent)
        let title = textLabel(book.title, size: 26)
        title.font = .readingSerif(26)
        let detail = textLabel(book.lastReadAt == nil ? "\(book.author) · \(book.isSample ? "经典节选" : book.category)" : "\(book.currentChapterTitle) · \(Int(book.fractionRead * 100))%", size: 11, color: Theme.secondary)
        detail.numberOfLines = 1
        let arrow = textLabel(book.lastReadAt == nil ? "开始阅读  →" : "继续阅读  →", size: 12, weight: .semibold, color: Theme.accent)
        let labels = vstack([eyebrow, title, detail, arrow], spacing: 11)
        labels.setCustomSpacing(16, after: detail)
        let cover = BookCoverView(book: book)
        cover.transform = CGAffineTransform(rotationAngle: 0.09)
        cover.widthAnchor.constraint(equalToConstant: 78).isActive = true
        cover.heightAnchor.constraint(equalToConstant: 113).isActive = true
        let row = hstack([labels, UIView(), cover], spacing: 8)
        row.isUserInteractionEnabled = false
        card.addSubview(row)
        row.pinEdges(to: card, insets: UIEdgeInsets(top: 24, left: 21, bottom: 24, right: 25))
        card.addAction(UIAction { [weak self] _ in self?.pushReader(book) }, for: .touchUpInside)
        card.accessibilityLabel = "\(book.lastReadAt == nil ? "开始阅读" : "继续阅读")，\(book.title)"
        card.accessibilityIdentifier = "shelf.continue"
        card.isAccessibilityElement = true
        card.accessibilityTraits = .button
        return card
    }

    private func emptyState() -> UIView {
        let filtered = stateFilter != nil || groupID != nil || ungrouped
        let icon = UIImageView(image: UIImage(systemName: "books.vertical"))
        icon.tintColor = Theme.accent
        icon.contentMode = .scaleAspectFit
        icon.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let label = textLabel(filtered ? "这里还没有书" : "从一本想读的书开始", size: 18, weight: .medium)
        let sub = textLabel(filtered ? "可在「全部」中长按书籍，调整分组和阅读状态。" : "搜索已启用的书源，把喜欢的书加入书架。", size: 13, color: Theme.secondary)
        label.textAlignment = .center
        sub.textAlignment = .center
        let button = UIButton(type: .system)
        button.setTitle(filtered ? "查看全部书籍" : "找一本书", for: .normal)
        button.accessibilityIdentifier = "shelf.emptyAction"
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if filtered {
                self.stateFilter = nil
                self.setGroupFilter(nil)
            } else {
                self.navigationController?.pushViewController(OnlineSearchViewController(), animated: true)
            }
        }, for: .touchUpInside)
        return vstack([icon, label, sub, button], spacing: 18)
    }

    private func showImportMenu() {
        let alert = UIAlertController(title: "把好书放进书架", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "搜索在线书源", style: .default) { [weak self] _ in self?.navigationController?.pushViewController(OnlineSearchViewController(), animated: true) })
        alert.addAction(UIAlertAction(title: "导入 TXT / EPUB 文件", style: .default) { [weak self] _ in self?.presentImporter() })
        alert.addAction(UIAlertAction(title: "离线试读 · 浮生六记", style: .default) { [weak self] _ in
            guard let sample = SampleLibrary.books.first(where: { $0.title == "浮生六记" }) else { return }
            self?.pushReader(LibraryStore.shared.add(sample))
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.sourceView = view
        alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.maxX - 50, y: view.safeAreaInsets.top + 70, width: 1, height: 1)
        present(alert, animated: true)
    }

    func presentImporter() {
        let epub = UTType(filenameExtension: "epub") ?? .data
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.plainText, epub], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first { importDocument(url) }
    }
    func importDocument(_ url: URL) {
        guard !importing else { return }
        importing = true
        let overlay = UIActivityIndicatorView(style: .large)
        overlay.center = view.center; overlay.color = Theme.accent
        view.addSubview(overlay); overlay.startAnimating()
        Task { [weak self] in
            defer { self?.importing = false; overlay.removeFromSuperview() }
            do {
                let book = try await BookImporter.importBook(from: url)
                let saved = LibraryStore.shared.add(book)
                if let error = LibraryStore.shared.persistenceError { self?.showMessage("保存失败", error) }
                else { self?.pushReader(saved) }
            } catch { self?.showMessage("无法导入", error.localizedDescription) }
        }
    }
}

final class LibrarySearchViewController: UITableViewController, UISearchResultsUpdating {
    private let search = UISearchController(searchResultsController: nil)
    private var results: [Book] = []
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "搜索书架"
        view.backgroundColor = Theme.bg
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "书名、作者或内容简介"
        definesPresentationContext = true
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "book")
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "在线搜索", primaryAction: UIAction { [weak self] _ in self?.navigationController?.pushViewController(OnlineSearchViewController(), animated: true) })
        updateSearchResults(for: search)
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); navigationController?.setNavigationBarHidden(false, animated: animated) }
    func updateSearchResults(for searchController: UISearchController) {
        let term = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        results = YueduShelfQuery.books(LibraryStore.shared.books, showSamples: UserDefaults.standard.bool(forKey: "shelf.showSamples")).filter {
            term.isEmpty || "\($0.title) \($0.author) \($0.summary)".localizedCaseInsensitiveContains(term)
        }
        tableView.reloadData()
        if results.isEmpty { let label = textLabel("没有找到这本书\n可以试试右上角的在线搜索", size: 15, color: Theme.secondary); label.textAlignment = .center; tableView.backgroundView = label } else { tableView.backgroundView = nil }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { results.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "book", for: indexPath)
        let book = results[indexPath.row]
        var config = cell.defaultContentConfiguration(); config.text = book.title; config.secondaryText = "\(book.author) · \(book.sourceName)"
        config.image = UIImage(systemName: "book.closed"); config.imageProperties.tintColor = UIColor(hex: book.coverColor)
        cell.contentConfiguration = config; cell.backgroundColor = Theme.bg; cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        navigationController?.pushViewController(ReaderViewController(bookID: results[indexPath.row].id), animated: true)
    }
}
