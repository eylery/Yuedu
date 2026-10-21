import UIKit
import AVFoundation

final class ReaderViewController: UIViewController, UIScrollViewDelegate, AVSpeechSynthesizerDelegate, UIAdaptivePresentationControllerDelegate, UIGestureRecognizerDelegate {
    private let bookID: UUID
    private var preferences = ReaderPreferences.load()
    private var chapterIndex = 0
    private var activeChapterID: UUID?
    private var contentAvailable = false
    private var isVisible = false
    private var hasAppeared = false
    private var isRestoring = false
    private var isChangingSize = false
    private var readingToolsOpen = false
    private var pendingFraction: Double?
    private var previousNavigationBarHidden = false
    private var loadTask: Task<Void, Never>?
    private var purificationTask: Task<Void, Never>?
    private var purificationToken = UUID()
    private var originalBody = ""
    private var displayedBody = ""
    private var saveWork: DispatchWorkItem?
    private var sessionStarted: TimeInterval?
    private var sessionTimer: Timer?
    private let synthesizer = AVSpeechSynthesizer()

    private static let readingInfoHeight: CGFloat = 28
    private let readingInfoBackground = UIView()
    private let readingInfoBar = UIStackView()
    private let chapterInfoLabel = UILabel()
    private let pageInfoLabel = UILabel()
    private let readingLayer = UIView()
    private let readingSurface = UIView()
    private let chromeOverlay = YueduReadingChromeOverlay()
    private var viewportConstraints: [NSLayoutConstraint] = []
    private var viewportSize = CGSize.zero
    private var viewportOrientation: UIInterfaceOrientation = .unknown
    private weak var viewportWindow: UIWindow?
    private let topBarBackground = UIView()
    private let footerBackground = UIView()
    private let topBarSeparator = UIView()
    private let footerSeparator = UIView()
    private let topBar = UIView()
    private let backButton = UIButton(type: .system)
    private let bookmarkButton = UIButton(type: .system)
    private let detailsButton = UIButton(type: .system)
    private let bookLabel = UILabel()
    private let sourceLabel = UILabel()
    private let scrollView = UIScrollView()
    private let pageReader = YueduPageReaderController()
    private let contentStack = UIStackView()
    private var contentTopConstraint: NSLayoutConstraint?
    private var contentLeadingConstraint: NSLayoutConstraint?
    private var contentTrailingConstraint: NSLayoutConstraint?
    private var contentBottomConstraint: NSLayoutConstraint?
    private var contentWidthConstraint: NSLayoutConstraint?
    private let chapterNumber = UILabel()
    private let chapterTitle = UILabel()
    private let bodyLabel = UILabel()
    private let endLabel = UILabel()
    private let chapterEndButton = UIButton(type: .system)
    private let statusStack = UIStackView()
    private let activity = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let switchSourceButton = UIButton(type: .system)
    private let footer = UIView()
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let listenButton = UIButton(type: .system)
    private var toolButtons: [UIButton] = []
    private var book: Book? { LibraryStore.shared.book(id: bookID) }
    private var chapter: BookChapter? {
        guard let book, book.chapters.indices.contains(chapterIndex) else { return nil }
        return book.chapters[chapterIndex]
    }

