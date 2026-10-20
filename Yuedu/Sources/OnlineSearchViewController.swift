import UIKit

@MainActor
final class OnlineSearchViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private struct Outcome {
        let name: String
        let results: [SourceSearchResult]
        let error: String?
    }

    private let table = UITableView(frame: .zero, style: .plain)
    private let searchBar = UISearchBar()
    private let statusLabel = UILabel()
    private let sourceButton = UIButton(type: .system)
    private let failureButton = UIButton(type: .system)
    private let emptyTitle = UILabel()
    private let emptyDetail = UILabel()
    private let emptyPanel = UIView()
    private var results: [SourceSearchResult] = []
    private var failures: [String] = []
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var isBusy = false
    private var hasSearched = false
    private var observer: NSObjectProtocol?
    private let switchingBookID: UUID?
    private var didStartSwitchSearch = false

    init(switchingBookID: UUID? = nil) {
        self.switchingBookID = switchingBookID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = switchingBookID == nil ? "发现" : "换源续读"
        view.backgroundColor = Theme.bg
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "slider.horizontal.3"), style: .plain, target: self, action: #selector(manageSources))
        table.backgroundColor = Theme.bg
        table.separatorColor = Theme.line
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .onDrag
        table.rowHeight = 94
        table.contentInset.bottom = 20
        view.addSubview(table)
        table.pinEdges(to: view)
        buildHeader()
        buildEmptyState()
        observer = NotificationCenter.default.addObserver(forName: .sourcesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSourceCount() }
        }
        updateSourceCount()
        updateEmptyState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
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
        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 239))
        let eyebrow = UILabel()
        eyebrow.text = "FIND YOUR NEXT CHAPTER"
        eyebrow.font = .systemFont(ofSize: 10, weight: .semibold)
        eyebrow.textColor = Theme.accent
        let heading = UILabel()
        heading.text = "万千故事，等你翻开。"
        heading.font = .readingSerif(29)
        heading.textColor = Theme.ink
        heading.adjustsFontSizeToFitWidth = true
        heading.minimumScaleFactor = 0.75
        sourceButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        sourceButton.tintColor = Theme.accent
        sourceButton.contentHorizontalAlignment = .leading
        sourceButton.addTarget(self, action: #selector(manageSources), for: .touchUpInside)
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
        statusLabel.text = "从已启用的书源，寻找喜欢的作品。"
        failureButton.setTitle("查看失败原因", for: .normal)
        failureButton.titleLabel?.font = .systemFont(ofSize: 12)
        failureButton.tintColor = Theme.accent
        failureButton.isHidden = true
        failureButton.addTarget(self, action: #selector(showFailures), for: .touchUpInside)
        for item in [eyebrow, heading, sourceButton, searchBar, statusLabel, failureButton] {
            header.addSubview(item)
            item.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            eyebrow.topAnchor.constraint(equalTo: header.topAnchor, constant: 21),
            eyebrow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24),
            heading.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 12),
            heading.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24),
            heading.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -24),
            sourceButton.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            sourceButton.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            sourceButton.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            searchBar.topAnchor.constraint(equalTo: sourceButton.bottomAnchor, constant: 9),
            searchBar.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            searchBar.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            searchBar.heightAnchor.constraint(equalToConstant: 54),
            statusLabel.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: failureButton.leadingAnchor, constant: -8),
            failureButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            failureButton.trailingAnchor.constraint(equalTo: heading.trailingAnchor)
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

    private func updateSourceCount() {
        let count = SourceStore.shared.sources.filter(\.enabled).count
        sourceButton.setTitle(count == 0 ? "还没有启用的书源  ·  去添加 →" : "\(count) 个书源已启用  ·  管理书源 →", for: .normal)
        if !hasSearched { updateEmptyState() }
    }

    private func updateEmptyState() {
        table.tableFooterView = results.isEmpty ? emptyPanel : UIView(frame: .zero)
        if isBusy {
            emptyTitle.text = "正在翻找故事…"
            emptyDetail.text = "搜索结果会陆续出现在这里。"
        } else if hasSearched {
            emptyTitle.text = "还没遇见这本书"
            emptyDetail.text = failures.isEmpty ? "换一个关键词，或添加更多书源再试试。" : "部分书源未能完成搜索。\n可查看失败原因后检查书源设置。"
        } else if SourceStore.shared.sources.filter(\.enabled).isEmpty {
            emptyTitle.text = "每段旅程，都有起点"
            emptyDetail.text = "先添加并启用一个书源，\n你喜欢的故事就从这里开始。"
        } else {
            emptyTitle.text = "留一点时间，给好故事"
            emptyDetail.text = "输入书名或作者，\n开始寻找下一本想读的书。"
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        guard let query = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { return }
        view.endEditing(true)
        search(query)
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        operation?.cancel()
        generation = UUID()
        setBusy(false)
        statusLabel.text = "已取消 · 保留当前搜索结果"
        view.endEditing(true)
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        searchBar.setShowsCancelButton(busy, animated: true)
        table.allowsSelection = !busy || !results.isEmpty
        updateEmptyState()
    }

    private func search(_ query: String) {
        let original = switchingBookID.flatMap { LibraryStore.shared.book(id: $0) }
        let sources = SourceStore.shared.sources.filter { $0.enabled && $0.id != original?.sourceID }
        guard !sources.isEmpty else {
            showMessage(original == nil ? "先添加一个书源" : "没有可用的备用书源",
                        "到“书源”页导入并启用其他文字书源后重试。")
            return
        }
        operation?.cancel()
        let token = UUID()
        generation = token
        results = []
        failures = []
        hasSearched = true
        failureButton.isHidden = true
        table.reloadData()
        setBusy(true)
        statusLabel.text = "正在搜索 \(sources.count) 个书源…"
        operation = Task { [weak self] in
            await withTaskGroup(of: Outcome.self) { group in
                var remaining = sources.makeIterator()
                func enqueue(_ source: BookSource) {
                    group.addTask {
                        do {
                            let results = try await SourceEngine.shared.search(source: source, query: query)
                            return Outcome(name: source.bookSourceName, results: results, error: nil)
                        } catch is CancellationError { return Outcome(name: source.bookSourceName, results: [], error: nil) }
                        catch { return Outcome(name: source.bookSourceName, results: [], error: error.localizedDescription) }
                    }
                }
                for _ in 0..<min(3, sources.count) { if let source = remaining.next() { enqueue(source) } }
                var completed = 0
                for await outcome in group {
                    guard !Task.isCancelled, let self, self.generation == token else { group.cancelAll(); return }
                    completed += 1
                    let incoming = outcome.results.filter {
                        original == nil || YueduCatalog.normalized($0.title) == YueduCatalog.normalized(original!.title)
                    }
                    let existing = Set(self.results.map(\.id))
                    self.results.append(contentsOf: incoming.filter { !existing.contains($0.id) })
                    self.table.allowsSelection = !self.results.isEmpty
                    if let error = outcome.error { self.failures.append("\(outcome.name)\n\(error)") }
                    self.statusLabel.text = "已搜索 \(completed)/\(sources.count) 个书源 · \(self.results.count) 本书"
                    self.failureButton.isHidden = self.failures.isEmpty
                    self.table.reloadData()
                    self.updateEmptyState()
                    if let source = remaining.next() { enqueue(source) }
                }
            }
            guard let self, self.generation == token else { return }
            self.setBusy(false)
            self.statusLabel.text = "找到 \(self.results.count) 本书" + (self.failures.isEmpty ? " · 搜索完成" : " · \(self.failures.count) 个书源失败")
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { results.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let result = results[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.bg
        cell.textLabel?.text = result.title
        cell.textLabel?.font = .readingSerif(18)
        cell.textLabel?.textColor = Theme.ink
        cell.detailTextLabel?.text = "\(result.author)  ·  \(result.sourceName)\n\(result.summary.isEmpty ? "点击查看目录并加入书架" : result.summary)"
        cell.detailTextLabel?.numberOfLines = 2
        cell.detailTextLabel?.font = .systemFont(ofSize: 12)
        cell.detailTextLabel?.textColor = Theme.secondary
        cell.imageView?.image = UIImage(systemName: "book.closed.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 31, weight: .light))
        cell.imageView?.tintColor = Theme.accent
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func prepareSwitch(_ result: SourceSearchResult) {
        guard let switchingBookID else { return }
        operation?.cancel()
        let token = UUID()
        generation = token
        setBusy(true)
        statusLabel.text = "正在加载新书源目录…"
        operation = Task { [weak self] in
            do {
                let candidate = try await SourceEngine.shared.loadBook(result)
                try Task.checkCancellation()
                guard let self, self.generation == token,
                      let original = LibraryStore.shared.book(id: switchingBookID) else { return }
                self.setBusy(false)
                let current = original.chapters.indices.contains(original.progress.chapterIndex)
                    ? original.chapters[original.progress.chapterIndex] : nil
                let matched = current.flatMap {
                    YueduCatalog.matchingIndex($0, in: candidate.chapters, sameSource: false)
                }
                let description = "\(candidate.author) · \(candidate.sourceName)\n\n"
                    + (matched.map { "匹配到：\(candidate.chapters[$0].title)" } ?? "未找到唯一对应章节，请手动选择。")
                    + "\n\n新版本将单独加入书架，原书及其书签、缓存完整保留。"
                let alert = UIAlertController(title: "确认续读位置", message: description, preferredStyle: .alert)
                if let matched {
                    alert.addAction(UIAlertAction(title: "从匹配章节续读", style: .default) { [weak self] _ in
                        self?.continueWith(candidate, index: matched, fraction: original.progress.scrollFraction)
                    })
                }
                alert.addAction(UIAlertAction(title: "手动选择章节", style: .default) { [weak self] _ in
                    let picker = ReaderContentsViewController(
                        book: candidate, currentChapter: matched ?? 0, bookmarksSelected: false
                    )
                    picker.onSelect = { [weak self] index, _ in
                        self?.continueWith(candidate, index: index, fraction: 0)
                    }
                    self?.present(UINavigationController(rootViewController: picker), animated: true)
                })
                alert.addAction(UIAlertAction(title: "取消", style: .cancel))
                self.present(alert, animated: true)
            } catch {
                guard let self, self.generation == token else { return }
                self.setBusy(false)
                self.statusLabel.text = Task.isCancelled ? "已取消" : "加载目录失败"
                if !Task.isCancelled { self.showMessage("无法换源", error.localizedDescription) }
            }
        }
    }

    private func continueWith(_ candidate: Book, index: Int, fraction: Double) {
        let saved = LibraryStore.shared.add(candidate)
        // If this edition is already on the shelf its directory may differ.
        guard let mapped = YueduCatalog.matchingIndex(
            candidate.chapters[index], in: saved.chapters, sameSource: true
        ) else {
            showMessage("目录不一致", "此版本已在书架，但目录与搜索结果不同。请先更新该版本目录。")
            return
        }
        LibraryStore.shared.updateProgress(bookID: saved.id, chapterIndex: mapped, scrollFraction: fraction)
        if let error = LibraryStore.shared.persistenceError {
            showMessage("保存失败", error)
            return
        }
        navigationController?.pushViewController(ReaderViewController(bookID: saved.id), animated: true)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let result = results[indexPath.row]
        if switchingBookID != nil {
            prepareSwitch(result)
            return
        }
        let message = "\(result.author) · \(result.sourceName)" + (result.summary.isEmpty ? "" : "\n\n\(result.summary.prefix(400))")
        let alert = UIAlertController(title: result.title, message: message, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "加入书架并阅读", style: .default) { [weak self] _ in self?.add(result, read: true) })
        alert.addAction(UIAlertAction(title: "加入书架", style: .default) { [weak self] _ in self?.add(result, read: false) })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = alert.popoverPresentationController { popover.sourceView = tableView; popover.sourceRect = tableView.rectForRow(at: indexPath) }
        present(alert, animated: true)
    }

    private func add(_ result: SourceSearchResult, read: Bool) {
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
                self.statusLabel.text = "已加入书架 · \(saved.chapters.count) 章"
                if read { self.navigationController?.pushViewController(ReaderViewController(bookID: saved.id), animated: true) }
                else { self.showMessage("已加入书架", "《\(saved.title)》共 \(saved.chapters.count) 章，打开书架即可阅读。") }
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == token else { return }
                self.setBusy(false)
                self.statusLabel.text = "加载目录失败，请重试"
                self.showMessage("无法加入书架", error.localizedDescription)
            }
        }
    }

    @objc private func manageSources() { navigationController?.pushViewController(SourcesViewController(), animated: true) }
    @objc private func showFailures() { showMessage("书源搜索情况", failures.joined(separator: "\n\n")) }
}
