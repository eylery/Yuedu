import UIKit

@MainActor
final class YueduCacheViewController: UITableViewController, UISearchResultsUpdating {
    private enum Filter: String, CaseIterable {
        case all = "全部", cached = "已缓存", missing = "未缓存完整", tasks = "有下载任务", failed = "有失败章节"
    }

    private let bookID: UUID?
    private let library = LibraryStore.shared
    private let manager = YueduDownloadManager.shared
    private let search = UISearchController(searchResultsController: nil)
    private var filter: Filter = .all
    private var sizeFirst = true
    private var books: [Book] = []
    private var chapters: [Int] = []
    private var selectedIDs = Set<UUID>()
    private var observers: [NSObjectProtocol] = []
    private var notice: String?
    private var book: Book? { bookID.flatMap { library.book(id: $0) } }

    init(bookID: UUID? = nil) {
        self.bookID = bookID
        super.init(style: .insetGrouped)
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = bookID == nil ? "缓存管理" : "本书缓存"
        tableView.backgroundColor = Theme.bg
        tableView.accessibilityIdentifier = "cache.list"
        tableView.allowsMultipleSelectionDuringEditing = true
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = bookID == nil ? "搜索书名或书源" : "搜索章节名或序号"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        for name in [Notification.Name.libraryChanged, .yueduDownloadsChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard self?.viewIfLoaded?.window != nil else { return }
                    self?.render()
                }
            })
        }
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        navigationController?.setToolbarHidden(!isEditing, animated: animated)
        render()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func updateSearchResults(for searchController: UISearchController) {
        selectedIDs.removeAll()
        render()
    }

    private func render() {
        guard isViewLoaded else { return }
        if bookID != nil && book == nil {
            chapters = []
            selectedIDs.removeAll()
            tableView.reloadData()
            return
        }
        let query = search.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let book {
            let failed = manager.failedChapterIDs(bookID: book.id)
            chapters = book.chapters.indices.filter { index in
                let chapter = book.chapters[index]
                guard query.isEmpty || chapter.title.localizedCaseInsensitiveContains(query) || String(index + 1) == query else { return false }
                switch filter {
                case .all: return true
                case .cached: return !chapter.content.isEmpty
                case .missing: return chapter.content.isEmpty
                case .failed: return failed.contains(chapter.id)
                case .tasks: return manager.taskBookIDs.contains(book.id)
                }
            }
            selectedIDs.formIntersection(chapters.map { book.chapters[$0].id })
        } else {
            books = library.books.filter { book in
                guard book.supportsCacheManagement,
                      query.isEmpty || book.title.localizedCaseInsensitiveContains(query) || book.sourceName.localizedCaseInsensitiveContains(query) else { return false }
                switch filter {
                case .all: return true
                case .cached: return book.cacheSummary.chapters > 0
                case .missing: return book.cacheSummary.chapters < book.chapters.count
                case .tasks: return manager.taskBookIDs.contains(book.id)
                case .failed: return !manager.failedChapterIDs(bookID: book.id).isEmpty
                }
            }.sorted {
                if sizeFirst, $0.cacheSummary.bytes != $1.cacheSummary.bytes { return $0.cacheSummary.bytes > $1.cacheSummary.bytes }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            selectedIDs.formIntersection(books.map(\.id))
        }
        updateButtons()
        tableView.reloadData()
        for row in 0..<dataCount where selectedIDs.contains(id(at: row)) {
            tableView.selectRow(at: IndexPath(row: row, section: 2), animated: false, scrollPosition: .none)
        }
    }

    private var dataCount: Int { bookID == nil ? books.count : chapters.count }
    private func id(at row: Int) -> UUID { book.map { $0.chapters[chapters[row]].id } ?? books[row].id }

    private func updateButtons() {
        let edit = UIBarButtonItem(title: isEditing ? "完成" : "选择", style: .plain, target: self, action: #selector(toggleSelection))
        edit.accessibilityIdentifier = "cache.select"
        if isEditing {
            let all = UIBarButtonItem(title: "全选", style: .plain, target: self, action: #selector(selectAllCacheItems))
            all.accessibilityIdentifier = "cache.selectAll"
            navigationItem.rightBarButtonItems = [edit, all]
        } else {
            var actions: [UIMenuElement] = Filter.allCases.filter { bookID == nil || $0 != .tasks }.map { value in
                UIAction(title: value.rawValue, state: value == filter ? .on : .off) { [weak self] _ in
                    self?.filter = value
                    self?.selectedIDs.removeAll()
                    self?.render()
                }
            }
            if bookID == nil {
                actions.append(UIAction(title: "按缓存大小排序", state: sizeFirst ? .on : .off) { [weak self] _ in
                    self?.sizeFirst.toggle()
                    self?.render()
                })
            }
            let options = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease.circle"), menu: UIMenu(children: actions))
            options.accessibilityLabel = "缓存筛选与排序"
            navigationItem.rightBarButtonItems = [edit, options]
        }
        let download = UIBarButtonItem(title: "缓存所选", style: .plain, target: self, action: #selector(downloadSelected))
        let pause = UIBarButtonItem(title: "暂停任务", style: .plain, target: self, action: #selector(pauseSelected))
        let clear = UIBarButtonItem(title: "清理所选", style: .plain, target: self, action: #selector(clearSelected))
        download.accessibilityIdentifier = "cache.downloadSelected"
        clear.accessibilityIdentifier = "cache.clearSelected"
        for button in [download, pause, clear] { button.isEnabled = !selectedIDs.isEmpty }
        toolbarItems = [download, .flexibleSpace(), pause, .flexibleSpace(), clear]
        tableView.headerView(forSection: 2)?.textLabel?.text = tableView(tableView, titleForHeaderInSection: 2)
    }

    @objc private func toggleSelection() {
        selectedIDs.removeAll()
        setEditing(!isEditing, animated: true)
        navigationController?.setToolbarHidden(!isEditing, animated: true)
        render()
    }

    @objc private func selectAllCacheItems() {
        selectedIDs = Set((0..<dataCount).map(id(at:)))
        render()
    }

    @objc private func downloadSelected() {
        if let bookID {
            start(chapterIDs: selectedIDs, bookID: bookID)
        } else {
            for id in selectedIDs { manager.start(bookID: id) }
        }
    }

    @objc private func pauseSelected() {
        for id in bookID.map({ Set([$0]) }) ?? selectedIDs { manager.pause(bookID: id) }
    }

    @objc private func clearSelected() {
        if let bookID { confirmClear(ids: [bookID], cleanup: .chapters(selectedIDs), title: "清理所选章节缓存") }
        else { confirmClear(ids: selectedIDs, cleanup: .all, title: "清理所选书籍缓存") }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { bookID != nil && book == nil ? 0 : 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return 1 }
        if section == 1 { return bookID == nil ? 2 : 8 }
        return dataCount
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 { return "正文缓存" }
        if section == 1 { return "下载与清理" }
        return "\(filter.rawValue) · \(dataCount) \(bookID == nil ? "本" : "章")\(isEditing ? " · 已选 \(selectedIDs.count)" : "")"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            return [notice, manager.queueError, "大小按正文 UTF-8 估算，不含目录、数据库开销和系统缓存。本地导入书与示例书不参与清理。"]
                .compactMap { $0 }.joined(separator: "\n")
        }
        if section == 1 {
            return "已缓存章节自动跳过；暂停后可按原范围继续。重新选择范围或仅重试失败会替换原任务范围。普通网页支持后台传输，脚本、登录和解析需回到前台。清理会先取消该书任务；仅删除正文，保留目录、进度、书签和书架设置。"
        }
        return dataCount == 0 ? "没有符合条件的\(bookID == nil ? "在线书籍" : "章节")，请调整搜索或筛选。" : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        cell.tintColor = Theme.accent
        var content = cell.defaultContentConfiguration()
        content.textProperties.color = Theme.ink
        content.textProperties.numberOfLines = 2
        content.secondaryTextProperties.color = Theme.secondary
        content.secondaryTextProperties.numberOfLines = 0
        if indexPath.section == 0 {
            let targets = book.map { [$0] } ?? library.books.filter(\.supportsCacheManagement)
            let summary = targets.reduce(into: YueduCacheSummary()) { value, book in
                value.chapters += book.cacheSummary.chapters
                value.bytes += book.cacheSummary.bytes
            }
            content.text = "\(summary.size) · 已缓存 \(summary.chapters) 章"
            if let book {
                let state = manager.status(for: book.id)
                content.secondaryText = "\(book.title) · \(book.sourceName)\n目录 \(book.chapters.count) 章\n"
                    + (state.map { "\($0.message)\n任务范围：\($0.completed)/\($0.total) 章已缓存 · \($0.failedCount) 章失败" } ?? "尚无下载任务")
            } else {
                let spool = ByteCountFormatter.string(fromByteCount: Int64(YueduBackgroundTransfer.shared.spooledBytes), countStyle: .file)
                content.secondaryText = "\(targets.count) 本在线书籍 · \(manager.taskBookIDs.count) 个下载任务\n待解析下载文件：\(spool)（取消相关任务会清除）"
            }
            cell.accessibilityIdentifier = "cache.summary"
            cell.selectionStyle = .none
        } else if indexPath.section == 1 {
            if let book {
                let running = manager.status(for: book.id)?.isRunning == true
                content.text = ["缓存全书", "缓存后续 50 章", "指定范围缓存", running ? "暂停本书任务" : "继续原范围",
                                "仅重试失败章节", "取消本书任务", "清理已读章节", "清理本书全部缓存"][indexPath.row]
                if indexPath.row == 4 { content.secondaryText = "\(manager.failedChapterIDs(bookID: book.id).count) 章失败 · 不重下成功章节" }
                if indexPath.row == 6 { content.secondaryText = "保留当前章、后续章节和书签所在章节" }
            } else { content.text = indexPath.row == 0 ? "暂停全部任务" : "继续已暂停任务" }
            cell.accessibilityIdentifier = "cache.action.\(indexPath.row)"
            cell.accessoryType = .disclosureIndicator
        } else if let book {
            let index = chapters[indexPath.row]
            let chapter = book.chapters[index]
            let failed = manager.failedChapterIDs(bookID: book.id).contains(chapter.id)
            content.text = "\(index + 1). \(chapter.title)"
            content.secondaryText = chapter.content.isEmpty ? (failed ? "下载失败 · 可重试" : "未缓存")
                : "已缓存 · \(ByteCountFormatter.string(fromByteCount: Int64(chapter.content.utf8.count), countStyle: .file))"
            if index == book.progress.chapterIndex { content.secondaryText! += " · 当前章" }
            cell.accessibilityIdentifier = "cache.chapter.\(index)"
            cell.accessoryType = .disclosureIndicator
        } else {
            let book = books[indexPath.row]
            content.text = book.title
            content.secondaryText = "\(book.sourceName) · \(book.cacheSummary.chapters)/\(book.chapters.count) 章 · \(book.cacheSummary.size)"
                + (manager.status(for: book.id).map { "\n\($0.message)" } ?? "")
            cell.accessibilityIdentifier = "cache.book.\(book.id)"
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { indexPath.section == 2 }
    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        isEditing && indexPath.section == 2 ? .delete : .none
    }
    override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }

    override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        if isEditing, indexPath.section == 2 { selectedIDs.remove(id(at: indexPath.row)); updateButtons() }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if isEditing, indexPath.section == 2 {
            selectedIDs.insert(id(at: indexPath.row))
            updateButtons()
            return
        }
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 { action(indexPath.row) }
        if indexPath.section == 2 {
            if let book { showChapter(book: book, index: chapters[indexPath.row], cell: tableView.cellForRow(at: indexPath)) }
            else { navigationController?.pushViewController(YueduCacheViewController(bookID: books[indexPath.row].id), animated: true) }
        }
    }

    private func action(_ row: Int) {
        guard let book else {
            if row == 0 { manager.pauseAll() } else { manager.resumeAll() }
            return
        }
        switch row {
        case 0: start(chapterIDs: Set(book.chapters.map(\.id)), bookID: book.id)
        case 1: start(chapterIDs: Set(book.chapters.dropFirst(book.progress.chapterIndex).prefix(50).map(\.id)), bookID: book.id)
        case 2: chooseRange(book)
        case 3:
            if manager.status(for: book.id)?.isRunning == true { manager.pause(bookID: book.id) }
            else if manager.canResume(bookID: book.id) { manager.resume(bookID: book.id) }
            else { showMessage("暂无暂停任务", "可选择全书、后续章节或指定范围开始缓存。") }
        case 4:
            if manager.status(for: book.id)?.isRunning == true { showMessage("任务仍在进行", "请先暂停，再单独重试失败章节。") }
            else if manager.failedChapterIDs(bookID: book.id).isEmpty { showMessage("暂无失败章节", "可以选择未缓存章节或指定范围下载。") }
            else { manager.resume(bookID: book.id, failuresOnly: true) }
        case 5:
            do { try manager.cancel(bookIDs: [book.id]) }
            catch { showMessage("未能取消", error.localizedDescription) }
        case 6: confirmClear(ids: [book.id], cleanup: .read, title: "清理已读章节缓存")
        default: confirmClear(ids: [book.id], cleanup: .all, title: "清理本书全部缓存")
        }
    }

    private func start(chapterIDs: Set<UUID>, bookID: UUID) {
        guard manager.status(for: bookID)?.isRunning != true else {
            showMessage("任务仍在进行", "请先暂停，再选择新的缓存范围。")
            return
        }
        manager.start(bookID: bookID, chapterIDs: chapterIDs)
    }

    private func chooseRange(_ book: Book) {
        let alert = UIAlertController(title: "指定范围缓存", message: "按目录位置输入第 1–\(book.chapters.count) 章，包含起止章节。", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "起始章"; $0.keyboardType = .numberPad; $0.text = String(book.progress.chapterIndex + 1) }
        alert.addTextField { $0.placeholder = "结束章"; $0.keyboardType = .numberPad; $0.text = String(min(book.chapters.count, book.progress.chapterIndex + 50)) }
        alert.addAction(UIAlertAction(title: "开始缓存", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            guard let first = Int(alert?.textFields?[0].text ?? ""), let last = Int(alert?.textFields?[1].text ?? ""),
                  first >= 1, last >= first, last <= book.chapters.count else {
                self.showMessage("范围无效", "请输入有效的起止章序号。")
                return
            }
            self.start(chapterIDs: Set(book.chapters[(first - 1)..<last].map(\.id)), bookID: book.id)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showChapter(book: Book, index: Int, cell: UITableViewCell?) {
        let chapter = book.chapters[index]
        let alert = UIAlertController(title: chapter.title, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "阅读本章", style: .default) { [weak self] _ in
            self?.library.updateProgress(bookID: book.id, chapterIndex: index, scrollFraction: 0)
            self?.navigationController?.pushViewController(ReaderViewController(bookID: book.id), animated: true)
        })
        alert.addAction(UIAlertAction(title: "缓存本章", style: .default) { [weak self] _ in self?.start(chapterIDs: [chapter.id], bookID: book.id) })
        if !chapter.content.isEmpty {
            alert.addAction(UIAlertAction(title: "清理本章缓存", style: .destructive) { [weak self] _ in
                self?.confirmClear(ids: [book.id], cleanup: .chapters([chapter.id]), title: "清理本章缓存")
            })
        }
        if manager.failedChapterIDs(bookID: book.id).contains(chapter.id) {
            alert.message = "本书最近失败记录（最多 30 条）：\n" + (manager.status(for: book.id)?.failures.joined(separator: "\n") ?? "")
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.sourceView = cell ?? view
        alert.popoverPresentationController?.sourceRect = cell?.bounds ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(alert, animated: true)
    }

    private func confirmClear(ids: Set<UUID>, cleanup: YueduCacheCleanup, title: String) {
        var summary = YueduCacheSummary()
        for id in ids {
            let chapterIDs = library.cacheChapterIDs(bookID: id, cleanup: cleanup)
            for chapter in library.book(id: id)?.chapters ?? [] where chapterIDs.contains(chapter.id) {
                summary.chapters += 1
                summary.bytes += chapter.content.utf8.count
            }
        }
        let alert = UIAlertController(title: title, message: "将清理 \(summary.chapters) 章，约 \(summary.size)，并取消相关书籍的下载任务。\n目录、进度与书签保留。再次阅读需要可用书源和网络；源已失效的正文请先备份。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "清理缓存", style: .destructive) { [weak self] _ in
            do {
                guard let self else { return }
                let removed = try self.manager.clearCache(bookIDs: ids, cleanup: cleanup)
                self.notice = "已清理 \(removed.chapters) 章 · \(removed.size)"
                self.selectedIDs.removeAll()
                self.render()
            } catch { self?.showMessage("未能清理", error.localizedDescription) }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}
