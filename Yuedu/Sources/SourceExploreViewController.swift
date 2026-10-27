import UIKit

@MainActor
final class SourceExploreViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let source: BookSource
    private let category: SourceCategory?
    private let table = UITableView(frame: .zero, style: .plain)
    private let refreshControl = UIRefreshControl()
    private let statusLabel = UILabel()
    private let progress = UIActivityIndicatorView(style: .medium)
    private let emptyPanel = UIView()
    private let emptyTitle = UILabel()
    private let emptyDetail = UILabel()
    private let retryButton = UIButton(type: .system)
    private let footer = UIView()
    private let footerLabel = UILabel()
    private let nextButton = UIButton(type: .system)
    private var categories: [SourceCategory] = []
    private var books: [SourceSearchResult] = []
    private var page = 0
    private var hasNextPage = true
    private var isBusy = false
    private var hasLoaded = false
    private var errorMessage: String?
    private var operation: Task<Void, Never>?
    private var generation = UUID()

    init(source: BookSource) {
        self.source = source
        category = nil
        super.init(nibName: nil, bundle: nil)
    }

    init(source: BookSource, category: SourceCategory) {
        self.source = source
        self.category = category
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { operation?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = category?.title ?? "书源发现"
        view.backgroundColor = Theme.bg
        navigationItem.backButtonTitle = "分类"
        table.backgroundColor = Theme.bg
        table.separatorColor = Theme.line
        table.separatorInset = UIEdgeInsets(top: 0, left: 24, bottom: 0, right: 24)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = category == nil ? 76 : 102
        table.contentInset.bottom = 20
        table.accessibilityIdentifier = "sourceExploreTable"
        refreshControl.tintColor = Theme.accent
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        table.refreshControl = refreshControl
        view.addSubview(table)
        table.pinEdges(to: view)
        buildHeader()
        buildEmptyState()
        buildFooter()
        updateChrome()
        refresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        table.yueduFitHeader()
        table.yueduFitFooter()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        table.reloadData()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.isBeingDismissed == true {
            operation?.cancel()
            generation = UUID()
        }
    }

    private func buildHeader() {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 156))
        let eyebrow = UILabel()
        eyebrow.text = category == nil ? "A LITTLE CURIOSITY" : "STORIES TO DISCOVER"
        eyebrow.font = .yueduUI(ofSize: 10, weight: .semibold)
        eyebrow.adjustsFontForContentSizeCategory = true
        eyebrow.textColor = Theme.accent
        let heading = UILabel()
        heading.text = category?.title ?? "随兴翻阅，遇见好书。"
        heading.font = .yueduUISerif(28)
        heading.adjustsFontForContentSizeCategory = true
        heading.textColor = Theme.ink
        heading.numberOfLines = 1
        heading.adjustsFontSizeToFitWidth = true
        heading.minimumScaleFactor = 0.65
        let sourceLabel = UILabel()
        sourceLabel.text = source.bookSourceName
        sourceLabel.font = .yueduUI(ofSize: 12, weight: .medium)
        sourceLabel.adjustsFontForContentSizeCategory = true
        sourceLabel.textColor = Theme.secondary
        sourceLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .yueduUI(ofSize: 12)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = Theme.secondary
        statusLabel.numberOfLines = 2
        progress.color = Theme.accent
        progress.hidesWhenStopped = true
        for item in [eyebrow, heading, sourceLabel, statusLabel, progress] {
            header.addSubview(item)
            item.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            eyebrow.topAnchor.constraint(equalTo: header.topAnchor, constant: 17),
            eyebrow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24),
            heading.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 11),
            heading.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -24),
            sourceLabel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 9),
            sourceLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            sourceLabel.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: sourceLabel.bottomAnchor, constant: 13),
            statusLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: progress.leadingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -18),
            progress.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            progress.trailingAnchor.constraint(equalTo: heading.trailingAnchor)
        ])
        table.tableHeaderView = header
    }

    private func buildEmptyState() {
        let icon = UIImageView(image: UIImage(systemName: category == nil ? "square.grid.2x2" : "book.closed"))
        icon.tintColor = Theme.accent.withAlphaComponent(0.8)
        icon.contentMode = .scaleAspectFit
        emptyTitle.font = .yueduUISerif(21)
        emptyTitle.adjustsFontForContentSizeCategory = true
        emptyTitle.textColor = Theme.ink
        emptyTitle.textAlignment = .center
        emptyDetail.font = .yueduUI(ofSize: 13)
        emptyDetail.adjustsFontForContentSizeCategory = true
        emptyDetail.textColor = Theme.secondary
        emptyDetail.numberOfLines = 5
        emptyDetail.textAlignment = .center
        retryButton.setTitle("重新加载", for: .normal)
        retryButton.tintColor = Theme.accent
        retryButton.titleLabel?.font = .yueduUI(ofSize: 14, weight: .semibold)
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        retryButton.addTarget(self, action: #selector(refresh), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [icon, emptyTitle, emptyDetail, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        emptyPanel.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 42),
            icon.heightAnchor.constraint(equalToConstant: 42),
            stack.centerYAnchor.constraint(equalTo: emptyPanel.centerYAnchor, constant: 36),
            stack.leadingAnchor.constraint(equalTo: emptyPanel.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: emptyPanel.trailingAnchor, constant: -32),
            emptyDetail.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    private func buildFooter() {
        footer.frame.size.height = 114
        footerLabel.font = .yueduUI(ofSize: 12)
        footerLabel.adjustsFontForContentSizeCategory = true
        footerLabel.textColor = Theme.secondary
        footerLabel.numberOfLines = 2
        footerLabel.textAlignment = .center
        nextButton.tintColor = Theme.accent
        nextButton.titleLabel?.font = .yueduUI(ofSize: 14, weight: .semibold)
        nextButton.titleLabel?.adjustsFontForContentSizeCategory = true
        nextButton.backgroundColor = Theme.surface
        nextButton.layer.cornerRadius = 12
        nextButton.accessibilityIdentifier = "sourceExploreNextPage"
        nextButton.addTarget(self, action: #selector(loadNextPage), for: .touchUpInside)
        for item in [nextButton, footerLabel] {
            footer.addSubview(item)
            item.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            nextButton.topAnchor.constraint(equalTo: footer.topAnchor, constant: 16),
            nextButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 24),
            nextButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24),
            nextButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            footerLabel.topAnchor.constraint(equalTo: nextButton.bottomAnchor, constant: 10),
            footerLabel.leadingAnchor.constraint(equalTo: nextButton.leadingAnchor),
            footerLabel.trailingAnchor.constraint(equalTo: nextButton.trailingAnchor),
            footerLabel.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -18)
        ])
    }

    private func updateChrome() {
        if isBusy {
            progress.startAnimating()
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(cancel))
        } else {
            progress.stopAnimating()
            refreshControl.endRefreshing()
            navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), style: .plain, target: self, action: #selector(refresh))
            navigationItem.rightBarButtonItem?.accessibilityLabel = "刷新"
        }
        table.allowsSelection = !isBusy || (category != nil && !books.isEmpty)
        let isEmpty = category == nil ? categories.isEmpty : books.isEmpty
        table.backgroundView = isEmpty ? emptyPanel : nil
        retryButton.isHidden = isBusy || errorMessage == nil
        if isBusy {
            emptyTitle.text = category == nil ? "正在整理分类…" : "正在翻找故事…"
            emptyDetail.text = "请稍候，内容正在加载。"
        } else if let errorMessage {
            emptyTitle.text = "暂时没能打开"
            emptyDetail.text = errorMessage
        } else {
            emptyTitle.text = category == nil ? "这里暂时没有分类" : "这一页，还没有故事"
            emptyDetail.text = category == nil ? "此书源未提供发现分类，\n仍可在“发现”页搜索书名或作者。" : "可返回其他分类看看，或下拉刷新。"
        }
        if category != nil, !books.isEmpty {
            table.tableFooterView = footer
            nextButton.isHidden = !hasNextPage
            nextButton.isEnabled = !isBusy
            nextButton.setTitle(isBusy ? "正在加载…" : errorMessage == nil ? "加载下一页" : "重试加载下一页", for: .normal)
            footerLabel.text = errorMessage == nil ? hasNextPage ? "已加载第 \(page) 页 · \(books.count) 本书" : "已看完当前分类 · \(books.count) 本书" : "加载失败，已保留当前书目。"
        } else {
            table.tableFooterView = UIView(frame: .zero)
        }
    }

    @objc private func refresh() {
        if category == nil { loadCategories() }
        else { loadBooks(page: 1) }
    }

    @objc private func cancel() {
        operation?.cancel()
        operation = nil
        generation = UUID()
        isBusy = false
        statusLabel.text = hasLoaded ? "已取消 · 保留当前内容" : "已取消加载 · 点击右上角刷新"
        updateChrome()
    }

    private func begin(_ status: String) -> UUID {
        operation?.cancel()
        let token = UUID()
        generation = token
        errorMessage = nil
        isBusy = true
        statusLabel.text = status
        updateChrome()
        return token
    }

    private func loadCategories() {
        let token = begin("正在加载书源分类…")
        let source = source
        operation = Task { [weak self] in
            do {
                let values = try await SourceEngine.shared.categories(source: source)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                var seen = Set<SourceCategory>()
                self.categories = values.filter { seen.insert($0).inserted }
                self.hasLoaded = true
                self.isBusy = false
                self.statusLabel.text = self.categories.isEmpty ? "书源未提供可浏览的分类" : "\(self.categories.count) 个分类 · 选一个开始翻阅"
                self.table.reloadData()
                self.updateChrome()
            } catch is CancellationError { }
            catch { self?.handle(error, token: token) }
        }
    }

    @objc private func loadNextPage() {
        guard !isBusy, hasNextPage else { return }
        loadBooks(page: page + 1)
    }

    private func loadBooks(page requestedPage: Int) {
        guard let category else { return }
        let token = begin(requestedPage == 1 ? "正在加载分类书目…" : "正在加载第 \(requestedPage) 页…")
        let source = source
        operation = Task { [weak self] in
            do {
                let values = try await SourceEngine.shared.explore(source: source, url: category.url, page: requestedPage)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                var seen = Set(requestedPage == 1 ? [] : self.books.map(\.id))
                let additions = values.filter { seen.insert($0.id).inserted }
                if requestedPage == 1 { self.books = additions }
                else { self.books.append(contentsOf: additions) }
                self.page = requestedPage
                self.hasNextPage = !additions.isEmpty && requestedPage < 200
                self.hasLoaded = true
                self.isBusy = false
                self.statusLabel.text = "\(self.books.count) 本书 · 点击加入书架"
                self.table.reloadData()
                self.updateChrome()
            } catch is CancellationError { }
            catch { self?.handle(error, token: token) }
        }
    }

    private func handle(_ error: Error, token: UUID) {
        guard generation == token else { return }
        isBusy = false
        errorMessage = error.localizedDescription
        statusLabel.text = "加载未完成 · 可刷新重试"
        updateChrome()
        if category != nil, !books.isEmpty {
            showMessage("加载失败", error.localizedDescription)
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        category == nil ? categories.count : books.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = category == nil ? "exploreCategory" : "exploreBook"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier) ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        cell.backgroundColor = Theme.bg
        cell.textLabel?.font = .yueduUISerif(category == nil ? 19 : 18)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.textColor = Theme.ink
        cell.textLabel?.numberOfLines = 2
        cell.detailTextLabel?.font = .yueduUI(ofSize: 12)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.textColor = Theme.secondary
        cell.detailTextLabel?.numberOfLines = category == nil ? 1 : 2
        cell.accessoryType = .disclosureIndicator
        cell.imageView?.tintColor = Theme.accent
        if category == nil {
            cell.textLabel?.text = categories[indexPath.row].title
            let isHeading = categories[indexPath.row].url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            cell.detailTextLabel?.text = isHeading ? nil : "打开分类，发现新故事"
            cell.accessoryType = isHeading ? .none : .disclosureIndicator
            cell.selectionStyle = isHeading ? .none : .default
            cell.imageView?.image = UIImage(systemName: "leaf", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .light))
        } else {
            let book = books[indexPath.row]
            cell.textLabel?.text = book.title
            let saved = LibraryStore.shared.books.contains { $0.sourceID == book.sourceID && $0.bookURL == book.bookURL }
            cell.detailTextLabel?.text = book.author + (saved ? " · 已在书架，可继续阅读" : "")
                + "\n" + (book.summary.isEmpty ? "查看详情、目录与试读" : book.summary)
            cell.imageView?.image = UIImage(systemName: "book.closed.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 29, weight: .light))
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if category == nil {
            guard !isBusy else { return }
            guard !categories[indexPath.row].url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            navigationController?.pushViewController(SourceExploreViewController(source: source, category: categories[indexPath.row]), animated: true)
        } else {
            let book = books[indexPath.row]
            if isBusy { cancel() }
            let author = YueduSearchIdentity.authorKey(book.author)
            let records = books.filter {
                $0.id == book.id || (author != nil && YueduSearchIdentity.authorKey($0.author) == author
                    && YueduSearchIdentity.titleKey($0.title) == YueduSearchIdentity.titleKey(book.title))
            }
            navigationController?.pushViewController(YueduSearchBookViewController(versions: records), animated: true)
        }
    }

}
