import UIKit
import CoreText

/// Interactive horizontal page sliding. Only the current chapter is paginated.
final class YueduPageReaderController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    var onPositionChanged: (() -> Void)?
    var onChapterTurn: ((Int) -> Void)?
    var onCenterTap: (() -> Void)?
    private let controller = UIPageViewController(
        transitionStyle: .scroll,
        navigationOrientation: .horizontal
    )
    private var text = NSAttributedString(string: "")
    private var paper = ReaderPreferences.Paper.ivory
    private var ranges: [NSRange] = []
    private var framesetter: CTFramesetter?
    private var paginationTask: Task<Void, Never>?
    private var paginationGeneration = UUID()
    private var pendingSize: CGSize?
    private var paginationEnabled = true
    private let loading = UIActivityIndicatorView(style: .medium)
    private var pageIndex = 0
    private var layoutSize = CGSize.zero
    private var initialFraction = 0.0
    private var preservedOffset: Int?
    private var canGoBack = false
    private var canGoForward = false
    private var transitioning = false
    private var pendingUpdate: (() -> Void)?
    private var requestedInsets = UIEdgeInsets(top: 20, left: 28, bottom: 32, right: 28)
    private var minimumContentSize = CGSize(width: 84, height: 60)
    private var pageInsets: UIEdgeInsets {
        YueduTypography.fittedPageInsets(requestedInsets, viewport: view.bounds.size, minimumContent: minimumContentSize)
    }

    var isReady: Bool { pendingSize == nil && !ranges.isEmpty && layoutSize == contentSize }
    var fraction: Double {
        guard isReady else { return initialFraction }
        return ranges.count > 1 ? Double(pageIndex) / Double(ranges.count - 1) : 1
    }
    var currentPageNumber: Int { pageIndex + 1 }
    var totalPageCount: Int { ranges.count }
    var pageDescription: String { "\(pageIndex + 1)/\(max(1, ranges.count)) 页" }

    deinit { paginationTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "reader.pagedContent"
        controller.dataSource = self
        controller.delegate = self
        addChild(controller)
        view.addSubview(controller.view)
        controller.view.pinEdges(to: view)
        controller.didMove(toParent: self)
        loading.hidesWhenStopped = true
        loading.accessibilityIdentifier = "reader.paginationLoading"
        loading.accessibilityLabel = "正在排版"
        loading.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loading)
        NSLayoutConstraint.activate([
            loading.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loading.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        view.addGestureRecognizer(tap)
    }

    func configure(text: NSAttributedString, paper: ReaderPreferences.Paper, insets: UIEdgeInsets, fraction: Double,
                   minimumContentSize: CGSize,
                   preservePosition: Bool, hasPrevious: Bool, hasNext: Bool) {
        if transitioning {
            pendingUpdate = { [weak self] in
                self?.configure(text: text, paper: paper, insets: insets, fraction: fraction,
                                minimumContentSize: minimumContentSize,
                                preservePosition: preservePosition, hasPrevious: hasPrevious, hasNext: hasNext)
            }
            return
        }
        preservedOffset = preservePosition && self.text.string == text.string && ranges.indices.contains(pageIndex)
            ? ranges[pageIndex].location : nil
        paginationTask?.cancel()
        paginationGeneration = UUID()
        pendingSize = nil
        paginationEnabled = true
        self.text = NSAttributedString(attributedString: text)
        self.paper = paper
        requestedInsets = insets
        self.minimumContentSize = minimumContentSize
        initialFraction = fraction
        canGoBack = hasPrevious
        canGoForward = hasNext
        layoutSize = .zero
        loadViewIfNeeded()
        view.backgroundColor = paper.background
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private var contentSize: CGSize {
        CGSize(width: max(0, view.bounds.width - pageInsets.left - pageInsets.right),
               height: max(0, view.bounds.height - pageInsets.top - pageInsets.bottom))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = contentSize
        guard paginationEnabled, !transitioning, size.width >= 40, size.height >= 40,
              size != layoutSize, size != pendingSize, text.length > 0 else { return }
        if layoutSize != .zero, ranges.indices.contains(pageIndex) {
            preservedOffset = ranges[pageIndex].location
        }
        paginationTask?.cancel()
        let generation = UUID()
        paginationGeneration = generation
        pendingSize = size
        let offset = preservedOffset
        let fraction = initialFraction
        let text = text
        controller.view.isHidden = true
        controller.view.isUserInteractionEnabled = false
        loading.color = paper.ink
        loading.startAnimating()
        onPositionChanged?()
        paginationTask = Task { [weak self] in
            do {
                let layout = try await YueduPagination.layoutInBackground(for: text, size: size)
                try Task.checkCancellation()
                guard let self, self.paginationGeneration == generation else { return }
                self.ranges = layout.ranges
                // Rendering owns a separate main-thread framesetter, reused by
                // the visible pages. Never share the worker's Core Text objects.
                self.framesetter = CTFramesetterCreateWithAttributedString(text)
                self.layoutSize = size
                self.pendingSize = nil
                self.pageIndex = offset.map { YueduPagination.page(containing: $0, in: layout.ranges) }
                    ?? YueduPagination.page(for: fraction, count: layout.ranges.count)
                self.preservedOffset = nil
                self.initialFraction = self.fraction
                self.controller.setViewControllers([self.page(at: self.pageIndex)], direction: .forward, animated: false)
                self.controller.view.isHidden = false
                self.controller.view.isUserInteractionEnabled = true
                self.loading.stopAnimating()
                self.paginationTask = nil
                self.onPositionChanged?()
            } catch {
                guard let self, self.paginationGeneration == generation else { return }
                self.pendingSize = nil
                self.loading.stopAnimating()
                self.paginationTask = nil
            }
        }
    }

    func cancelPagination() {
        paginationEnabled = false
        paginationTask?.cancel()
        paginationTask = nil
        paginationGeneration = UUID()
        pendingSize = nil
        loading.stopAnimating()
    }

    private func page(at index: Int) -> YueduPaperPage {
        if ranges.indices.contains(index) {
            let page = YueduPaperPage(index: index, text: text, range: ranges[index], paper: paper, insets: pageInsets, framesetter: framesetter)
            page.onToggleFullScreen = { [weak self] in self?.onCenterTap?() }
            return page
        }
        let title = index < 0 ? "上一章" : "下一章"
        let content = NSAttributedString(string: title, attributes: [
            .font: UIFont.readingSerif(24), .foregroundColor: paper.ink
        ])
        return YueduPaperPage(index: index, text: content, range: NSRange(location: 0, length: content.length),
                             paper: paper, insets: pageInsets)
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard isReady, let page = viewController as? YueduPaperPage else { return nil }
        let previous = page.index - 1
        return previous >= 0 || (previous == -1 && canGoBack) ? self.page(at: previous) : nil
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard isReady, let page = viewController as? YueduPaperPage else { return nil }
        let next = page.index + 1
        return next < ranges.count || (next == ranges.count && canGoForward) ? self.page(at: next) : nil
    }

    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        transitioning = true
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        finishTurn(completed: completed)
    }

    private func finishTurn(completed: Bool) {
        transitioning = false
        if completed, let visible = controller.viewControllers?.first as? YueduPaperPage {
            if visible.index < 0 {
                onChapterTurn?(-1)
            } else if visible.index >= ranges.count {
                onChapterTurn?(1)
            } else {
                pageIndex = visible.index
                initialFraction = fraction
                onPositionChanged?()
            }
        }
        let update = pendingUpdate
        pendingUpdate = nil
        update?()
        view.setNeedsLayout()
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard !transitioning else { return }
        let x = recognizer.location(in: view).x
        if x < view.bounds.width * 0.3 { turn(-1) }
        else if x > view.bounds.width * 0.7 { turn(1) }
        else { onCenterTap?() }
    }

    func turn(_ direction: Int) {
        guard !transitioning, isReady else { return }
        let index = pageIndex + direction
        guard index >= 0 || canGoBack, index < ranges.count || canGoForward else { return }
        transitioning = true
        controller.setViewControllers([page(at: index)], direction: direction > 0 ? .forward : .reverse,
                                      animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] finished in
            self?.finishTurn(completed: finished)
        }
    }
}

