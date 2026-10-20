import UIKit

final class YueduBookDetailViewController: UITableViewController {
    private let bookID: UUID
    private var operation: Task<Void, Never>?
    private var updating = false
    private var notice: String?
    private var observers: [NSObjectProtocol] = []
    private var book: Book? { LibraryStore.shared.book(id: bookID) }

    init(bookID: UUID) {
        self.bookID = bookID
        super.init(style: .insetGrouped)
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "书籍详情"
        tableView.backgroundColor = Theme.bg
        tableView.accessibilityIdentifier = "bookDetail.list"
        for name in [Notification.Name.libraryChanged, .yueduDownloadsChanged] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.tableView.reloadData() }
            })
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        tableView.reloadData()
    }

    deinit {
        operation?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { book == nil ? 0 : 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return 1 }
        if section == 1 { return 2 }
        return book?.sourceID == nil ? 0 : 5
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? "阅读" : section == 2 && book?.sourceID != nil ? "在线与离线" : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 2, book?.sourceID != nil {
            let state = YueduDownloadManager.shared.status(for: bookID)
            return [notice, state?.message, "普通章节支持系统后台下载，返回应用后自动解析。脚本、登录或网页验证等请求需要保持前台。任务队列会保存；手动强制退出后需重新打开应用续传。单章 8 MB，单本正文 100 MB，待解析文件最多 200 MB，达到后等待前台处理。"]
                .compactMap { $0 }.joined(separator: "\n\n")
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard let book else { return cell }
        var content = cell.defaultContentConfiguration()
        content.textProperties.color = Theme.ink
        content.secondaryTextProperties.color = Theme.secondary
        content.secondaryTextProperties.numberOfLines = 0
        cell.backgroundColor = Theme.surface
        cell.tintColor = Theme.accent
        cell.accessoryType = .disclosureIndicator
        if indexPath.section == 0 {
            content.text = book.title
            content.textProperties.font = .readingSerif(24)
            content.secondaryText = "\(book.author) · \(book.sourceName)\n\(book.chapters.count) 章 · 已缓存 \(book.cachedChapterCount) 章\n\n\(book.summary)"
            cell.accessoryType = .none
            cell.selectionStyle = .none
        } else if indexPath.section == 1 {
            content.text = indexPath.row == 0 ? "继续阅读" : "目录与书签"
            content.secondaryText = indexPath.row == 0 ? "\(book.currentChapterTitle) · \(Int(book.fractionRead * 100))%" : "搜索章节、查看离线状态、跳转阅读"
            content.image = UIImage(systemName: indexPath.row == 0 ? "book" : "list.bullet")
            cell.accessibilityIdentifier = indexPath.row == 0 ? "bookDetail.read" : "bookDetail.contents"
        } else {
            let running = YueduDownloadManager.shared.status(for: bookID)?.isRunning == true
            let titles = [updating ? "正在更新目录…" : "更新目录", "换源续读",
                          "缓存全书", "缓存后续 50 章", running ? "暂停缓存" : "查看缓存情况"]
            let symbols = ["arrow.clockwise", "arrow.triangle.2.circlepath", "arrow.down.circle",
                           "text.badge.plus", running ? "pause.circle" : "info.circle"]
            content.text = titles[indexPath.row]
            content.image = UIImage(systemName: symbols[indexPath.row])
            content.secondaryText = indexPath.row == 1 ? "查找同名书籍，匹配续读章节；保留原书" : nil
            cell.accessibilityIdentifier = "bookDetail.online.\(indexPath.row)"
            if updating || (running && indexPath.row < 4) {
                content.textProperties.color = Theme.secondary
                cell.selectionStyle = .none
            }
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let book else { return }
        if indexPath.section == 1 {
            if indexPath.row == 0 { openReader() }
            else {
                let contents = ReaderContentsViewController(
                    book: book, currentChapter: book.progress.chapterIndex, bookmarksSelected: false
                )
                contents.onSelect = { [weak self] index, fraction in
                    LibraryStore.shared.updateProgress(bookID: book.id, chapterIndex: index, scrollFraction: fraction)
                    self?.openReader()
                }
                present(UINavigationController(rootViewController: contents), animated: true)
            }
        } else if indexPath.section == 2 {
            let manager = YueduDownloadManager.shared
            let running = manager.status(for: bookID)?.isRunning == true
            guard !updating, !running || indexPath.row == 4 else { return }
            switch indexPath.row {
            case 0: refreshCatalog()
            case 1:
                navigationController?.pushViewController(
                    OnlineSearchViewController(switchingBookID: book.id), animated: true
                )
            case 2: manager.start(bookID: bookID)
            case 3: manager.start(bookID: bookID, startIndex: book.progress.chapterIndex, limit: 50)
            default:
                if running { manager.pause(bookID: bookID) }
                else {
                    let state = manager.status(for: bookID)
                    showMessage("缓存情况", "\(book.cachedChapterCount)/\(book.chapters.count) 章可离线阅读。\n\n"
                        + (state?.message ?? "尚未开始批量缓存")
                        + (state?.failures.isEmpty == false ? "\n\n" + state!.failures.joined(separator: "\n") : ""))
                }
            }
        }
    }

    private func openReader() {
        navigationController?.pushViewController(ReaderViewController(bookID: bookID), animated: true)
    }

    private func refreshCatalog() {
        guard let result = book?.searchResult else { return }
        updating = true
        notice = nil
        tableView.reloadData()
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "取消更新", primaryAction: UIAction { [weak self] _ in
            self?.operation?.cancel()
        })
        operation = Task { [weak self] in
            do {
                let fetched = try await SourceEngine.shared.loadBook(result)
                try Task.checkCancellation()
                guard let self else { return }
                let added = try LibraryStore.shared.refreshCatalog(bookID: self.bookID, fetched: fetched)
                self.notice = added == 0 ? "目录已是最新，进度与缓存已保留。" : "目录更新完成 · 新增 \(added) 章，进度与缓存已保留。"
            } catch {
                guard let self else { return }
                self.notice = Task.isCancelled ? "已取消更新，原目录未改动。" : "更新失败：\(error.localizedDescription)"
            }
            self?.updating = false
            self?.navigationItem.rightBarButtonItem = nil
            self?.tableView.reloadData()
        }
    }
}