    init(bookID: UUID) {
        self.bookID = bookID
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        loadTask?.cancel()
        purificationTask?.cancel()
        saveWork?.cancel()
        sessionTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { preferences.paper == .night ? .lightContent : .darkContent }
    override var prefersStatusBarHidden: Bool {
        preferences.fullScreen && !preferences.showsStatusBarInFullScreen && !readingToolsOpen
    }
    override var prefersHomeIndicatorAutoHidden: Bool { preferences.fullScreen && !readingToolsOpen }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .none }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        synthesizer.delegate = self
        buildInterface()
        applyPalette()
        NotificationCenter.default.addObserver(self, selector: #selector(enterBackground), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enterForeground), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(catalogChanged(_:)), name: .yueduCatalogChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(purificationChanged), name: .yueduPurificationChanged, object: nil)
        if let book, !book.chapters.isEmpty {
            chapterIndex = min(max(0, book.progress.chapterIndex), book.chapters.count - 1)
            showChapter(at: chapterIndex, fraction: book.progress.scrollFraction, saveCurrent: false)
        } else {
            bookLabel.text = book?.title ?? "书籍不可用"
            chapterNumber.isHidden = true
            chapterTitle.text = book == nil ? "书籍不可用" : "暂无章节"
            setStatus(book == nil ? "这本书已不在书架中，请返回书架选择其他书籍。" : "这本书还没有可阅读的章节。", loading: false, retry: false)
            previousButton.isEnabled = false
            nextButton.isEnabled = false
            bookmarkButton.isEnabled = false
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        previousNavigationBarHidden = navigationController?.isNavigationBarHidden ?? false
        navigationController?.setNavigationBarHidden(true, animated: animated)
        updateReadingViewport()
        applyPreferences(ReaderPreferences.load())
        updateSystemBars()
        if hasAppeared, let book {
            showChapter(at: book.progress.chapterIndex, fraction: book.progress.scrollFraction, saveCurrent: false)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hasAppeared {
            // Navigation and status bars can change the safe area several times
            // during the first presentation. Restore once in the settled viewport.
            pendingFraction = book?.progress.scrollFraction ?? 0
            if contentAvailable {
                configurePages(preservePosition: false)
                restorePositionIfNeeded()
            }
        }
        hasAppeared = true
        isVisible = true
        persistProgress()
        startReadingSession()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.finishReadingSession()
            self?.startReadingSession()
            self?.persistProgress()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        saveWork?.cancel()
        persistProgress()
        finishReadingSession()
        sessionTimer?.invalidate()
        sessionTimer = nil
        stopSpeaking()
        navigationController?.setNavigationBarHidden(previousNavigationBarHidden, animated: animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        restorePositionIfNeeded()
        updateBottomReadingInfo()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateReadingViewport()
    }

    private func updateReadingViewport() {
        guard !viewportConstraints.isEmpty, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let window = view.window
        let orientation = window?.windowScene?.interfaceOrientation ?? .unknown
        guard viewportSize != view.bounds.size || viewportOrientation != orientation || viewportWindow !== window else { return }
        // Sample the window's full-screen safe area only when its geometry changes.
        // Navigation bars, sheets and status-bar visibility must not resize the text.
        let insets = window?.safeAreaInsets ?? view.safeAreaInsets
        if contentAvailable, pendingFraction == nil { pendingFraction = currentFraction }
        viewportSize = view.bounds.size
        viewportOrientation = orientation
        viewportWindow = window
        for (constraint, constant) in zip(viewportConstraints, [insets.top, insets.left, -insets.bottom - Self.readingInfoHeight, -insets.right]) {
            constraint.constant = constant
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        pendingFraction = currentFraction
        isChangingSize = true
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in self?.view.layoutIfNeeded() }) { [weak self] _ in
            self?.isChangingSize = false
            self?.restorePositionIfNeeded()
        }
    }

    private func buildInterface() {
        view.accessibilityIdentifier = "reader.screen"
        readingSurface.accessibilityIdentifier = "reader.surface"
        chromeOverlay.accessibilityIdentifier = "reader.chrome"
        topBar.accessibilityIdentifier = "reader.topBar"
        footer.accessibilityIdentifier = "reader.footer"
        readingLayer.accessibilityIdentifier = "reader.readingLayer"
        view.addSubview(readingLayer)
        readingLayer.pinEdges(to: view)
        readingSurface.translatesAutoresizingMaskIntoConstraints = false
        readingLayer.addSubview(readingSurface)
        view.addSubview(chromeOverlay)
        viewportConstraints = [
            readingSurface.topAnchor.constraint(equalTo: view.topAnchor),
            readingSurface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readingSurface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            readingSurface.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ]
        NSLayoutConstraint.activate(viewportConstraints)
        chromeOverlay.pinEdges(to: view)
        buildReadingInfoBar()
        for background in [topBarBackground, footerBackground] {
            background.translatesAutoresizingMaskIntoConstraints = false
            background.isUserInteractionEnabled = false
            chromeOverlay.addSubview(background)
        }
        for bar in [topBar, footer] {
            bar.translatesAutoresizingMaskIntoConstraints = false
            chromeOverlay.addSubview(bar)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 64),
            footer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        // Extend the chrome color through the status and home-indicator areas,
        // while keeping all controls at their existing safe-area positions.
        NSLayoutConstraint.activate([
            topBarBackground.topAnchor.constraint(equalTo: chromeOverlay.topAnchor),
            topBarBackground.leadingAnchor.constraint(equalTo: chromeOverlay.leadingAnchor),
            topBarBackground.trailingAnchor.constraint(equalTo: chromeOverlay.trailingAnchor),
            topBarBackground.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            footerBackground.topAnchor.constraint(equalTo: footer.topAnchor),
            footerBackground.leadingAnchor.constraint(equalTo: chromeOverlay.leadingAnchor),
            footerBackground.trailingAnchor.constraint(equalTo: chromeOverlay.trailingAnchor),
            footerBackground.bottomAnchor.constraint(equalTo: chromeOverlay.bottomAnchor)
        ])
        for (separator, background) in [(topBarSeparator, topBarBackground), (footerSeparator, footerBackground)] {
            separator.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(separator)
            NSLayoutConstraint.activate([
                separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
                separator.heightAnchor.constraint(equalToConstant: 0.5)
            ])
        }
        topBarSeparator.bottomAnchor.constraint(equalTo: topBarBackground.bottomAnchor).isActive = true
        footerSeparator.topAnchor.constraint(equalTo: footerBackground.topAnchor).isActive = true
        readingSurface.addSubview(scrollView)
        scrollView.pinEdges(to: readingSurface)
        addChild(pageReader)
        readingSurface.addSubview(pageReader.view)
        pageReader.view.pinEdges(to: readingSurface)
        pageReader.didMove(toParent: self)
        pageReader.view.isHidden = true
        pageReader.onPositionChanged = { [weak self] in
            guard let self, self.contentAvailable, self.preferences.turnStyle == .slide else { return }
            self.restorePositionIfNeeded()
            self.updateProgressDisplay()
            if !self.isChangingSize && !self.isRestoring { self.persistProgress() }
        }
        pageReader.onChapterTurn = { [weak self] direction in
            guard let self else { return }
            self.showChapter(at: self.chapterIndex + direction, fraction: direction < 0 ? 1 : 0)
        }
        pageReader.onCenterTap = { [weak self] in self?.toggleFullScreen() }
        configureIcon(backButton, symbol: "chevron.left", label: "返回书架", id: "back", action: #selector(goBack))
        configureIcon(bookmarkButton, symbol: "bookmark", label: "添加书签", id: "addBookmark", action: #selector(toggleBookmark))
        configureIcon(detailsButton, symbol: "ellipsis", label: "书籍详情与缓存", id: "details", action: #selector(openDetails))
        bookLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        bookLabel.textAlignment = .center
        bookLabel.lineBreakMode = .byTruncatingMiddle
        sourceLabel.font = .systemFont(ofSize: 10, weight: .regular)
        sourceLabel.textAlignment = .center
        sourceLabel.text = "把时间，留给阅读"
        sourceLabel.accessibilityIdentifier = "reader.purificationStatus"
        let titleStack = UIStackView(arrangedSubviews: [bookLabel, sourceLabel])
        titleStack.axis = .vertical
        titleStack.spacing = 6
        let topStack = UIStackView(arrangedSubviews: [backButton, titleStack, bookmarkButton, detailsButton])
        topStack.alignment = .center
        topStack.spacing = 12
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(topStack)
        NSLayoutConstraint.activate([
            topStack.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 12),
            topStack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            topStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            bookmarkButton.widthAnchor.constraint(equalToConstant: 44),
            bookmarkButton.heightAnchor.constraint(equalToConstant: 44),
            detailsButton.widthAnchor.constraint(equalToConstant: 44),
            detailsButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.accessibilityIdentifier = "reader.content"
        let contentTap = UITapGestureRecognizer(target: self, action: #selector(contentTapped(_:)))
        contentTap.delegate = self
        contentTap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(contentTap)
        contentStack.axis = .vertical
        contentStack.spacing = 22
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        contentTopConstraint = contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor)
        contentLeadingConstraint = contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor)
        contentTrailingConstraint = contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor)
        contentBottomConstraint = contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor)
        contentWidthConstraint = contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        NSLayoutConstraint.activate([contentTopConstraint, contentLeadingConstraint, contentTrailingConstraint,
                                     contentBottomConstraint, contentWidthConstraint].compactMap { $0 })
        chapterNumber.font = .systemFont(ofSize: 10, weight: .semibold)
        chapterTitle.font = .readingSerif(28)
        chapterTitle.numberOfLines = 0
        chapterTitle.accessibilityTraits = .header
        chapterTitle.accessibilityIdentifier = "reader.chapterTitle"
        bodyLabel.numberOfLines = 0
        bodyLabel.accessibilityIdentifier = "reader.text"
        bodyLabel.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "切换全屏阅读") { [weak self] _ in
            self?.toggleFullScreen()
            return true
        }]
        endLabel.font = .systemFont(ofSize: 11)
        endLabel.textAlignment = .center
        endLabel.text = "—  本 章 完  —"
        contentStack.addArrangedSubview(chapterNumber)
        contentStack.setCustomSpacing(14, after: chapterNumber)
        contentStack.addArrangedSubview(chapterTitle)
        contentStack.setCustomSpacing(28, after: chapterTitle)
        contentStack.addArrangedSubview(bodyLabel)
        statusStack.axis = .vertical
        statusStack.alignment = .center
        statusStack.spacing = 16
        statusStack.addArrangedSubview(activity)
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.accessibilityIdentifier = "reader.status"
        statusStack.addArrangedSubview(statusLabel)
        retryButton.setTitle("重新加载", for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        retryButton.accessibilityIdentifier = "reader.retry"
        retryButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        retryButton.addTarget(self, action: #selector(retryChapter), for: .touchUpInside)
        statusStack.addArrangedSubview(retryButton)
        switchSourceButton.setTitle("换个书源继续读", for: .normal)
        switchSourceButton.accessibilityIdentifier = "reader.switchSource"
        switchSourceButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        switchSourceButton.addTarget(self, action: #selector(switchSource), for: .touchUpInside)
        statusStack.addArrangedSubview(switchSourceButton)
        contentStack.addArrangedSubview(statusStack)
        contentStack.addArrangedSubview(endLabel)
        chapterEndButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        chapterEndButton.titleLabel?.numberOfLines = 2
        chapterEndButton.titleLabel?.textAlignment = .center
        chapterEndButton.layer.cornerRadius = 12
        chapterEndButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        chapterEndButton.accessibilityIdentifier = "reader.nextChapterAtEnd"
        chapterEndButton.addTarget(self, action: #selector(nextChapter), for: .touchUpInside)
        contentStack.addArrangedSubview(chapterEndButton)
        applyTypographyLayout()
        buildFooter()
    }

    private func buildReadingInfoBar() {
        readingInfoBackground.translatesAutoresizingMaskIntoConstraints = false
        readingInfoBackground.isUserInteractionEnabled = false
        readingInfoBar.translatesAutoresizingMaskIntoConstraints = false
        readingInfoBar.alignment = .center
        readingInfoBar.spacing = 12
        readingInfoBar.isUserInteractionEnabled = false
        readingInfoBar.accessibilityIdentifier = "reader.bottomInfo"
        chapterInfoLabel.font = .systemFont(ofSize: 11)
        chapterInfoLabel.lineBreakMode = .byTruncatingMiddle
        chapterInfoLabel.accessibilityIdentifier = "reader.chapterInfo"
        chapterInfoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pageInfoLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        pageInfoLabel.textAlignment = .right
        pageInfoLabel.accessibilityIdentifier = "reader.pageInfo"
        pageInfoLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        pageInfoLabel.setContentHuggingPriority(.required, for: .horizontal)
        readingInfoBar.addArrangedSubview(chapterInfoLabel)
        readingInfoBar.addArrangedSubview(pageInfoLabel)
        readingLayer.addSubview(readingInfoBackground)
        readingLayer.addSubview(readingInfoBar)
        NSLayoutConstraint.activate([
            readingInfoBar.topAnchor.constraint(equalTo: readingSurface.bottomAnchor),
            readingInfoBar.heightAnchor.constraint(equalToConstant: Self.readingInfoHeight),
            readingInfoBar.leadingAnchor.constraint(equalTo: readingSurface.leadingAnchor, constant: 20),
            readingInfoBar.trailingAnchor.constraint(equalTo: readingSurface.trailingAnchor, constant: -20),
            readingInfoBackground.topAnchor.constraint(equalTo: readingInfoBar.topAnchor),
            readingInfoBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readingInfoBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readingInfoBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func updateBottomReadingInfo() {
        let chapterText = chapter.map { "第 \(chapterIndex + 1) 章 · \($0.title)" } ?? "暂无章节"
        if chapterInfoLabel.text != chapterText { chapterInfoLabel.text = chapterText }
        let pageText: String
        if !contentAvailable {
            pageText = "— / — 页"
        } else if preferences.turnStyle == .slide {
            pageText = pageReader.isReady ? "\(pageReader.currentPageNumber) / \(pageReader.totalPageCount) 页" : "— / — 页"
        } else {
            // Count screenfuls of the chapter itself, excluding end-of-chapter controls.
            let chapterHeight = contentStack.convert(bodyLabel.frame, to: scrollView).maxY
            let position = YueduReadingPagePosition.scrolling(
                chapterHeight: chapterHeight,
                viewportHeight: scrollView.bounds.height,
                offset: scrollView.contentOffset.y
            )
            pageText = position.map { "\($0.current) / \($0.total) 页" } ?? "— / — 页"
        }
        if pageInfoLabel.text != pageText { pageInfoLabel.text = pageText }
    }

    private func buildFooter() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: footer.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -4)
        ])
        configureIcon(previousButton, symbol: "chevron.left", label: "上一章", id: "previousChapter", action: #selector(previousChapter))
        configureIcon(nextButton, symbol: "chevron.right", label: "下一章", id: "nextChapter", action: #selector(nextChapter))
        let chapterRow = UIStackView(arrangedSubviews: [previousButton, UIView(), nextButton])
        chapterRow.alignment = .center
        for button in [previousButton, nextButton] {
            var configuration = UIButton.Configuration.plain()
            configuration.title = button === previousButton ? "上一章" : "下一章"
            configuration.image = UIImage(systemName: button === previousButton ? "chevron.left" : "chevron.right",
                                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium))
            configuration.imagePlacement = button === previousButton ? .leading : .trailing
            configuration.imagePadding = 5
            configuration.contentInsets = .zero
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes
                result.font = .systemFont(ofSize: 12, weight: .medium)
                return result
            }
            button.configuration = configuration
            button.widthAnchor.constraint(equalToConstant: 68).isActive = true
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
        }
        stack.addArrangedSubview(chapterRow)
        let contents = makeTool(symbol: "list.bullet", title: "目录", id: "contents", action: #selector(openContents))
        let bookmarks = makeTool(symbol: "bookmark", title: "书签", id: "bookmarks", action: #selector(openBookmarks))
        configureTool(listenButton, symbol: "headphones", title: "听书", id: "listen", action: #selector(openSpeechControls))
        let settings = makeTool(symbol: "textformat.size", title: "设置", id: "settings", action: #selector(openSettings))
        let fullScreen = makeTool(symbol: "arrow.up.left.and.arrow.down.right", title: "全屏", id: "fullScreen", action: #selector(toggleFullScreen))
        toolButtons = [contents, bookmarks, listenButton, fullScreen, settings]
        let tools = UIStackView(arrangedSubviews: toolButtons)
        tools.distribution = .fillEqually
        tools.heightAnchor.constraint(equalToConstant: 48).isActive = true
        stack.addArrangedSubview(tools)
    }

    private func configureIcon(_ button: UIButton, symbol: String, label: String, id: String, action: Selector) {
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = "reader.\(id)"
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func makeTool(symbol: String, title: String, id: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        configureTool(button, symbol: symbol, title: title, id: id, action: action)
        return button
    }

    private func configureTool(_ button: UIButton, symbol: String, title: String, id: String, action: Selector) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17))
        configuration.title = title
        configuration.imagePlacement = .top
        configuration.imagePadding = 6
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var result = incoming
            result.font = .systemFont(ofSize: 10, weight: .medium)
            return result
        }
        button.configuration = configuration
        button.accessibilityLabel = title
        button.accessibilityIdentifier = "reader.\(id)"
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func showChapter(at index: Int, fraction: Double = 0, saveCurrent: Bool = true) {
        guard let book, book.chapters.indices.contains(index) else { return }
        if saveCurrent { persistProgress() }
        finishReadingSession()
        stopSpeaking()
        loadTask?.cancel()
        purificationTask?.cancel()
        purificationToken = UUID()
        originalBody = ""
        displayedBody = ""
        saveWork?.cancel()
        chapterIndex = index
        pendingFraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
        contentAvailable = false
        let selected = book.chapters[index]
        activeChapterID = selected.id
        bookLabel.text = book.title
        chapterNumber.text = String(format: "CHAPTER  %02d", index + 1)
        chapterTitle.text = selected.title
        previousButton.isEnabled = index > 0
        nextButton.isEnabled = index + 1 < book.chapters.count
        chapterEndButton.setTitle(index + 1 < book.chapters.count ? "下一章  →" : "已读至全书末尾", for: .normal)
        chapterEndButton.isEnabled = index + 1 < book.chapters.count
        updateProgressDisplay()
        if !selected.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            displayContent(selected.content)
            return
        }
        // A local volume heading can legitimately contain no body. There is no
        // remote chapter to fetch, but it must remain a navigable TOC entry.
        if book.sourceID == nil, selected.url == nil {
            pendingFraction = 0
            setStatus("本章没有正文，可切换到其他章节继续阅读。", loading: false, retry: false)
            chapterEndButton.isHidden = !nextButton.isEnabled
            LibraryStore.shared.updateProgress(bookID: bookID, chapterIndex: index, scrollFraction: 0)
            updateProgressDisplay()
            return
        }
        setStatus("正在载入这一章…", loading: true, retry: false)
        let cacheRevision = LibraryStore.shared.cacheRevision(for: bookID)
        loadTask = Task { [weak self] in
            do {
                let content = try await SourceEngine.shared.loadChapter(selected, sourceID: book.sourceID, book: book)
                try Task.checkCancellation()
                guard let self, self.chapter?.id == selected.id else { return }
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.setStatus("本章没有获取到正文，请检查书源规则后重试。", loading: false, retry: true)
                    return
                }
                guard try LibraryStore.shared.cacheChapterContent(bookID: self.bookID, chapterID: selected.id,
                                                                 text: content, revision: cacheRevision) else {
                    self.setStatus("缓存或目录已变化，请重新加载这一章。", loading: false, retry: true)
                    return
                }
                self.displayContent(content)
            } catch {
                guard !Task.isCancelled, let self, self.chapter?.id == selected.id else { return }
                self.setStatus("章节加载失败\n\(error.localizedDescription)", loading: false, retry: true)
            }
        }
    }

    private func displayContent(_ text: String) {
        purificationTask?.cancel()
        let token = UUID()
        purificationToken = token
        originalBody = text
        guard let chapter, let book else { return }
        let settings = YueduPurificationStore.shared.settings
        guard settings.enabled, !settings.originalBookIDs.contains(bookID),
              settings.rules.contains(where: { $0.applies(bookID: bookID, sourceID: book.sourceID) }) else {
            renderContent(YueduPurificationResult(text: text))
            return
        }
        setStatus("正在整理正文…", loading: true, retry: false)
        purificationTask = Task { [weak self] in
            do {
                let result = try await YueduTextPurifier.process(text, chapterTitle: chapter.title, bookID: book.id, sourceID: book.sourceID, settings: settings)
                try Task.checkCancellation()
                guard let self, self.purificationToken == token, self.chapter?.id == chapter.id else { return }
                self.renderContent(result)
            } catch {
                guard !Task.isCancelled, let self, self.purificationToken == token else { return }
                self.renderContent(YueduPurificationResult(text: text, warnings: ["净化失败，已显示原文。"], restoredOriginal: true))
            }
        }
    }

    @objc private func purificationChanged() {
        guard isVisible || readingToolsOpen || !hasAppeared else { return }
        guard !originalBody.isEmpty else { return }
        pendingFraction = currentFraction
        saveWork?.cancel()
        stopSpeaking()
        displayContent(originalBody)
    }

    private func renderContent(_ result: YueduPurificationResult) {
        // Keep the pending fraction until the newly visible text and its scroll
        // content have both been laid out. The loading view can be much shorter.
        isRestoring = true
        displayedBody = result.text
        if !result.warnings.isEmpty { sourceLabel.text = "净化有提示 · 请在设置中预览" }
        else if !result.hits.isEmpty { sourceLabel.text = "已净化 \(result.hits.values.reduce(0, +)) 处 · 原文已保留" }
        else { sourceLabel.text = "把时间，留给阅读" }
        contentAvailable = true
        applyTypographyLayout()
        bodyLabel.attributedText = preferences.attributedText(displayedBody)
        bodyLabel.isHidden = false
        endLabel.isHidden = false
        chapterEndButton.isHidden = false
        statusStack.isHidden = true
        activity.stopAnimating()
        bookmarkButton.isEnabled = true
        listenButton.isEnabled = true
        // Resolve the full-screen/safe-area viewport before applying the saved
        // page fraction. A temporary smaller frame would choose a different page.
        view.setNeedsLayout()
        view.layoutIfNeeded()
        configurePages(preservePosition: false)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        contentStack.layoutIfNeeded()
        scrollView.layoutIfNeeded()
        isRestoring = false
        restorePositionIfNeeded()
        startReadingSession()
        persistProgress()
    }

    private func setStatus(_ text: String, loading: Bool, retry: Bool) {
        contentAvailable = false
        pageReader.view.isHidden = true
        scrollView.isHidden = false
        bodyLabel.isHidden = true
        endLabel.isHidden = true
        chapterEndButton.isHidden = true
        statusStack.isHidden = false
        statusLabel.text = text
        retryButton.isHidden = !retry
        switchSourceButton.isHidden = !retry || book?.sourceID == nil
        activity.isHidden = !loading
        loading ? activity.startAnimating() : activity.stopAnimating()
        bookmarkButton.isEnabled = false
        listenButton.isEnabled = false
        isRestoring = true
        scrollView.setContentOffset(.zero, animated: false)
        isRestoring = false
        updateBottomReadingInfo()
    }

    private var currentFraction: Double {
        if let pendingFraction { return pendingFraction }
        if preferences.turnStyle == .slide, contentAvailable { return pageReader.fraction }
        let distance = scrollView.contentSize.height - scrollView.bounds.height
        guard distance > 0 else { return contentAvailable ? 1 : 0 }
        return min(1, max(0, Double(scrollView.contentOffset.y / distance)))
    }

    private func restorePositionIfNeeded() {
        guard !isRestoring, contentAvailable, !isChangingSize, let fraction = pendingFraction, scrollView.bounds.height > 0 else { return }
        if preferences.turnStyle == .slide {
            guard pageReader.isReady else { return }
            pendingFraction = nil
            updateProgressDisplay()
            return
        }
        let distance = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        isRestoring = true
        scrollView.setContentOffset(CGPoint(x: 0, y: distance * CGFloat(fraction)), animated: false)
        pendingFraction = nil
        isRestoring = false
        updateProgressDisplay()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard preferences.turnStyle == .scroll, contentAvailable, !isRestoring, pendingFraction == nil else { return }
        updateProgressDisplay()
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistProgress() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func persistProgress() {
        guard hasAppeared, contentAvailable, chapter != nil else { return }
        LibraryStore.shared.updateProgress(bookID: bookID, chapterIndex: chapterIndex, scrollFraction: currentFraction)
    }

    private func updateProgressDisplay() {
        updateBottomReadingInfo()
        let hasBookmark = nearbyBookmark != nil
        bookmarkButton.setImage(UIImage(systemName: hasBookmark ? "bookmark.fill" : "bookmark"), for: .normal)
        bookmarkButton.accessibilityLabel = hasBookmark ? "移除此处书签" : "添加书签"
    }

    @objc private func catalogChanged(_ notification: Notification) {
        guard notification.object as? UUID == bookID, let book else { return }
        guard let index = book.chapters.firstIndex(where: { $0.id == activeChapterID }) else {
            showChapter(at: book.progress.chapterIndex, fraction: book.progress.scrollFraction, saveCurrent: false)
            return
        }
        // A foreground update can insert chapters while this reader remains visible.
        // Follow the displayed chapter identity without resetting its text or position.
        chapterIndex = index
        chapterNumber.text = String(format: "CHAPTER  %02d", index + 1)
        previousButton.isEnabled = index > 0
        nextButton.isEnabled = index + 1 < book.chapters.count
        chapterEndButton.setTitle(nextButton.isEnabled ? "下一章  →" : "已读至全书末尾", for: .normal)
        chapterEndButton.isEnabled = nextButton.isEnabled
        updateProgressDisplay()
    }

    private var nearbyBookmark: Bookmark? {
        LibraryStore.shared.bookmarks.first { $0.bookID == bookID && $0.chapterIndex == chapterIndex && abs($0.scrollFraction - currentFraction) < 0.01 }
    }

    private func applyPreferences(_ preferences: ReaderPreferences) {
        let contentChanged = self.preferences.fontSize != preferences.fontSize
            || self.preferences.lineSpacing != preferences.lineSpacing
            || self.preferences.typography != preferences.typography
            || self.preferences.paper != preferences.paper
            || self.preferences.turnStyle != preferences.turnStyle
        guard contentChanged else {
            self.preferences = preferences
            applyReadingChrome()
            return
        }
        if contentAvailable { pendingFraction = currentFraction }
        isRestoring = true
        let preservePage = self.preferences.turnStyle == .slide
        self.preferences = preferences
        applyReadingChrome()
        applyTypographyLayout()
        if contentAvailable { bodyLabel.attributedText = preferences.attributedText(displayedBody) }
        if contentAvailable { configurePages(preservePosition: preservePage) }
        applyPalette()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        contentStack.layoutIfNeeded()
        scrollView.layoutIfNeeded()
        isRestoring = false
        restorePositionIfNeeded()
        if isVisible, contentAvailable { persistProgress() }
    }

    private func applyReadingChrome() {
        chromeOverlay.isHidden = preferences.fullScreen
        readingInfoBar.accessibilityElementsHidden = !preferences.fullScreen
        updateSystemBars()
    }

    private func applyTypographyLayout() {
        let insets = preferences.typography.insets
        contentTopConstraint?.constant = insets.top
        contentLeadingConstraint?.constant = insets.left
        contentTrailingConstraint?.constant = -insets.right
        contentBottomConstraint?.constant = -insets.bottom
        contentWidthConstraint?.constant = -insets.left - insets.right
        chapterTitle.font = preferences.typography.font(size: preferences.titleFontSize)
        chapterTitle.textAlignment = preferences.typography.centeredTitle ? .center : .left
        if let chapter {
            chapterTitle.attributedText = preferences.attributedText(chapter.title, size: preferences.titleFontSize, isTitle: true)
        }
        contentStack.setCustomSpacing(preferences.typography.paragraphSpacing + 8, after: chapterTitle)
    }

    private func updateSystemBars() {
        setNeedsStatusBarAppearanceUpdate()
        navigationController?.setNeedsStatusBarAppearanceUpdate()
        tabBarController?.setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        navigationController?.setNeedsUpdateOfHomeIndicatorAutoHidden()
        tabBarController?.setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    @objc private func toggleFullScreen() {
        guard !readingToolsOpen else { return }
        preferences.fullScreen.toggle()
        preferences.save()
        applyReadingChrome()
        UIAccessibility.post(notification: .layoutChanged, argument: preferences.fullScreen ? nil : toolButtons.first)
    }

    @objc private func contentTapped(_ recognizer: UITapGestureRecognizer) {
        let x = recognizer.location(in: scrollView).x
        if x >= scrollView.bounds.width * 0.3 && x <= scrollView.bounds.width * 0.7 {
            toggleFullScreen()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var touchedView = touch.view
        while let current = touchedView, current !== scrollView {
            if current is UIControl { return false }
            touchedView = current.superview
        }
        return true
    }

    override func accessibilityPerformEscape() -> Bool {
        guard preferences.fullScreen else { return super.accessibilityPerformEscape() }
        toggleFullScreen()
        return true
    }

    private func configurePages(preservePosition: Bool) {
        let paged = preferences.turnStyle == .slide && contentAvailable
        pageReader.view.isHidden = !paged
        scrollView.isHidden = paged
        guard paged, let chapter, let book else { return }
        let text = NSMutableAttributedString(attributedString: preferences.attributedText(chapter.title + "\n", size: preferences.titleFontSize, isTitle: true))
        text.append(preferences.attributedText(displayedBody))
        pageReader.configure(
            text: text, paper: preferences.paper, insets: preferences.typography.insets, fraction: pendingFraction ?? 0,
            minimumContentSize: preferences.minimumPageContentSize,
            preservePosition: preservePosition, hasPrevious: chapterIndex > 0,
            hasNext: chapterIndex + 1 < book.chapters.count
        )
    }

    private func applyPalette() {
        let paper = preferences.paper
        view.backgroundColor = paper.background
        readingInfoBackground.backgroundColor = paper.background
        chapterInfoLabel.textColor = paper.ink.withAlphaComponent(0.72)
        pageInfoLabel.textColor = paper.ink.withAlphaComponent(0.72)
        topBarBackground.backgroundColor = paper.toolbarBackground
        footerBackground.backgroundColor = paper.toolbarBackground
        topBarSeparator.backgroundColor = paper.toolbarSeparator
        footerSeparator.backgroundColor = paper.toolbarSeparator
        bookLabel.textColor = paper.ink
        chapterTitle.textColor = paper.ink
        sourceLabel.textColor = paper.secondary
        chapterNumber.textColor = paper.secondary
        endLabel.textColor = paper.secondary
        statusLabel.textColor = paper.secondary
        scrollView.indicatorStyle = paper == .night ? .white : .black
        activity.color = paper.ink
        chapterEndButton.backgroundColor = paper.rule
        chapterEndButton.setTitleColor(paper.ink, for: .normal)
        for button in [backButton, bookmarkButton, detailsButton, previousButton, nextButton, retryButton, switchSourceButton] + toolButtons { button.tintColor = paper.ink }
        updateSystemBars()
    }

    private func startReadingSession() {
        guard isVisible, contentAvailable, !readingToolsOpen, UIApplication.shared.applicationState == .active, sessionStarted == nil else { return }
        sessionStarted = ProcessInfo.processInfo.systemUptime
    }

    private func finishReadingSession() {
        guard let start = sessionStarted else { return }
        sessionStarted = nil
        LibraryStore.shared.recordReading(seconds: max(0, ProcessInfo.processInfo.systemUptime - start))
    }

    @objc private func enterBackground() { saveWork?.cancel(); persistProgress(); finishReadingSession(); stopSpeaking() }
    @objc private func enterForeground() { startReadingSession() }
    @objc private func goBack() {
        if navigationController != nil { navigationController?.popViewController(animated: true) }
        else { dismiss(animated: true) }
    }
    @objc private func retryChapter() { showChapter(at: chapterIndex, fraction: pendingFraction ?? 0, saveCurrent: false) }
    @objc private func previousChapter() { showChapter(at: chapterIndex - 1) }
    @objc private func nextChapter() { showChapter(at: chapterIndex + 1) }

    @objc private func toggleBookmark() {
        guard contentAvailable, let chapter else { return }
        if let bookmark = nearbyBookmark {
            LibraryStore.shared.removeBookmark(id: bookmark.id)
            showToast("已移除此处书签")
        } else {
            LibraryStore.shared.addBookmark(bookID: bookID, chapterIndex: chapterIndex, scrollFraction: currentFraction, title: chapter.title)
            showToast("书签已夹在此页")
        }
        updateProgressDisplay()
    }

    @objc private func openContents() { presentContents(bookmarks: false) }
    @objc private func openBookmarks() { presentContents(bookmarks: true) }
    @objc private func openDetails() {
        navigationController?.pushViewController(YueduBookDetailViewController(bookID: bookID), animated: true)
    }

    @objc private func switchSource() {
        persistProgress()
        let progress = ReadingProgress(chapterIndex: chapterIndex, scrollFraction: currentFraction)
        navigationController?.pushViewController(
            OnlineSearchViewController(switchingBookID: bookID, switchingProgress: progress), animated: true
        )
    }

    private func presentContents(bookmarks: Bool) {
        guard let book else { return }
        let controller = ReaderContentsViewController(book: book, currentChapter: chapterIndex, bookmarksSelected: bookmarks)
        controller.onSelect = { [weak self] index, fraction in self?.showChapter(at: index, fraction: fraction) }
        controller.onBookmarksChanged = { [weak self] in self?.updateProgressDisplay() }
        controller.onDismiss = { [weak self] in self?.resumeAfterReadingTools() }
        presentSheet(controller)
    }

    @objc private func openSettings() {
        let settings = ReadingSettingsViewController()
        settings.purificationBook = book
        settings.purificationChapterTitle = chapter?.title ?? ""
        settings.purificationOriginal = originalBody.isEmpty ? nil : originalBody
        settings.onChange = { [weak self] preferences in self?.applyPreferences(preferences) }
        settings.onDismiss = { [weak self] in self?.resumeAfterReadingTools() }
        presentSheet(settings)
    }

    private func presentSheet(_ controller: UIViewController) {
        readingToolsOpen = true
        updateSystemBars()
        finishReadingSession()
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        navigation.navigationBar.tintColor = Theme.accent
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
        }
        navigation.presentationController?.delegate = self
        present(navigation, animated: true)
    }

    private func resumeAfterReadingTools() {
        readingToolsOpen = false
        updateSystemBars()
        startReadingSession()
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { resumeAfterReadingTools() }

    @objc private func openSpeechControls() {
        guard contentAvailable else { return }
        let alert = UIAlertController(title: "听一会儿书", message: "使用系统语音朗读当前章节。离开阅读页或切到后台后停止。", preferredStyle: .actionSheet)
        if synthesizer.isSpeaking || synthesizer.isPaused {
            if synthesizer.isPaused {
                alert.addAction(UIAlertAction(title: "继续朗读", style: .default) { [weak self] _ in self?.synthesizer.continueSpeaking() })
            } else {
                alert.addAction(UIAlertAction(title: "暂停朗读", style: .default) { [weak self] _ in self?.synthesizer.pauseSpeaking(at: .word) })
            }
            alert.addAction(UIAlertAction(title: "停止朗读", style: .destructive) { [weak self] _ in self?.stopSpeaking() })
        } else {
            alert.addAction(UIAlertAction(title: "从本章开始朗读", style: .default) { [weak self] _ in self?.startSpeaking() })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.sourceView = listenButton
        alert.popoverPresentationController?.sourceRect = listenButton.bounds
        present(alert, animated: true)
    }

    private func startSpeaking() {
        guard let chapter, !displayedBody.isEmpty else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            let utterance = AVSpeechUtterance(string: chapter.title + "。" + displayedBody)
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
            synthesizer.speak(utterance)
            updateSpeechButton(active: true)
        } catch { showMessage("无法开始朗读", error.localizedDescription) }
    }

    private func stopSpeaking() {
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
        synthesizer.stopSpeaking(at: .immediate)
        updateSpeechButton(active: false)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func updateSpeechButton(active: Bool) {
        var configuration = listenButton.configuration
        configuration?.title = active ? "朗读中" : "听书"
        configuration?.image = UIImage(systemName: active ? "waveform" : "headphones")
        listenButton.configuration = configuration
        listenButton.accessibilityLabel = active ? "朗读控制" : "听书"
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        updateSpeechButton(active: false)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func showToast(_ text: String) {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textAlignment = .center
        label.textColor = preferences.paper.background
        label.backgroundColor = preferences.paper.ink
        label.layer.cornerRadius = 20
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -20),
            label.heightAnchor.constraint(equalToConstant: 40),
            label.widthAnchor.constraint(equalToConstant: 184)
        ])
        UIAccessibility.post(notification: .announcement, argument: text)
        UIView.animate(withDuration: 0.25, delay: 1.5, options: .curveEaseOut) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }
}

/// Bars receive touches; the uncovered center belongs to the reader underneath.
private final class YueduReadingChromeOverlay: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let target = super.hitTest(point, with: event)
        return target === self ? nil : target
    }
}