private final class YueduPaperPage: UIViewController {
    let index: Int
    var onToggleFullScreen: (() -> Void)?
    private let text: NSAttributedString
    private let range: NSRange
    private let paper: ReaderPreferences.Paper
    private let insets: UIEdgeInsets
    private let framesetter: CTFramesetter?

    init(index: Int, text: NSAttributedString, range: NSRange, paper: ReaderPreferences.Paper, insets: UIEdgeInsets, framesetter: CTFramesetter? = nil) {
        self.index = index
        self.text = text
        self.range = range
        self.paper = paper
        self.insets = insets
        self.framesetter = framesetter
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let canvas = YueduPaperCanvas()
        canvas.text = text
        canvas.range = range
        canvas.framesetter = framesetter
        canvas.insets = insets
        canvas.backgroundColor = paper.background
        canvas.isOpaque = true
        canvas.contentMode = .redraw
        canvas.isAccessibilityElement = true
        canvas.accessibilityIdentifier = "reader.pageText"
        canvas.accessibilityLabel = (text.string as NSString).substring(with: range)
        canvas.accessibilityTraits = .staticText
        canvas.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "切换全屏阅读") { [weak self] _ in
            self?.onToggleFullScreen?()
            return true
        }]
        view = canvas
    }
}

private final class YueduPaperCanvas: UIView {
    var text = NSAttributedString(string: "")
    var framesetter: CTFramesetter?
    var range = NSRange(location: 0, length: 0)
    var insets = UIEdgeInsets.zero

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        // A reused opaque canvas must erase the previous glyphs before drawing
        // after rotation or a viewport change.
        context.setFillColor((backgroundColor ?? .clear).cgColor)
        context.fill(bounds)
        guard range.length > 0 else { return }
        let area = bounds.inset(by: insets)
        context.saveGState()
        context.translateBy(x: area.minX, y: area.maxY)
        context.scaleBy(x: 1, y: -1)
        let setter = framesetter ?? CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(origin: .zero, size: area.size), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: range.location, length: range.length), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}
