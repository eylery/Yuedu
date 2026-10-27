import UIKit

/// Keeps the book and its source choices together, including failures and retries.
@MainActor
final class YueduSearchBookViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private enum SourceRow {
        case source(Int)
        case record(Int, Int)
    }

    private let versions: [SourceSearchResult]
    private let groups: [YueduSearchSourceGroup]
    private var expandedSources = Set<UUID>()
    private var sourceRows: [SourceRow] = []
    private let sources: [UUID: BookSource]
    private var selectedIndex = 0
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let readButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let noticeLabel = UILabel()
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var isLoading = false
    private var sourceObserver: NSObjectProtocol?
    private let choices = YueduBookChoices()
    private var previewBooks: [String: Book] = [:]
    private var previewFailures: [String: String] = [:]
    private var readyPreviews = Set<String>()
    private var isPreviewing = false

    private var selected: SourceSearchResult { versions[selectedIndex] }
    private var savedBook: Book? {
        LibraryStore.shared.books.first {
            $0.sourceID == selected.sourceID && $0.bookURL == selected.bookURL
        }
    }

    init(versions: [SourceSearchResult]) {
        precondition(!versions.isEmpty)
        groups = YueduSearchSourceGroup.grouped(versions)
        self.versions = groups.flatMap(\.records)
        sources = Dictionary(uniqueKeysWithValues: Set(versions.map(\.sourceID)).compactMap { id in
            SourceStore.shared.source(id: id).map { (id, $0) }
        })
        super.init(nibName: nil, bundle: nil)
        selectedIndex = choices.preferred(in: self.versions).flatMap { preferred in
            self.versions.firstIndex { $0.id == preferred.id }
        } ?? self.versions.firstIndex { result in
            LibraryStore.shared.books.contains {
                $0.sourceID == result.sourceID && $0.bookURL == result.bookURL
            }
        } ?? 0
        rebuildSourceRows()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "书籍详情"
        view.backgroundColor = Theme.bg
        table.backgroundColor = Theme.bg
        table.dataSource = self
        table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 76
        table.accessibilityIdentifier = "search.book.details"
        table.register(UITableViewCell.self, forCellReuseIdentifier: "YueduSearchBook")
        view.addSubview(table)

        noticeLabel.font = .yueduUI(ofSize: 13)
        noticeLabel.adjustsFontForContentSizeCategory = true
        noticeLabel.textColor = Theme.secondary
        noticeLabel.numberOfLines = 0
        noticeLabel.textAlignment = .center
        noticeLabel.accessibilityIdentifier = "search.book.status"
        readButton.accessibilityIdentifier = "search.book.read"
        readButton.addTarget(self, action: #selector(read), for: .touchUpInside)
        saveButton.accessibilityIdentifier = "search.book.save"
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [saveButton, readButton])
        buttons.distribution = .fillEqually
        buttons.spacing = 12
        buttons.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        let actions = UIStackView(arrangedSubviews: [noticeLabel, buttons])
        actions.axis = .vertical
        actions.spacing = 12
        view.addSubview(actions)
        table.translatesAutoresizingMaskIntoConstraints = false
        actions.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
            actions.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            actions.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            actions.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
        sourceObserver = NotificationCenter.default.addObserver(
            forName: .sourcesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cancelLoading()
                self.noticeLabel.text = "书源已变更，请返回重新搜索。"
                self.readButton.isEnabled = self.savedBook != nil
                self.saveButton.isEnabled = false
            }
        }
        updateActions()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        updateActions()
        table.reloadData()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.viewControllers.contains(self) == false {
            cancelLoading()
        }
    }

    deinit {
        operation?.cancel()
        if let sourceObserver { NotificationCenter.default.removeObserver(sourceObserver) }
    }

    private func updateActions() {
        let saved = savedBook != nil
        let sourceIsCurrent = sources[selected.sourceID].map {
            $0.enabled && SourceStore.shared.source(id: $0.id) == $0
        } ?? false
        var primary = UIButton.Configuration.filled()
        primary.title = isLoading ? (isPreviewing ? "正在加载试读…" : "正在加载目录…") : (saved ? "继续阅读" : "加入书架并阅读")
        primary.baseBackgroundColor = Theme.accent
        primary.baseForegroundColor = .white
        primary.cornerStyle = .medium
        primary.titleLineBreakMode = .byWordWrapping
        primary.showsActivityIndicator = isLoading
        readButton.configuration = primary
        readButton.isEnabled = !isLoading && (saved || sourceIsCurrent)
        var secondary = UIButton.Configuration.tinted()
        secondary.title = saved ? "已在书架" : "加入书架"
        secondary.baseBackgroundColor = Theme.pale
        secondary.baseForegroundColor = Theme.accent
        secondary.cornerStyle = .medium
        secondary.titleLineBreakMode = .byWordWrapping
        saveButton.configuration = secondary
        saveButton.isEnabled = !saved && !isLoading && sourceIsCurrent
        navigationItem.rightBarButtonItem = isLoading
            ? UIBarButtonItem(title: "取消加载", style: .plain, target: self, action: #selector(cancelLoading)) : nil
        if !isLoading {
            noticeLabel.text = saved ? "已保留阅读进度，打开即可继续。"
                : (sourceIsCurrent ? selectionCaption : "书源已变化，请返回重新搜索。")
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int { 3 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 1 ? sourceRows.count : 1
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? "选择书源 · \(groups.count) 个书源" : nil
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1 else { return nil }
        return groups.contains { $0.records.count > 1 }
            ? "同一书源的多条收录已归在一起，展开可切换；收录条数不代表不同版本数。"
            : "选中书源后直接阅读；加载失败时可在这里换一个书源。"
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "YueduSearchBook", for: indexPath)
        cell.backgroundColor = Theme.surface
        cell.tintColor = Theme.accent
        var content = cell.defaultContentConfiguration()
        content.textProperties.color = Theme.ink
        content.secondaryTextProperties.color = Theme.secondary
        content.secondaryTextProperties.numberOfLines = 0
        cell.accessibilityHint = nil
        if indexPath.section == 2 {
            content.text = isPreviewing ? "正在获取目录与首章…" : "目录与首章试读"
            content.textProperties.font = .yueduUI(ofSize: 16, weight: .semibold)
            var detail = "点击查看章节数量、目录摘要和首章正文，试读不会加入书架。"
            if let preview = previewBooks[selected.id] {
                detail = "共 \(preview.chapters.count) 章 · 末章：\(preview.chapters.last?.title ?? "")\n\n"
                    + preview.chapters.prefix(5).map(\.title).joined(separator: "\n")
                if let chapter = preview.chapters.first, chapter.hasCachedContent {
                    detail += "\n\n首章试读\n" + String(chapter.content.prefix(1800))
                }
            }
            if let failure = previewFailures[selected.id] { detail += "\n\n上次加载失败：\(failure)\n点击重试，或选择其他收录。" }
            content.secondaryText = detail
            cell.accessibilityIdentifier = "search.book.preview"
            cell.accessibilityValue = readyPreviews.contains(selected.id) ? "试读已就绪" : "未试读"
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        } else if indexPath.section == 0 {
            content.text = YueduSearchIdentity.title(selected.title)
            content.textProperties.font = .yueduUISerif(26)
            content.textProperties.numberOfLines = 0
            content.secondaryText = YueduSearchIdentity.author(selected.author) + "\n\n" + (selected.summary.isEmpty ? "暂无简介" : selected.summary)
            content.secondaryTextProperties.font = .yueduUI(ofSize: 15)
            content.directionalLayoutMargins.top = 24
            content.directionalLayoutMargins.bottom = 24
            cell.accessoryType = .none
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = "search.book.summary"
            cell.accessibilityValue = nil
        } else {
            switch sourceRows[indexPath.row] {
            case .source(let groupIndex):
                let group = groups[groupIndex]
                let isSelected = selected.sourceID == group.sourceID
                let record = isSelected ? selected : group.records[0]
                content.text = group.sourceName
                content.textProperties.font = .yueduUI(ofSize: 16, weight: .medium)
                var details = [URL(string: record.bookURL)?.host ?? "在线书源"]
                if group.records.count > 1 {
                    let expanded = expandedSources.contains(group.sourceID)
                    details.append("\(group.records.count) 条收录 · " + (expanded ? "收起" : "展开选择"))
                    if isSelected, let index = group.records.firstIndex(where: { $0.id == selected.id }) {
                        details.append("已选收录 \(index + 1)")
                    }
                }
                if let saved = savedBook(for: record) {
                    details.append("已在书架 · \(saved.currentChapterTitle)")
                }
                if previewFailures[record.id] != nil { details.append("上次加载失败") }
                else if let preview = previewBooks[record.id] { details.append("已获取目录 · \(preview.chapters.count) 章") }
                content.secondaryText = details.joined(separator: " · ")
                cell.accessoryType = isSelected ? .checkmark : .none
                cell.accessibilityIdentifier = "search.book.source.\(group.sourceName)"
                cell.accessibilityValue = isSelected ? "已选择" : "未选择"
                cell.accessibilityHint = group.records.count > 1 ? "展开或收起此书源的收录记录" : "选择此书源"
            case .record(let groupIndex, let recordIndex):
                let record = groups[groupIndex].records[recordIndex]
                content.text = "收录 \(recordIndex + 1)"
                content.textProperties.font = .yueduUI(ofSize: 15, weight: .medium)
                content.secondaryText = recordDescription(record)
                content.secondaryTextProperties.font = .yueduUI(ofSize: 13)
                content.directionalLayoutMargins.leading = 36
                cell.backgroundColor = Theme.pale.withAlphaComponent(0.45)
                cell.accessoryType = record.id == selected.id ? .checkmark : .none
                cell.accessibilityIdentifier = "search.book.record.\(record.sourceName).\(recordIndex + 1)"
                cell.accessibilityValue = record.id == selected.id ? "已选择" : "未选择"
                cell.accessibilityHint = "选择这条收录后可加入书架或阅读"
            }
            cell.selectionStyle = .default
        }
        cell.contentConfiguration = content
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        if indexPath.section == 2 { preview(); return }
        guard indexPath.section == 1 else { return }
        switch sourceRows[indexPath.row] {
        case .source(let groupIndex):
            let group = groups[groupIndex]
            if group.records.count == 1 && selected.sourceID == group.sourceID { return }
            if selected.sourceID != group.sourceID {
                let preferred = choices.preferred(in: group.records)
                    ?? group.records.first { savedBook(for: $0) != nil } ?? group.records[0]
                select(preferred)
            }
            if group.records.count > 1 {
                if !expandedSources.insert(group.sourceID).inserted {
                    expandedSources.remove(group.sourceID)
                }
            }
        case .record(let groupIndex, let recordIndex):
            let record = groups[groupIndex].records[recordIndex]
            guard record.id != selected.id else { return }
            select(record)
        }
        rebuildSourceRows()
        updateActions()
        tableView.reloadData()
    }

    private func select(_ result: SourceSearchResult) {
        guard result.id != selected.id,
              let index = versions.firstIndex(where: { $0.id == result.id }) else { return }
        cancelLoading()
        selectedIndex = index
        choices.remember(result)
    }

    private func rebuildSourceRows() {
        sourceRows = groups.indices.flatMap { index -> [SourceRow] in
            let group = groups[index]
            let children: [SourceRow] = expandedSources.contains(group.sourceID)
                ? group.records.indices.map { .record(index, $0) } : []
            return [.source(index)] + children
        }
    }

    private var selectionCaption: String {
        guard let group = groups.first(where: { $0.sourceID == selected.sourceID }),
              group.records.count > 1,
              let index = group.records.firstIndex(where: { $0.id == selected.id }) else {
            return "已选：\(selected.sourceName)"
        }
        return "已选：\(selected.sourceName) · 收录 \(index + 1)"
    }

    private func savedBook(for result: SourceSearchResult) -> Book? {
        LibraryStore.shared.books.first {
            $0.sourceID == result.sourceID && $0.bookURL == result.bookURL
        }
    }

    private func recordDescription(_ result: SourceSearchResult) -> String {
        var lines = ["作者标注：\(result.author)"]
        if let failure = previewFailures[result.id] { lines.append("上次加载失败：\(failure)") }
        if let preview = previewBooks[result.id] {
            lines.append("已获取目录 · \(preview.chapters.count) 章 · 末章：\(preview.chapters.last?.title ?? "")")
            if preview.chapters.first?.hasCachedContent == true { lines.append("首章试读可用") }
        }
        let fields = [("kind", "分类"), ("wordCount", "字数"), ("lastChapter", "最新章节")]
        for (key, label) in fields {
            if let value = result.context?[key]?.scalarString?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                lines.append("\(label)：\(value)")
            }
        }
        if let saved = savedBook(for: result) {
            lines.append("已在书架 · \(saved.chapters.count) 章 · \(saved.currentChapterTitle)")
        } else if !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(String(result.summary.prefix(120)))
        } else if lines.count == 1 {
            lines.append("书源未提供版本说明，可选中后尝试阅读。")
        }
        return lines.joined(separator: "\n")
    }

    @objc private func read() { load(read: true) }
    @objc private func save() { load(read: false) }

    @objc private func cancelLoading() {
        operation?.cancel()
        operation = nil
        generation = UUID()
        isLoading = false
        isPreviewing = false
        updateActions()
    }

    private func load(read: Bool) {
        guard !isLoading else { return }
        if let saved = savedBook {
            if read { openReader(saved) }
            return
        }
        let result = selected
        guard let source = sources[result.sourceID], source.enabled,
              SourceStore.shared.source(id: source.id) == source else {
            noticeLabel.text = "此书源已变化，请返回重新搜索或选择其他版本。"
            return
        }
        isLoading = true
        updateActions()
        noticeLabel.text = "正在获取目录，可取消或选择其他书源。"
        let token = UUID()
        generation = token
        operation = Task { [weak self] in
            do {
                let book: Book
                if let preview = self?.previewBooks[result.id] { book = preview }
                else { book = try await SourceEngine.shared.loadBook(result, source: source, timeout: 20) }
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                guard SourceStore.shared.source(id: source.id) == source else {
                    throw SourceError.invalid("书源已变化，请返回重新搜索。")
                }
                let saved = LibraryStore.shared.add(book)
                if let error = LibraryStore.shared.persistenceError {
                    throw SourceError.invalid(error)
                }
                self.isLoading = false
                self.previewFailures[result.id] = nil
                self.choices.remember(result)
                self.operation = nil
                self.updateActions()
                self.table.reloadData()
                self.noticeLabel.text = "已加入书架 · \(saved.chapters.count) 章"
                if read { self.openReader(saved) }
            } catch {
                guard let self, self.generation == token else { return }
                self.isLoading = false
                if !Task.isCancelled { self.previewFailures[result.id] = error.localizedDescription }
                self.operation = nil
                self.updateActions()
                self.noticeLabel.text = "加载失败：\(error.localizedDescription)\n可再次点击重试，或选择其他书源。"
                self.table.reloadData()
            }
        }
    }

    private func preview() {
        guard !isLoading, let source = sources[selected.sourceID], source.enabled,
              SourceStore.shared.source(id: source.id) == source else { return }
        let result = selected
        if readyPreviews.contains(result.id) { return }
        isLoading = true
        isPreviewing = true
        updateActions()
        table.reloadData()
        let token = UUID()
        generation = token
        operation = Task { [weak self] in
            do {
                var book: Book
                if let existing = self?.previewBooks[result.id] ?? self?.savedBook(for: result) { book = existing }
                else { book = try await SourceEngine.shared.loadBook(result, source: source, timeout: 20) }
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                if self.previewBooks.count >= 8 { self.previewBooks.removeAll(); self.readyPreviews.removeAll() }
                self.previewBooks[result.id] = book
                guard let first = book.chapters.first else { throw SourceError.empty("目录为空。") }
                let text: String
                if first.hasCachedContent, let cached = try? await first.body.readAsync() { text = cached }
                else { text = try await SourceEngine.shared.loadChapter(first, source: source, book: book, timeout: 15) }
                try Task.checkCancellation()
                guard self.generation == token, SourceStore.shared.source(id: source.id) == source else { return }
                book.chapters[0].content = text
                self.previewBooks[result.id] = book
                self.readyPreviews.insert(result.id)
                self.previewFailures[result.id] = nil
                self.isLoading = false
                self.isPreviewing = false
                self.operation = nil
                self.updateActions()
                self.noticeLabel.text = "试读已就绪，满意后可加入书架。"
                self.table.reloadData()
                self.table.layoutIfNeeded()
                self.table.scrollToRow(at: IndexPath(row: 0, section: 2), at: .top, animated: true)
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.previewFailures[result.id] = error.localizedDescription
                self.isLoading = false
                self.isPreviewing = false
                self.operation = nil
                self.updateActions()
                self.noticeLabel.text = "试读失败，可点击试读重试或换一条收录。"
                self.table.reloadData()
            }
        }
    }

    private func openReader(_ book: Book) {
        navigationController?.pushViewController(ReaderViewController(bookID: book.id), animated: true)
    }
}
