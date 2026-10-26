import UIKit

@MainActor
final class OnlineSearchViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private let table = UITableView(frame: .zero, style: .plain)
    private let searchBar = UISearchBar()
    private let searchButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let matchControl = UISegmentedControl(items: ["综合", "书名", "作者", "精确"])
    private let header = UIStackView()
    private let recentStack = UIStackView()
    private let emptyAction = UIButton(type: .system)
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
    private var mergeVersions = true
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
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 112
        table.register(UITableViewCell.self, forCellReuseIdentifier: "YueduSearchResult")
        table.contentInset.bottom = 20
        table.accessibilityIdentifier = "search.results"
        view.addSubview(table)
        buildHeader()
        table.translatesAutoresizingMaskIntoConstraints = false
        let keyboardBottom = table.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        keyboardBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            table.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            table.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor),
            table.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            keyboardBottom
        ])
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
        renderSearch()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        table.reloadData()
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
        header.axis = .vertical
        header.spacing = 6
        view.addSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20)
        ])

        searchBar.placeholder = "搜索书名、作者"
        searchBar.searchBarStyle = .minimal
        searchBar.tintColor = Theme.accent
        searchBar.searchTextField.backgroundColor = Theme.surface
        searchBar.searchTextField.textColor = Theme.ink
        searchBar.searchTextField.font = .systemFont(ofSize: 16)
        searchBar.searchTextField.returnKeyType = .search
        searchBar.searchTextField.autocorrectionType = .no
        searchBar.delegate = self
        searchButton.setTitle("搜索", for: .normal)
        searchButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        searchButton.accessibilityIdentifier = "search.submit"
        searchButton.addTarget(self, action: #selector(submitSearch), for: .touchUpInside)
        searchButton.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let input = UIStackView(arrangedSubviews: [searchBar, searchButton])
        input.alignment = .center
        input.spacing = 4
        header.addArrangedSubview(input)

        sourceButton.contentHorizontalAlignment = .leading
        sourceButton.accessibilityIdentifier = "search.scope"
        sourceButton.addTarget(self, action: #selector(chooseScope), for: .touchUpInside)
        historyButton.setTitle("历史", for: .normal)
        historyButton.accessibilityIdentifier = "search.history"
        historyButton.showsMenuAsPrimaryAction = true
        filterButton.accessibilityIdentifier = "search.options"
        filterButton.showsMenuAsPrimaryAction = true
        let options = UIStackView(arrangedSubviews: [sourceButton, UIView(), filterButton, historyButton])
        options.spacing = 16
        options.heightAnchor.constraint(equalToConstant: 38).isActive = true
        header.addArrangedSubview(options)

        matchControl.selectedSegmentIndex = 0
        matchControl.selectedSegmentTintColor = Theme.surface
        matchControl.accessibilityIdentifier = "search.match"
        matchControl.addTarget(self, action: #selector(changeMatch), for: .valueChanged)
        matchControl.heightAnchor.constraint(equalToConstant: 34).isActive = true
        header.addArrangedSubview(matchControl)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = Theme.secondary
        statusLabel.numberOfLines = 2
        statusLabel.accessibilityIdentifier = "search.status"
        failureButton.setTitle("失败重试", for: .normal)
        failureButton.accessibilityIdentifier = "search.failures"
        failureButton.isHidden = true
        failureButton.addTarget(self, action: #selector(showFailures), for: .touchUpInside)
        stopButton.setTitle("停止", for: .normal)
        stopButton.accessibilityIdentifier = "search.stop"
        stopButton.isHidden = true
        stopButton.addTarget(self, action: #selector(stopSearch), for: .touchUpInside)
        let status = UIStackView(arrangedSubviews: [statusLabel, failureButton, stopButton])
        status.spacing = 12
        status.alignment = .center
        status.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        header.addArrangedSubview(status)
        for button in [sourceButton, filterButton, historyButton, failureButton, stopButton] {
            button.tintColor = Theme.accent
            button.titleLabel?.font = .systemFont(ofSize: 13)
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        updateSearchButton()
    }

    private func buildEmptyState() {
        emptyTitle.font = .readingSerif(22)
        emptyTitle.textColor = Theme.ink
        emptyTitle.textAlignment = .center
        emptyDetail.font = .systemFont(ofSize: 14)
        emptyDetail.textColor = Theme.secondary
        emptyDetail.numberOfLines = 0
        emptyDetail.textAlignment = .center
        emptyAction.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        emptyAction.accessibilityIdentifier = "search.emptyAction"
        emptyAction.addTarget(self, action: #selector(handleEmptyAction), for: .touchUpInside)
        recentStack.axis = .vertical
        recentStack.spacing = 4
        let stack = UIStackView(arrangedSubviews: [emptyTitle, emptyDetail, emptyAction, recentStack])
        stack.axis = .vertical
        stack.spacing = 16
        emptyPanel.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: emptyPanel.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: emptyPanel.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: emptyPanel.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: emptyPanel.bottomAnchor, constant: -24)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if table.tableFooterView === emptyPanel {
            let size = emptyPanel.systemLayoutSizeFitting(
                CGSize(width: table.bounds.width, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            if abs(emptyPanel.frame.height - size.height) > 1 || emptyPanel.frame.width != table.bounds.width {
                emptyPanel.frame = CGRect(x: 0, y: 0, width: table.bounds.width, height: size.height)
                table.tableFooterView = emptyPanel
            }
        }
    }

    private var availableSources: [BookSource] {
        let originalID = switchingBookID.flatMap { LibraryStore.shared.book(id: $0)?.sourceID }
        return YueduOnlineSearchModel.eligible(SourceStore.shared.sources, excluding: originalID)
    }

    private var selectedSources: [BookSource] {
        availableSources.filter { scope == nil || scope!.contains($0.id) }
    }

    private func updateSourceCount() {
        sourceButton.setTitle((scope == nil ? "全部" : "自选") + " · \(selectedSources.count) 个书源 ▾", for: .normal)
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
        let canContinue = hasSearched && (model.canLoadMore || !model.failures.isEmpty)
        table.tableFooterView = rows.isEmpty ? emptyPanel : morePanel
        moreButton.isEnabled = !isBusy && canContinue
        let caption = model.canLoadMore ? (model.wasCancelled ? "继续搜索" : "加载更多结果")
            : (!model.failures.isEmpty ? "重试失败书源" : "已展示全部结果")
        moreButton.setTitle(isBusy ? "正在搜索…" : caption, for: .normal)
        recentStack.isHidden = hasSearched || history.queries.isEmpty || availableSources.isEmpty
        emptyAction.isHidden = isBusy
        if isBusy {
            emptyTitle.text = "正在搜索…"
            emptyDetail.text = "结果会陆续显示，找到想读的书即可打开。"
        } else if availableSources.isEmpty {
            emptyTitle.text = "先添加一个书源"
            emptyDetail.text = "导入并启用书源后，就能搜索书名或作者。"
            emptyAction.setTitle("添加书源", for: .normal)
        } else if hasSearched {
            emptyTitle.text = model.results.isEmpty ? "暂时没有找到这本书" : "当前筛选没有匹配结果"
            emptyDetail.text = model.results.isEmpty
                ? "可以换个关键词，或调整上方的书源范围。"
                : "已找到其他结果，可切回综合查看。"
            emptyAction.setTitle(!model.results.isEmpty && match != .all ? "查看全部结果"
                : (canContinue ? caption : "重新搜索"), for: .normal)
        } else {
            emptyTitle.text = history.queries.isEmpty ? "寻找下一本想读的书" : "最近搜索"
            emptyDetail.text = history.queries.isEmpty ? "输入书名或作者，点击搜索即可开始。" : "轻点关键词，再搜一次。"
            emptyAction.isHidden = true
        }
        view.setNeedsLayout()
    }

    private func updateRecentSearches() {
        recentStack.arrangedSubviews.forEach {
            recentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for query in history.queries.prefix(6) {
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.tinted()
            configuration.title = query
            configuration.image = UIImage(systemName: "clock.arrow.circlepath")
            configuration.imagePadding = 12
            configuration.baseForegroundColor = Theme.accent
            configuration.baseBackgroundColor = Theme.pale
            configuration.cornerStyle = .medium
            button.configuration = configuration
            button.contentHorizontalAlignment = .leading
            button.accessibilityIdentifier = "search.recent.\(query)"
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addAction(UIAction { [weak self] _ in
                self?.searchBar.text = query
                self?.submitSearch()
            }, for: .touchUpInside)
            recentStack.addArrangedSubview(button)
        }
    }

    @objc private func handleEmptyAction() {
        if availableSources.isEmpty {
            manageSources()
        } else if !model.results.isEmpty && match != .all {
            match = .all
            updateMenus()
            renderSearch()
        } else if hasSearched && (model.canLoadMore || !model.failures.isEmpty) {
            loadMore()
        } else {
            submitSearch()
        }
    }

    @objc private func changeMatch() {
        match = YueduSearchMatch.allCases[matchControl.selectedSegmentIndex]
        updateMenus()
        renderSearch()
    }

    @objc private func submitSearch() {
        guard let query = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { return }
        view.endEditing(true)
        search(query)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        submitSearch()
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        updateSearchButton()
        if searchText.isEmpty {
            operation?.cancel()
            generation = UUID()
            hasSearched = false
            model.reset()
            updateMenus()
        }
    }

    private func updateSearchButton() {
        searchButton.isEnabled = !(searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func stopSearch() {
        model.cancel()
        operation?.cancel()
        generation = UUID()
        setBusy(false)
        statusLabel.text = "已停止 · 保留当前结果，可继续搜索"
        view.endEditing(true)
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        stopButton.isHidden = !busy
        let canBrowse = !busy || model.isSearching
        table.allowsSelection = canBrowse
        matchControl.isEnabled = canBrowse
        sourceButton.isEnabled = canBrowse
        filterButton.isEnabled = canBrowse
        historyButton.isEnabled = canBrowse
        updateEmptyState()
    }

    private func search(_ query: String) {
        guard !selectedSources.isEmpty else {
            showMessage("没有可用书源", "请调整搜索范围，或到书源管理中导入并启用其他文字书源。")
            return
        }
        operation?.cancel()
        generation = UUID()
        searchBar.text = query
        updateSearchButton()
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
        let count = "\(rows.count) 条匹配 · 累计 \(model.results.count) 条收录"
        if !hasSearched {
            statusLabel.text = switchingBookID == nil ? "输入书名或作者，找到结果即可阅读" : "查找同名书籍，选择版本对比并试读"
        } else if model.isSearching {
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
        filterButton.setTitle("排序 ▾", for: .normal)
        filterButton.accessibilityValue = sort.rawValue + (mergeVersions ? "，合并同名同作者" : "，分别显示收录")
        matchControl.selectedSegmentIndex = YueduSearchMatch.allCases.firstIndex(of: match) ?? 0
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
                self?.updateEmptyState()
            })
        }
        historyButton.menu = UIMenu(title: "最近 20 次搜索 · 仅保存在本机", children: historyActions)
        updateRecentSearches()
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
        let row = rows[indexPath.row]
        let result = row.book
        let cell = tableView.dequeueReusableCell(withIdentifier: "YueduSearchResult", for: indexPath)
        cell.backgroundColor = Theme.bg
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        content.textProperties.font = .readingSerif(20)
        content.textProperties.color = Theme.ink
        content.textProperties.numberOfLines = 2
        let saved = row.versions.contains { result in
            LibraryStore.shared.books.contains { $0.sourceID == result.sourceID && $0.bookURL == result.bookURL }
        }
        let source = row.versions.count > 1
            ? "\(row.sourceCount) 个书源 · \(row.versions.count) 条收录" : result.sourceName
        let detail: String
        if let switchingBookID, let original = LibraryStore.shared.book(id: switchingBookID) {
            detail = YueduSourceSwitch.authorsAgree(original.author, result.author)
                ? "作者一致 · 点击对比目录与试读" : "作者不同或不明 · 请核对是否同一作品"
        } else {
            detail = result.summary.isEmpty ? "查看书籍，选择书源并阅读" : result.summary
        }
        content.secondaryText = "\(row.author) · \(source)" + (saved ? " · 已在书架" : "") + "\n\(detail)"
        content.secondaryTextProperties.numberOfLines = 3
        content.secondaryTextProperties.font = .systemFont(ofSize: 13)
        content.secondaryTextProperties.color = Theme.secondary
        content.image = UIImage(systemName: "book.closed.fill")
        content.imageProperties.tintColor = Theme.accent
        content.imageProperties.maximumSize = CGSize(width: 34, height: 44)
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 16)
        cell.contentConfiguration = content
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
        view.endEditing(true)
        model.cancel()
        let detail = YueduSearchBookViewController(versions: row.versions)
        navigationController?.pushViewController(detail, animated: true)
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
