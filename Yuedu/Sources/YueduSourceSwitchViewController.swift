import UIKit

@MainActor
final class YueduSourceSwitchViewController: UITableViewController {
    private let original: Book
    private let candidate: Book
    private let source: BookSource
    private let alreadySaved: Bool
    private let resumeProgress: ReadingProgress
    private let match: YueduSourceSwitch.Match?
    private let bookmarkMapping: [Int: Int]
    private var selectedIndex: Int?
    private var preserveFraction: Bool
    private var copyBookmarks: Bool
    private var verifiedText: String?
    private var status = "先试读所选章节，确认正文可用后再换源。"
    private var task: Task<Void, Never>?
    private var token = UUID()
    private var loading = false
    private var sourceInvalid = false
    private var observer: NSObjectProtocol?

    init(original: Book, candidate: Book, source: BookSource, alreadySaved: Bool,
         resumeProgress: ReadingProgress? = nil) {
        self.original = original
        self.candidate = candidate
        self.source = source
        self.alreadySaved = alreadySaved
        let progress = resumeProgress ?? original.progress
        self.resumeProgress = progress
        let mapping = YueduSourceSwitch.bookmarkMapping(from: original, to: candidate)
        bookmarkMapping = mapping
        let proposed = original.chapters.indices.contains(progress.chapterIndex)
            ? YueduSourceSwitch.match(original.chapters[progress.chapterIndex], in: candidate.chapters) : nil
        match = proposed.flatMap { mapping[progress.chapterIndex] == $0.index ? $0 : nil }
        selectedIndex = match?.index
        preserveFraction = match != nil
        copyBookmarks = YueduSourceSwitch.metadataAgrees(original, candidate)
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "换源对比"
        tableView.backgroundColor = Theme.bg
        tableView.accessibilityIdentifier = "sourceSwitch.list"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "确认换源", style: .done, target: self, action: #selector(confirm))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "sourceSwitch.confirm"
        observer = NotificationCenter.default.addObserver(forName: .sourcesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, SourceStore.shared.source(id: self.source.id) != self.source else { return }
                self.cancelPreview()
                self.sourceInvalid = true
                self.verifiedText = nil
                self.status = "书源已修改或停用，请返回重新搜索。"
                self.render()
            }
        }
        render()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.viewControllers.contains(self) == false { cancelPreview() }
    }

    deinit {
        task?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func render() {
        navigationItem.rightBarButtonItem?.isEnabled = verifiedText != nil && !loading && !sourceInvalid
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 4 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 2
        case 1: return 2
        case 2: return verifiedText == nil ? 1 : 2
        default: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["版本信息", "续读位置", "正文试读", "书架与书签"][section]
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0:
            return YueduSourceSwitch.metadataAgrees(original, candidate)
                ? "书名与作者请以正文为准；章节总数受拆章、合章影响。"
                : "书名或作者不一致、作者不明，请核对试读正文是否同一作品；书签默认不复制。"
        case 1:
            let title = original.chapters.indices.contains(resumeProgress.chapterIndex)
                ? original.chapters[resumeProgress.chapterIndex].title : "未选择章节"
            return "原位置：\(title) · 章内 \(Int(resumeProgress.scrollFraction * 100))%\n不同版本的排版可能不同，章内比例仅为近似位置；手动选章默认从章首开始。"
        case 2: return status
        default:
            let marks = LibraryStore.shared.bookmarks.filter { $0.bookID == original.id }
            let matched = marks.filter { bookmarkMapping[$0.chapterIndex] != nil }.count
            return "可匹配 \(matched)/\(marks.count) 个书签；未匹配书签留在原版本。\n"
                + (alreadySaved ? "此版本已在书架，使用已保存的目录与缓存；确认后更新续读位置，保留此版本的分组和追更设置。"
                   : "新版本继承分组、阅读状态、置顶和追更开关。")
                + "\n原版本及其进度、书签、缓存均保留，可从书籍详情的「已保存版本」返回。"
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        cell.tintColor = Theme.accent
        var content = cell.defaultContentConfiguration()
        content.textProperties.color = Theme.ink
        content.secondaryTextProperties.color = Theme.secondary
        content.secondaryTextProperties.numberOfLines = 0
        content.textProperties.numberOfLines = 0
        if indexPath.section == 0 {
            let book = indexPath.row == 0 ? original : candidate
            content.text = "\(indexPath.row == 0 ? "原版本" : "待切换") · \(book.sourceName)"
            content.secondaryText = "《\(book.title)》 · \(book.author)\n\(book.chapters.count) 章 · 缓存 \(book.cachedChapterCount) 章\n末章：\(book.latestChapterTitle)"
            cell.selectionStyle = .none
        } else if indexPath.section == 1, indexPath.row == 0 {
            content.text = selectedIndex.map { candidate.chapters[$0].title } ?? "未找到唯一匹配，请手动选章"
            content.secondaryText = selectedIndex == match?.index ? match?.explanation : "已手动选择"
            if selectedIndex == nil { content.secondaryText = "仅有相同章号不会自动续读" }
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "sourceSwitch.chapter"
        } else if indexPath.section == 1 {
            content.text = "沿用原章内进度"
            let toggle = UISwitch()
            toggle.isOn = preserveFraction
            toggle.isEnabled = selectedIndex != nil
            toggle.accessibilityIdentifier = "sourceSwitch.fraction"
            toggle.addTarget(self, action: #selector(changeFraction(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        } else if indexPath.section == 2, indexPath.row == 0 {
            content.text = loading ? "取消试读" : (verifiedText == nil ? "试读所选章节 / 重试" : "重新试读")
            content.image = UIImage(systemName: loading ? "stop.circle" : "text.book.closed")
            content.secondaryText = selectedIndex == nil ? "请先选择续读章节" : "确认前不会写入书架"
            cell.accessibilityIdentifier = "sourceSwitch.preview"
            if selectedIndex == nil || sourceInvalid { content.textProperties.color = Theme.secondary }
        } else if indexPath.section == 2 {
            content.text = String(verifiedText!.prefix(180))
            content.secondaryText = "已获取 \(verifiedText!.count) 字 · 点击查看完整试读原文"
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "sourceSwitch.previewText"
        } else {
            content.text = "复制可匹配的书签"
            let toggle = UISwitch()
            toggle.isOn = copyBookmarks
            toggle.accessibilityIdentifier = "sourceSwitch.bookmarks"
            toggle.addTarget(self, action: #selector(changeBookmarks(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1, indexPath.row == 0 { chooseChapter() }
        if indexPath.section == 2, indexPath.row == 0 {
            if loading {
                cancelPreview()
                status = "已取消试读，可重新尝试或改选章节。"
                render()
            } else { preview() }
        }
        if indexPath.section == 2, indexPath.row == 1, let verifiedText {
            let controller = UIViewController()
            controller.title = "试读原文"
            let text = UITextView()
            text.text = verifiedText
            text.isEditable = false
            text.font = .systemFont(ofSize: 18)
            text.backgroundColor = Theme.bg
            text.textColor = Theme.ink
            text.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
            controller.view = text
            navigationController?.pushViewController(controller, animated: true)
        }
    }

    @objc private func changeFraction(_ sender: UISwitch) { preserveFraction = sender.isOn }
    @objc private func changeBookmarks(_ sender: UISwitch) { copyBookmarks = sender.isOn }

    private func chooseChapter() {
        var suggested = selectedIndex
        if suggested == nil, original.chapters.indices.contains(resumeProgress.chapterIndex) {
            suggested = YueduSourceSwitch.suggestedIndex(original.chapters[resumeProgress.chapterIndex], in: candidate.chapters)
        }
        let picker = ReaderContentsViewController(book: candidate, currentChapter: suggested ?? 0, bookmarksSelected: false)
        picker.onSelect = { [weak self] index, _ in
            guard let self else { return }
            self.cancelPreview()
            self.selectedIndex = index
            self.preserveFraction = false
            self.verifiedText = nil
            self.status = "续读章节已变更，请重新试读。"
            self.render()
        }
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    private func cancelPreview() {
        task?.cancel()
        token = UUID()
        loading = false
    }

    private func preview() {
        guard let selectedIndex, !sourceInvalid else { return }
        cancelPreview()
        verifiedText = nil
        loading = true
        status = "正在获取所选章节，最多等待 30 秒…"
        render()
        let currentToken = token
        let candidate = candidate
        let source = source
        task = Task { [weak self] in
            let started = Date()
            do {
                let chapter = candidate.chapters[selectedIndex]
                let text: String
                if !chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = chapter.content
                } else {
                    text = try await SourceEngine.shared.loadChapter(chapter, source: source, book: candidate, timeout: 30)
                }
                try Task.checkCancellation()
                guard let self, self.token == currentToken else { return }
                guard SourceStore.shared.source(id: source.id) == source else {
                    throw SourceError.invalid("书源配置已变化，请返回重新搜索。")
                }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SourceError.empty("这一章没有正文，请重试或选择其他章节。")
                }
                self.verifiedText = text
                self.status = chapter.content.isEmpty
                    ? String(format: "试读成功 · %.1f 秒 · 请核对正文后确认换源。", Date().timeIntervalSince(started))
                    : "已载入此版本的缓存正文，请核对后确认换源。"
            } catch {
                guard let self, self.token == currentToken else { return }
                self.status = "试读失败：\(error.localizedDescription)\n原书未改动，可重试或换其他版本。"
            }
            guard let self, self.token == currentToken else { return }
            self.loading = false
            self.render()
        }
    }

    @objc private func confirm() {
        guard verifiedText != nil, !loading, !sourceInvalid else { return }
        if !YueduSourceSwitch.metadataAgrees(original, candidate) {
            let alert = UIAlertController(title: "确认是同一部作品？", message: "原书：\(original.title) · \(original.author)\n新书：\(candidate.title) · \(candidate.author)\n书名或作者不一致、作者不明，请确认试读内容与原书一致。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "确认换源", style: .default) { [weak self] _ in self?.save() })
            alert.addAction(UIAlertAction(title: "继续核对", style: .cancel))
            present(alert, animated: true)
        } else { save() }
    }

    private func save() {
        guard let selectedIndex, let verifiedText, SourceStore.shared.source(id: source.id) == source else {
            showMessage("无法换源", "书源或试读内容已变化，请返回重新选择。")
            return
        }
        do {
            let saved = try LibraryStore.shared.switchSource(
                original: original, candidate: candidate, chapterIndex: selectedIndex,
                fraction: preserveFraction ? resumeProgress.scrollFraction : 0,
                verifiedText: verifiedText, copyBookmarks: copyBookmarks, candidateWasSaved: alreadySaved
            )
            // Remove the confirmation page so Back cannot accidentally commit it again.
            guard let navigationController else { return }
            var stack = navigationController.viewControllers
            stack.removeLast()
            stack.append(ReaderViewController(bookID: saved.id))
            navigationController.setViewControllers(stack, animated: true)
        } catch { showMessage("换源未保存", error.localizedDescription) }
    }
}

@MainActor
final class YueduSavedEditionsViewController: UITableViewController {
    private let bookID: UUID
    private var editions: [Book] = []

    init(bookID: UUID) {
        self.bookID = bookID
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        title = "已保存版本"
        navigationController?.setNavigationBarHidden(false, animated: animated)
        tableView.backgroundColor = Theme.bg
        editions = LibraryStore.shared.book(id: bookID).map { LibraryStore.shared.editions(of: $0) } ?? []
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { editions.count }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "打开版本会沿用该版本自己保存的进度。缓存章节可离线阅读；各版本可在书架单独管理或移除。"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let book = editions[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        cell.textLabel?.text = book.sourceName
        cell.detailTextLabel?.text = "\(book.currentChapterTitle) · 章内 \(Int(book.progress.scrollFraction * 100))%\n\(book.chapters.count) 章 · 已缓存 \(book.cachedChapterCount) 章"
        cell.detailTextLabel?.numberOfLines = 0
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(ReaderViewController(bookID: editions[indexPath.row].id), animated: true)
    }
}
