import UIKit

@MainActor
final class OnlineSearchViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private let table = UITableView(frame: .zero, style: .plain)
    private let searchBar = UISearchBar()
    private let statusLabel = UILabel()
    private let sourceButton = UIButton(type: .system)
    private let failureButton = UIButton(type: .system)
    private let filterButton = UIButton(type: .system)
    private let historyButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let morePanel = UIView()
    private let model = YueduOnlineSearchModel()
    private let history = YueduSearchHistory()
    private var scope: Set<UUID>?
    private var match: YueduSearchMatch = .all
    private var sort: YueduSearchSort = .relevance
    private var mergeVersions = false
    private var rows: [YueduSearchRow] = []
    private let emptyTitle = UILabel()
    private let emptyDetail = UILabel()
    private let emptyPanel = UIView()
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var isBusy = false
    private var hasSearched = false
    private var observer: NSObjectProtocol?
    private let switchingBookID: UUID?
    private let switchingProgress: ReadingProgress?
    private var didStartSwitchSearch = false

    init(switchingBookID: UUID? = nil, switchingProgress: ReadingProgress? = nil) {
        self.switchingBookID = switchingBookID
        self.switchingProgress = switchingProgress
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = switchingBookID == nil ? "搜索书籍" : "换源续读"
        view.backgroundColor = Theme.bg
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "slider.horizontal.3"), style: .plain, target: self, action: #selector(manageSources))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "管理书源"
        table.backgroundColor = Theme.bg
        table.separatorColor = Theme.line
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .onDrag
        table.rowHeight = 94
        table.contentInset.bottom = 20
        table.accessibilityIdentifier = "search.results"
        view.addSubview(table)
        table.pinEdges(to: view)
        buildHeader()
        buildEmptyState()
        buildMorePanel()
        model.onChange = { [weak self] in self?.renderSearch() }
        observer = NotificationCenter.default.addObserver(forName: .sourcesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.operation?.cancel()
                self.generation = UUID()
                self.setBusy(false)
                self.model.updateSources(SourceStore.shared.sources)
                self.renderSearch()
                self.updateSourceCount()
            }
        }
        updateMenus()
        updateSourceCount()
        updateEmptyState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.viewControllers.contains(self) == false {
            model.cancel()
            operation?.cancel()
            generation = UUID()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didStartSwitchSearch, let switchingBookID,
           let book = LibraryStore.shared.book(id: switchingBookID) {
            didStartSwitchSearch = true
            searchBar.text = book.title
            search(book.title)
        }
    }

    deinit {
        operation?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func buildHeader() {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 196))
        sourceButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        sourceButton.contentHorizontalAlignment = .leading
        sourceButton.accessibilityIdentifier = "search.scope"
        sourceButton.addTarget(self, action: #selector(chooseScope), for: .touchUpInside)
        searchBar.placeholder = "搜索书名、作者"
        searchBar.searchBarStyle = .minimal
        searchBar.tintColor = Theme.accent
        searchBar.searchTextField.backgroundColor = Theme.surface
        searchBar.searchTextField.textColor = Theme.ink
        searchBar.searchTextField.font = .systemFont(ofSize: 15)
        searchBar.searchTextField.returnKeyType = .search
        searchBar.delegate = self
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = Theme.secondary
        statusLabel.numberOfLines = 2
        statusLabel.accessibilityIdentifier = "search.status"
        statusLabel.text = "输入书名或作者，在选定的书源中搜索。"
        failureButton.setTitle("失败与重试", for: .normal)
        failureButton.accessibilityIdentifier = "search.failures"
        failureButton.isHidden = true
        failureButton.addTarget(self, action: #selector(showFailures), for: .touchUpInside)
        historyButton.setTitle("搜索历史", for: .normal)
        historyButton.accessibilityIdentifier = "search.history"
        historyButton.showsMenuAsPrimaryAction = true
        filterButton.accessibilityIdentifier = "search.options"
        filterButton.showsMenuAsPrimaryAction = true
        for button in [sourceButton, filterButton, historyButton, failureButton] {
            button.tintColor = Theme.accent
            button.titleLabel?.font = .systemFont(ofSize: 13)
        }
        let options = UIStackView(arrangedSubviews: [filterButton, historyButton])
        options.distribution = .equalSpacing
        for item in [sourceButton, searchBar, options, statusLabel, failureButton] {
            header.addSubview(item)
            item.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            sourceButton.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            sourceButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24),
            sourceButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -24),
            sourceButton.heightAnchor.constraint(equalToConstant: 36),
            searchBar.topAnchor.constraint(equalTo: sourceButton.bottomAnchor, constant: 2),
            searchBar.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            searchBar.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            searchBar.heightAnchor.constraint(equalToConstant: 54),
            options.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 4),
            options.leadingAnchor.constraint(equalTo: sourceButton.leadingAnchor),
            options.trailingAnchor.constraint(equalTo: sourceButton.trailingAnchor),
            options.heightAnchor.constraint(equalToConstant: 40),
            statusLabel.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: sourceButton.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: failureButton.leadingAnchor, constant: -8),
            failureButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            failureButton.trailingAnchor.constraint(equalTo: sourceButton.trailingAnchor)
        ])
        failureButton.setContentHuggingPriority(.required, for: .horizontal)
        table.tableHeaderView = header
    }

    private func buildEmptyState() {
        let icon = UIImageView(image: UIImage(systemName: "text.book.closed"))
        icon.tintColor = Theme.accent.withAlphaComponent(0.75)
        icon.contentMode = .scaleAspectFit
        emptyTitle.font = .readingSerif(22)
        emptyTitle.textColor = Theme.ink
        emptyTitle.textAlignment = .center
        emptyDetail.font = .systemFont(ofSize: 13)
        emptyDetail.textColor = Theme.secondary
        emptyDetail.numberOfLines = 0
        emptyDetail.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [icon, emptyTitle, emptyDetail])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 15
        emptyPanel.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.heightAnchor.constraint(equalToConstant: 46),
            icon.widthAnchor.constraint(equalToConstant: 46),
            stack.topAnchor.constraint(equalTo: emptyPanel.topAnchor, constant: 45),
            stack.leadingAnchor.constraint(equalTo: emptyPanel.leadingAnchor, constant: 34),
            stack.trailingAnchor.constraint(equalTo: emptyPanel.trailingAnchor, constant: -34),
            emptyDetail.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
        ])
        emptyPanel.frame.size.height = 245
    }

    private var availableSources: [BookSource] {
        let originalID = switchingBookID.flatMap { LibraryStore.shared.book(id: $0)?.sourceID }
        return YueduOnlineSearchModel.eligible(SourceStore.shared.sources, excluding: originalID)
    }

    private var selectedSources: [BookSource] {
        availableSources.filter { scope == nil || scope!.contains($0.id) }
    }

    private func updateSourceCount() {
        sourceButton.setTitle("搜索范围：" + (scope == nil ? "全部" : "自选") + " · \(selectedSources.count) 个书源 ▾", for: .normal)
        if !hasSearched { updateEmptyState() }
    }

    private func buildMorePanel() {
        morePanel.frame.size.height = 76
        moreButton.accessibilityIdentifier = "search.more"
        moreButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        moreButton.addTarget(self, action: #selector(loadMore), for: .touchUpInside)
        morePanel.addSubview(moreButton)
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            moreButton.leadingAnchor.constraint(equalTo: morePanel.leadingAnchor, constant: 24),
            moreButton.trailingAnchor.constraint(equalTo: morePanel.trailingAnchor, constant: -24),
            moreButton.topAnchor.constraint(equalTo: morePanel.topAnchor, constant: 12),
            moreButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func updateEmptyState() {
        // Even if a local match filter hides page one, users can still request
        // later pages. Exhaustion is based on raw source results, not the filter.
        let canContinue = hasSearched && (model.canLoadMore || !model.failures.isEmpty)
        table.tableFooterView = rows.isEmpty && !canContinue ? emptyPanel : morePanel
        moreButton.isEnabled = !isBusy && canContinue
        let caption = model.canLoadMore ? (model.wasCancelled ? "继续搜索" : "加载更多结果")
            : (!model.failures.isEmpty ? "重试失败书源" : "已展示全部结果")
        moreButton.setTitle(isBusy ? "正在搜索…" : caption, for: .normal)
        if isBusy {
            emptyTitle.text = "正在翻找故事…"
            emptyDetail.text = "结果会陆续显示，可随时停止搜索。"
        } else if hasSearched {
            emptyTitle.text = "没有匹配的结果"
            emptyDetail.text = "试试其他关键词、匹配方式或搜索范围。"
        } else if availableSources.isEmpty {
            emptyTitle.text = "先添加一个书源"
            emptyDetail.text = "在书源管理中导入并启用文字书源。"
        } else {
            emptyTitle.text = "寻找下一本想读的书"
            emptyDetail.text = "支持按书源和分组选择范围，\n也可以从搜索历史再次查找。"
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        guard let query = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { return }
        view.endEditing(true)
        search(query)
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        model.cancel()
        operation?.cancel()
        generation = UUID()
        setBusy(false)
        statusLabel.text = "已停止 · 保留当前结果，可继续搜索"
        view.endEditing(true)
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        searchBar.setShowsCancelButton(busy, animated: true)
        table.allowsSelection = !busy || !rows.isEmpty
        sourceButton.isEnabled = !busy
        historyButton.isEnabled = !busy
        filterButton.isEnabled = !busy
        updateEmptyState()
    }

    private func search(_ query: String) {
        guard !selectedSources.isEmpty else {
            showMessage("没有可用书源", "请调整搜索范围，或到书源管理中导入并启用其他文字书源。")
            return
        }
        operation?.cancel()
        generation = UUID()
        hasSearched = true
        history.record(query)
        updateMenus()
        model.search(query, sources: selectedSources)
        table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
    }

    private func renderSearch() {
        let requiredTitle = switchingBookID.flatMap { LibraryStore.shared.book(id: $0)?.title }
        rows = model.rows(match: match, sort: sort, merge: mergeVersions && switchingBookID == nil, requiredTitle: requiredTitle)
        setBusy(model.isSearching)
        let count = "\(rows.count) 条匹配 · 累计 \(model.results.count) 个版本"
        if model.isSearching {
            statusLabel.text = "已搜索 \(model.completed)/\(model.total) 个书源 · \(rows.count) 条结果"
        } else {
            statusLabel.text = count + (model.wasCancelled ? " · 已停止" : "")
                + (model.failures.isEmpty ? "" : " · \(model.failures.count) 个失败")
                + (model.sourcesChanged ? "\n书源已变更，重新搜索可更新范围" : "")
        }
        failureButton.isHidden = model.failures.isEmpty
        table.reloadData()
        updateEmptyState()
    }

    private func updateMenus() {
        filterButton.setTitle("\(match.rawValue) · 排序 ▾", for: .normal)
        let matches = YueduSearchMatch.allCases.map { value in
            UIAction(title: value.rawValue, state: value == match ? .on : .off) { [weak self] _ in
                self?.match = value
                self?.updateMenus()
                self?.renderSearch()
            }
        }
        let sorts = YueduSearchSort.allCases.map { value in
            UIAction(title: value.rawValue, state: value == sort ? .on : .off) { [weak self] _ in
                self?.sort = value
                self?.updateMenus()
                self?.renderSearch()
            }
        }
        var options: [UIMenuElement] = [UIMenu(title: "匹配方式", children: matches), UIMenu(title: "结果排序", children: sorts)]
        if switchingBookID == nil {
            options.append(UIAction(title: "合并同名同作者", state: mergeVersions ? .on : .off) { [weak self] _ in
                self?.mergeVersions.toggle()
                self?.updateMenus()
                self?.renderSearch()
            })
        }
        filterButton.menu = UIMenu(children: options)
        var historyActions = history.queries.map { query in
            UIAction(title: query) { [weak self] _ in
                self?.searchBar.text = query
                self?.view.endEditing(true)
                self?.search(query)
            }
        }
        if historyActions.isEmpty {
            historyActions.append(UIAction(title: "暂无搜索记录", attributes: .disabled) { _ in })
        } else {
            historyActions.append(UIAction(title: "清空搜索历史", attributes: .destructive) { [weak self] _ in
                self?.history.clear()
                self?.updateMenus()
            })
        }
        historyButton.menu = UIMenu(title: "最近 20 次搜索 · 仅保存在本机", children: historyActions)
    }

    @objc private func chooseScope() {
        let picker = YueduSearchScopeViewController(sources: availableSources, selected: scope)
        picker.onApply = { [weak self] ids in
            guard let self else { return }
            self.scope = ids
            self.updateSourceCount()
            if self.hasSearched { self.search(self.model.query) }
        }
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    @objc private func loadMore() {
        if model.canLoadMore { model.loadMore() }
        else { model.retryFailures() }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let result = rows[indexPath.row].book
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.bg
        cell.textLabel?.text = result.title
        cell.textLabel?.font = .readingSerif(18)
        cell.textLabel?.textColor = Theme.ink
        let versions = rows[indexPath.row].versions
        let source = versions.count > 1 ? "\(versions.count) 个版本 · 点击选择书源" : result.sourceName
        let detail: String
        if let switchingBookID, let original = LibraryStore.shared.book(id: switchingBookID) {
            detail = YueduSourceSwitch.authorsAgree(original.author, result.author)
                ? "作者一致 · 点击对比目录与试读" : "作者不同或不明 · 请核对是否同一作品"
        } else {
            detail = result.summary.isEmpty ? "点击查看目录并加入书架" : result.summary
        }
        cell.detailTextLabel?.text = "\(result.author)  ·  \(source)\n\(detail)"
        cell.detailTextLabel?.numberOfLines = 2
        cell.detailTextLabel?.font = .systemFont(ofSize: 12)
        cell.detailTextLabel?.textColor = Theme.secondary
        cell.imageView?.image = UIImage(systemName: "book.closed.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 31, weight: .light))
        cell.imageView?.tintColor = Theme.accent
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func prepareSwitch(_ result: SourceSearchResult) {
        guard let switchingBookID,
              model.results.contains(where: { $0.id == result.id }),
              let source = SourceStore.shared.source(id: result.sourceID), source.enabled else {
            showMessage("结果已过期", "请重新搜索后选择换源版本。")
            return
        }
        model.cancel()
        operation?.cancel()
        let token = UUID()
        generation = token
        setBusy(true)
        statusLabel.text = "正在加载新书源目录…"
        operation = Task { [weak self] in
            do {
                let stored = LibraryStore.shared.books.first {
                    $0.sourceID == result.sourceID && $0.bookURL == result.bookURL
                }
                let fetched: Book
                if let stored {
                    fetched = stored
                } else {
                    fetched = try await SourceEngine.shared.loadBook(result, source: source, timeout: 30)
                }
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.setBusy(false)
                guard let original = LibraryStore.shared.book(id: switchingBookID),
                      SourceStore.shared.source(id: source.id) == source else {
                    throw SourceError.invalid("原书或书源已变化，请重新搜索。")
                }
                self.statusLabel.text = "已加载目录，可对比版本并试读。"
                self.navigationController?.pushViewController(
                    YueduSourceSwitchViewController(original: original, candidate: fetched,
                                                    source: source, alreadySaved: stored != nil,
                                                    resumeProgress: self.switchingProgress),
                    animated: true
                )
            } catch {
                guard let self, self.generation == token else { return }
                self.setBusy(false)
                self.statusLabel.text = Task.isCancelled ? "已取消" : "加载目录失败，可重试或选择其他版本"
                if !Task.isCancelled { self.showMessage("无法换源", error.localizedDescription) }
            }
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = rows[indexPath.row]
        let result = row.book
        if switchingBookID != nil {
            prepareSwitch(result)
            return
        }
        if row.versions.count > 1 {
            model.cancel()
            let picker = YueduSearchVersionsViewController(versions: row.versions)
            picker.onSelect = { [weak self, weak picker] result in
                guard let picker else { return }
                self?.showResult(result, presenter: picker)
            }
            navigationController?.pushViewController(picker, animated: true)
        } else {
            showResult(result, presenter: self)
        }
    }

    private func showResult(_ result: SourceSearchResult, presenter: UIViewController) {
        guard model.results.contains(where: { $0.id == result.id }) else {
            presenter.showMessage("结果已过期", "书源配置已变更，请返回并重新搜索。")
            return
        }
        let message = "\(result.author) · \(result.sourceName)" + (result.summary.isEmpty ? "" : "\n\n\(result.summary.prefix(400))")
        let alert = UIAlertController(title: result.title, message: message, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "加入书架并阅读", style: .default) { [weak self] _ in self?.add(result, read: true) })
        alert.addAction(UIAlertAction(title: "加入书架", style: .default) { [weak self] _ in self?.add(result, read: false) })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        }
        presenter.present(alert, animated: true)
    }

    private func add(_ result: SourceSearchResult, read: Bool) {
        navigationController?.popToViewController(self, animated: false)
        guard model.results.contains(where: { $0.id == result.id }) else {
            showMessage("结果已过期", "书源配置已变更，请重新搜索。")
            return
        }
        model.cancel()
        operation?.cancel()
        let token = UUID()
        generation = token
        setBusy(true)
        statusLabel.text = "正在加载《\(result.title)》目录…"
        operation = Task { [weak self] in
            do {
                let book = try await SourceEngine.shared.loadBook(result)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                let saved = LibraryStore.shared.add(book)
                self.setBusy(false)
                if let error = LibraryStore.shared.persistenceError {
                    self.statusLabel.text = "保存失败"
                    self.navigationController?.topViewController?.showMessage("保存失败", error)
                    return
                }
                self.statusLabel.text = "已加入书架 · \(saved.chapters.count) 章"
                if read { self.navigationController?.pushViewController(ReaderViewController(bookID: saved.id), animated: true) }
                else { self.navigationController?.topViewController?.showMessage("已加入书架", "《\(saved.title)》共 \(saved.chapters.count) 章，打开书架即可阅读。") }
            } catch {
                guard let self, self.generation == token else { return }
                self.setBusy(false)
                self.statusLabel.text = Task.isCancelled ? "已停止" : "加载目录失败，请重试"
                if !Task.isCancelled {
                    self.navigationController?.topViewController?.showMessage("无法加入书架", error.localizedDescription)
                }
            }
        }
    }

    @objc private func manageSources() { navigationController?.pushViewController(SourcesViewController(), animated: true) }
    @objc private func showFailures() {
        let details = model.failures.map { "\($0.source.bookSourceName) · 第 \($0.nextPage) 页\n\($0.error ?? "")" }
        let alert = UIAlertController(title: "书源搜索情况", message: details.joined(separator: "\n\n"), preferredStyle: .alert)
        let retry = UIAlertAction(title: "重试失败书源", style: .default) { [weak self] _ in self?.model.retryFailures() }
        retry.isEnabled = !isBusy
        alert.addAction(retry)
        alert.addAction(UIAlertAction(title: "关闭", style: .cancel))
        present(alert, animated: true)
    }
}

@MainActor
private final class YueduSearchVersionsViewController: UITableViewController {
    let versions: [SourceSearchResult]
    var onSelect: ((SourceSearchResult) -> Void)?

    init(versions: [SourceSearchResult]) {
        self.versions = versions
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "选择书源版本"
        view.backgroundColor = Theme.bg
        tableView.rowHeight = 76
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        versions.first.map { "\($0.title) · \($0.author)" }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { versions.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let result = versions[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = result.sourceName
        cell.detailTextLabel?.text = result.bookURL
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect?(versions[indexPath.row])
    }
}
