import UIKit

final class ReaderContentsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating {
    var onSelect: ((Int, Double) -> Void)?
    var onBookmarksChanged: (() -> Void)?
    var onDismiss: (() -> Void)?
    private var book: Book
    private let library: LibraryStore
    private let followsLibrary: Bool
    private let currentChapterID: UUID?
    private var observer: NSObjectProtocol?
    private var currentChapter = -1
    private let segments = UISegmentedControl(items: ["章节目录", "我的书签"])
    private let table = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private let search = UISearchController(searchResultsController: nil)
    private var reversed = false
    private var cachedOnly = false
    private let bookmarksInitiallySelected: Bool
    private var query: String { (search.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private var bookmarks: [Bookmark] = []
    private var chapterIndices: [Int] = []
    private var showingBookmarks: Bool { segments.selectedSegmentIndex == 1 }

    init(book: Book, currentChapter: Int, bookmarksSelected: Bool, library: LibraryStore? = nil, followsLibrary: Bool = true) {
        self.book = book
        self.library = library ?? .shared
        self.followsLibrary = followsLibrary
        self.currentChapterID = book.chapters.indices.contains(currentChapter) ? book.chapters[currentChapter].id : nil
        self.bookmarksInitiallySelected = bookmarksSelected
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = book.title
        view.backgroundColor = Theme.bg
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(close))
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "搜索章节名或章序号"
        search.searchBar.accessibilityIdentifier = "reader.contentsSearch"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        updateFilterMenu()
        segments.selectedSegmentIndex = bookmarksInitiallySelected ? 1 : 0
        segments.selectedSegmentTintColor = Theme.surface
        segments.setTitleTextAttributes([.foregroundColor: Theme.ink, .font: UIFont.systemFont(ofSize: 13, weight: .medium)], for: .normal)
        segments.addTarget(self, action: #selector(changeSegment), for: .valueChanged)
        segments.accessibilityIdentifier = "reader.contentsSegments"
        segments.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(segments)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = Theme.bg
        table.separatorColor = Theme.line
        table.separatorInset = UIEdgeInsets(top: 0, left: 24, bottom: 0, right: 24)
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 66
        table.accessibilityIdentifier = "reader.contentsList"
        table.register(UITableViewCell.self, forCellReuseIdentifier: "chapter")
        view.addSubview(table)
        NSLayoutConstraint.activate([
            segments.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            segments.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            segments.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            segments.heightAnchor.constraint(equalToConstant: 36),
            table.topAnchor.constraint(equalTo: segments.bottomAnchor, constant: 14),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        emptyLabel.text = "还没有书签\n\n点击阅读页右上角的书签，\n把想再读的地方留下来。"
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = Theme.secondary
        if followsLibrary {
            observer = NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadContents() }
            }
        }
        reloadContents()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scrollToCurrent()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        showingBookmarks ? bookmarks.count : chapterIndices.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chapter", for: indexPath)
        cell.backgroundColor = Theme.bg
        cell.tintColor = Theme.accent
        var content = cell.defaultContentConfiguration()
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 16, trailing: 24)
        content.textProperties.font = .systemFont(ofSize: 15, weight: .medium)
        content.textProperties.color = Theme.ink
        content.textProperties.numberOfLines = 2
        content.secondaryTextProperties.font = .systemFont(ofSize: 11)
        content.secondaryTextProperties.color = Theme.secondary
        content.textToSecondaryTextVerticalPadding = 7
        if showingBookmarks {
            let bookmark = bookmarks[indexPath.row]
            content.text = bookmark.title
            content.secondaryText = "第 \(bookmark.chapterIndex + 1) 章 · 章内 \(Int(bookmark.scrollFraction * 100))% · \(bookmark.createdAt.formatted(date: .abbreviated, time: .omitted))"
            content.image = UIImage(systemName: "bookmark.fill")
            content.imageProperties.tintColor = Theme.accent
            content.imageProperties.maximumSize = CGSize(width: 16, height: 20)
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "reader.bookmark.\(bookmark.id.uuidString)"
        } else {
            let index = chapterIndices[indexPath.row]
            let chapter = book.chapters[index]
            content.text = chapter.title
            content.secondaryText = "\(String(format: "%02d", index + 1))   ·   \(!chapter.hasCachedContent ? "待载入" : "可离线阅读")"
            if index == currentChapter { content.textProperties.color = Theme.accent }
            cell.accessoryType = index == currentChapter ? .checkmark : .none
            cell.accessibilityIdentifier = "reader.chapter.\(index)"
        }
        cell.contentConfiguration = content
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let index: Int
        let fraction: Double
        if showingBookmarks {
            guard bookmarks.indices.contains(indexPath.row) else { return }
            let bookmark = bookmarks[indexPath.row]
            index = bookmark.chapterIndex
            fraction = bookmark.scrollFraction
        } else {
            guard chapterIndices.indices.contains(indexPath.row) else { return }
            index = chapterIndices[indexPath.row]
            fraction = 0
        }
        let selection = onSelect
        let completion = onDismiss
        guard book.chapters.indices.contains(index) else { return }
        let chapterID = book.chapters[index].id
        let bookID = book.id
        let library = library
        let followsLibrary = followsLibrary
        dismissContents {
            // The catalog can change again during the sheet dismissal animation.
            if !followsLibrary {
                selection?(index, fraction)
            } else if let index = library.book(id: bookID)?.chapters.firstIndex(where: { $0.id == chapterID }) {
                selection?(index, fraction)
            }
            completion?()
        }
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { showingBookmarks }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard showingBookmarks, editingStyle == .delete,
              bookmarks.indices.contains(indexPath.row) else { return }
        guard library.removeBookmark(id: bookmarks[indexPath.row].id) else {
            showMessage("书签未能移除", library.persistenceError ?? "请稍后重试。")
            return
        }
        // The successful write refreshes the snapshot through libraryChanged.
        onBookmarksChanged?()
    }

    private func reloadContents() {
        let query = query
        if followsLibrary {
            guard let latest = library.book(id: book.id) else {
                currentChapter = -1
                chapterIndices = []
                bookmarks = []
                table.reloadData()
                updateEmptyState()
                return
            }
            book = latest
        }
        currentChapter = book.chapters.firstIndex { $0.id == currentChapterID } ?? -1
        let indices = book.chapters.indices.filter {
            (query.isEmpty || book.chapters[$0].title.localizedCaseInsensitiveContains(query) || String($0 + 1) == query)
                && (!cachedOnly || book.chapters[$0].hasCachedContent)
        }
        chapterIndices = reversed ? Array(indices.reversed()) : indices
        bookmarks = followsLibrary ? library.bookmarks.filter {
            $0.bookID == book.id && book.chapters.indices.contains($0.chapterIndex)
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        } : []
        table.reloadData()
        updateEmptyState()
    }

    private func updateEmptyState() {
        let empty = showingBookmarks ? bookmarks.isEmpty : chapterIndices.isEmpty
        emptyLabel.text = query.isEmpty && showingBookmarks
            ? "还没有书签\n\n点击阅读页右上角的书签，\n把想再读的地方留下来。"
            : "没有匹配的章节或书签\n请调整关键词或筛选条件。"
        table.backgroundView = empty ? emptyLabel : nil
    }

    func updateSearchResults(for searchController: UISearchController) {
        reloadContents()
    }

    private func updateFilterMenu() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease.circle"),
            menu: UIMenu(children: [
                UIAction(title: "倒序排列", state: reversed ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    self.reversed.toggle()
                    self.updateFilterMenu()
                    self.reloadContents()
                },
                UIAction(title: "仅看已缓存", state: cachedOnly ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    self.cachedOnly.toggle()
                    self.updateFilterMenu()
                    self.reloadContents()
                },
                UIAction(title: "定位当前章节") { [weak self] _ in
                    guard let self else { return }
                    self.search.searchBar.text = ""
                    self.search.isActive = false
                    self.cachedOnly = false
                    self.segments.selectedSegmentIndex = 0
                    self.updateFilterMenu()
                    self.changeSegment()
                    self.scrollToCurrent()
                }
            ])
        )
        navigationItem.leftBarButtonItem?.accessibilityLabel = "目录筛选与排序"
    }

    private func scrollToCurrent() {
        if !showingBookmarks, let row = chapterIndices.firstIndex(of: currentChapter) {
            table.scrollToRow(at: IndexPath(row: row, section: 0), at: .middle, animated: false)
        }
    }
    @objc private func changeSegment() { reloadContents() }
    @objc private func close() {
        let completion = onDismiss
        dismissContents(completion: completion)
    }

    private func dismissContents(completion: (() -> Void)?) {
        // The search controller may itself be presented by the contents page.
        // Dismiss the entire navigation sheet, not just that search overlay.
        let presenter = navigationController?.presentingViewController ?? presentingViewController
        if let presenter {
            presenter.dismiss(animated: true, completion: completion)
        } else {
            dismiss(animated: true, completion: completion)
        }
    }
}
