import UIKit
import CoreText

/// A real, interactive UIKit paper curl. Only the current chapter is paginated.
final class YueduPageReaderController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    var onPositionChanged: (() -> Void)?
    var onChapterTurn: ((Int) -> Void)?
    private let controller = UIPageViewController(
        transitionStyle: .pageCurl, navigationOrientation: .horizontal,
        options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue]
    )
    private var text = NSAttributedString(string: "")
    private var paper = ReaderPreferences.Paper.ivory
    private var ranges: [NSRange] = []
    private var pageIndex = 0
    private var layoutSize = CGSize.zero
    private var initialFraction = 0.0
    private var preservedOffset: Int?
    private var canGoBack = false
    private var canGoForward = false
    private var transitioning = false
    private var pendingUpdate: (() -> Void)?
    private let pageInsets = UIEdgeInsets(top: 20, left: 28, bottom: 32, right: 28)

    var isReady: Bool { !ranges.isEmpty && layoutSize == contentSize }
    var fraction: Double { ranges.count > 1 ? Double(pageIndex) / Double(ranges.count - 1) : 1 }
    var pageDescription: String { "\(pageIndex + 1)/\(max(1, ranges.count)) 页" }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "reader.pagedContent"
        controller.dataSource = self
        controller.delegate = self
        controller.isDoubleSided = false
        addChild(controller)
        view.addSubview(controller.view)
        controller.view.pinEdges(to: view)
        controller.didMove(toParent: self)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        view.addGestureRecognizer(tap)
    }

    func configure(text: NSAttributedString, paper: ReaderPreferences.Paper, fraction: Double,
                   preservePosition: Bool, hasPrevious: Bool, hasNext: Bool) {
        if transitioning {
            pendingUpdate = { [weak self] in
                self?.configure(text: text, paper: paper, fraction: fraction,
                                preservePosition: preservePosition, hasPrevious: hasPrevious, hasNext: hasNext)
            }
            return
        }
        preservedOffset = preservePosition && self.text.string == text.string && ranges.indices.contains(pageIndex)
            ? ranges[pageIndex].location : nil
        self.text = text
        self.paper = paper
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
        guard !transitioning, contentSize.width >= 40, contentSize.height >= 40,
              contentSize != layoutSize, text.length > 0 else { return }
        if layoutSize != .zero, ranges.indices.contains(pageIndex) {
            preservedOffset = ranges[pageIndex].location
        }
        layoutSize = contentSize
        ranges = YueduPagination.ranges(for: text, size: layoutSize)
        pageIndex = preservedOffset.map { YueduPagination.page(containing: $0, in: ranges) }
            ?? YueduPagination.page(for: initialFraction, count: ranges.count)
        preservedOffset = nil
        controller.setViewControllers([page(at: pageIndex)], direction: .forward, animated: false)
        onPositionChanged?()
    }

    private func page(at index: Int) -> YueduPaperPage {
        if ranges.indices.contains(index) {
            return YueduPaperPage(index: index, text: text, range: ranges[index], paper: paper, insets: pageInsets)
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
        guard let page = viewController as? YueduPaperPage else { return nil }
        let previous = page.index - 1
        return previous >= 0 || (previous == -1 && canGoBack) ? self.page(at: previous) : nil
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? YueduPaperPage else { return nil }
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
        let x = recognizer.location(in: view).x
        if x < view.bounds.width * 0.3 { turn(-1) }
        else if x > view.bounds.width * 0.7 { turn(1) }
    }

    func turn(_ direction: Int) {
        guard !transitioning, !ranges.isEmpty else { return }
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
    private let text: NSAttributedString
    private let range: NSRange
    private let paper: ReaderPreferences.Paper
    private let insets: UIEdgeInsets

    init(index: Int, text: NSAttributedString, range: NSRange, paper: ReaderPreferences.Paper, insets: UIEdgeInsets) {
        self.index = index
        self.text = text
        self.range = range
        self.paper = paper
        self.insets = insets
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let canvas = YueduPaperCanvas()
        canvas.text = text
        canvas.range = range
        canvas.insets = insets
        canvas.backgroundColor = paper.background
        canvas.isOpaque = true
        canvas.contentMode = .redraw
        canvas.isAccessibilityElement = true
        canvas.accessibilityIdentifier = "reader.pageText"
        canvas.accessibilityLabel = (text.string as NSString).substring(with: range)
        canvas.accessibilityTraits = .staticText
        view = canvas
    }
}

private final class YueduPaperCanvas: UIView {
    var text = NSAttributedString(string: "")
    var range = NSRange(location: 0, length: 0)
    var insets = UIEdgeInsets.zero

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), range.length > 0 else { return }
        let area = bounds.inset(by: insets)
        context.saveGState()
        context.translateBy(x: area.minX, y: area.maxY)
        context.scaleBy(x: 1, y: -1)
        let setter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(origin: .zero, size: area.size), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: range.location, length: range.length), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}
