import UIKit
import UniformTypeIdentifiers

final class BookshelfViewController: LibraryPageController, UIDocumentPickerDelegate {
    private var filter = 0
    private var sortByTitle = false
    private var observer: NSObjectProtocol?
    private var importing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        render()
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let error = LibraryStore.shared.persistenceError { showMessage("存储提示", error) }
    }

    private func render() {
        guard isViewLoaded else { return }
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let search = symbolButton("magnifyingglass", label: "搜索书架") { [weak self] in self?.navigationController?.pushViewController(LibrarySearchViewController(), animated: true) }
        let add = symbolButton("plus", label: "导入书籍") { [weak self] in self?.showImportMenu() }
        content.addArrangedSubview(pageHeader(title: "书架", subtitle: "把日子，读成喜欢的样子。", actions: [search, add]))

        let books = LibraryStore.shared.books
        if let current = books.filter({ $0.lastReadAt != nil }).sorted(by: { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }).first ?? books.first {
            content.addArrangedSubview(continueCard(current))
        }

        let chips = hstack([], spacing: 9)
        for (index, title) in ["全部", "最近阅读", "本地导入"].enumerated() {
            let button = UIButton(type: .system)
            var config = UIButton.Configuration.filled()
            config.title = title
            config.baseBackgroundColor = filter == index ? Theme.accent : Theme.pale.withAlphaComponent(0.65)
            config.baseForegroundColor = filter == index ? .white : Theme.secondary
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in var out = incoming; out.font = UIFont.systemFont(ofSize: 12, weight: .medium); return out }
            button.configuration = config
            button.addAction(UIAction { [weak self] _ in self?.filter = index; self?.render() }, for: .touchUpInside)
            chips.addArrangedSubview(button)
        }
        chips.addArrangedSubview(UIView())
        content.addArrangedSubview(chips)
        content.setCustomSpacing(20, after: chips)
        var visible = books.filter { filter == 0 || (filter == 1 && $0.lastReadAt != nil) || (filter == 2 && !$0.isSample && $0.sourceID == nil) }
        visible.sort { sortByTitle ? $0.title.localizedCompare($1.title) == .orderedAscending : ($0.lastReadAt ?? $0.addedAt) > ($1.lastReadAt ?? $1.addedAt) }
        let count = textLabel("我的藏书", size: 18, weight: .semibold)
        let number = textLabel("\(visible.count) 本", size: 12, color: Theme.secondary)
        let sort = UIButton(type: .system)
        sort.setImage(UIImage(systemName: "line.3.horizontal.decrease"), for: .normal)
        sort.tintColor = Theme.secondary
        sort.accessibilityLabel = "书架排序"
        sort.menu = UIMenu(children: [
            UIAction(title: "最近阅读 / 添加", state: sortByTitle ? .off : .on) { [weak self] _ in self?.sortByTitle = false; self?.render() },
            UIAction(title: "书名", state: sortByTitle ? .on : .off) { [weak self] _ in self?.sortByTitle = true; self?.render() }
        ])
        sort.showsMenuAsPrimaryAction = true
        content.addArrangedSubview(hstack([count, number, UIView(), sort], spacing: 10))
        if visible.isEmpty {
            content.addArrangedSubview(emptyState())
        } else {
            let grid = vstack([], spacing: 25)
            for start in stride(from: 0, to: visible.count, by: 3) {
                let row = hstack([], spacing: 19, alignment: .top)
                row.distribution = .fillEqually
                for index in start..<min(start + 3, visible.count) {
                    let book = visible[index]
                    let card = BookCard(
                        book: book,
                        action: { [weak self] in self?.pushReader(book) },
                        remove: { [weak self] in self?.confirmRemove(book) },
                        details: { [weak self] in
                            self?.navigationController?.pushViewController(
                                YueduBookDetailViewController(bookID: book.id), animated: true
                            )
                        }
                    )
                    row.addArrangedSubview(card)
                }
                while row.arrangedSubviews.count < 3 { row.addArrangedSubview(UIView()) }
                grid.addArrangedSubview(row)
            }
            content.addArrangedSubview(grid)
        }
        let footer = textLabel("一本书，一段属于自己的时光", size: 11, color: Theme.secondary.withAlphaComponent(0.7))
        footer.textAlignment = .center
        content.addArrangedSubview(footer)
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
        let icon = UIImageView(image: UIImage(systemName: "book.closed")); icon.tintColor = Theme.accent; icon.contentMode = .scaleAspectFit
        icon.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let label = textLabel(filter == 1 ? "还没有阅读记录" : filter == 2 ? "带上你喜欢的书" : "书架，等一本好书", size: 18, weight: .medium)
        let sub = textLabel("从「文件」导入 TXT / EPUB，或到发现页选一本经典。", size: 13, color: Theme.secondary)
        label.textAlignment = .center; sub.textAlignment = .center
        let button = UIButton(type: .system); button.setTitle("导入书籍", for: .normal)
        button.addAction(UIAction { [weak self] _ in self?.presentImporter() }, for: .touchUpInside)
        return vstack([icon, label, sub, button], spacing: 18)
    }

    private func confirmRemove(_ book: Book) {
        let alert = UIAlertController(title: "移除《\(book.title)》？", message: "本应用中保存的阅读进度、书签与缓存会一并移除，原始文件不受影响。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "移除", style: .destructive) { _ in
            YueduDownloadManager.shared.pause(bookID: book.id)
            LibraryStore.shared.remove(id: book.id)
        })
        present(alert, animated: true)
    }

    private func showImportMenu() {
        let alert = UIAlertController(title: "把好书放进书架", message: "支持 TXT 与未加密的 EPUB", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "从文件导入", style: .default) { [weak self] _ in self?.presentImporter() })
        alert.addAction(UIAlertAction(title: "搜索在线书源", style: .default) { [weak self] _ in self?.navigationController?.pushViewController(OnlineSearchViewController(), animated: true) })
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
        results = LibraryStore.shared.books.filter { term.isEmpty || "\($0.title) \($0.author) \($0.summary)".localizedCaseInsensitiveContains(term) }
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
