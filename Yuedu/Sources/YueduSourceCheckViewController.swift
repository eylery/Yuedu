import UIKit

final class YueduSourceCheckViewController: UITableViewController {
    private let ids: Set<UUID>
    private let keyword = UITextField()
    private let mode = UISegmentedControl(items: ["仅搜索", "搜索 → 目录 → 首章"])
    private let checker = YueduSourceChecker.shared
    private var sources: [BookSource] = []
    private var observers: [NSObjectProtocol] = []

    init(ids: Set<UUID>) {
        self.ids = ids
        super.init(style: .insetGrouped)
        hidesBottomBarWhenPushed = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "书源检测"
        tableView.backgroundColor = Theme.bg
        tableView.keyboardDismissMode = .onDrag
        tableView.accessibilityIdentifier = "sourceChecks.list"
        keyword.placeholder = "测试书名或关键词"
        keyword.text = UserDefaults.standard.string(forKey: "sources.checkKeyword") ?? "斗罗大陆"
        keyword.borderStyle = .roundedRect
        keyword.clearButtonMode = .whileEditing
        keyword.accessibilityIdentifier = "sourceChecks.keyword"
        mode.selectedSegmentIndex = 0
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 112))
        let stack = vstack([keyword, mode], spacing: 12)
        header.addSubview(stack)
        stack.pinEdges(to: header, insets: UIEdgeInsets(top: 8, left: 20, bottom: 12, right: 20))
        tableView.tableHeaderView = header
        for name in [Notification.Name.sourcesChanged, .yueduSourceChecksChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            })
        }
        render()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func render() {
        sources = SourceStore.shared.sources.filter { ids.contains($0.id) }
        let start = UIBarButtonItem(title: checker.isRunning ? "停止" : "开始检测", primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            if self.checker.isRunning { self.checker.cancel() }
            else { self.start(self.ids) }
        })
        start.accessibilityIdentifier = "sourceChecks.start"
        let retry = UIBarButtonItem(title: "重试失败", primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            let failed = Set(self.sources.filter { self.checker.result(for: $0)?.outcome == .failed }.map(\.id))
            self.start(failed)
        })
        retry.isEnabled = !checker.isRunning && sources.contains { checker.result(for: $0)?.outcome == .failed }
        navigationItem.rightBarButtonItems = [start, retry]
        keyword.isEnabled = !checker.isRunning
        mode.isEnabled = !checker.isRunning
        tableView.reloadData()
    }

    private func start(_ ids: Set<UUID>) {
        view.endEditing(true)
        do {
            let text = keyword.text ?? ""
            try checker.start(ids: ids, keyword: text, mode: mode.selectedSegmentIndex == 0 ? .search : .reading)
            UserDefaults.standard.set(text, forKey: "sources.checkKeyword")
        } catch { showMessage("无法开始检测", error.localizedDescription) }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 1 : sources.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 1 ? "本次选择 · \(sources.count) 个" : nil }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "检测会按顺序实际访问所选书源，包括已停用的书源，每阶段最多等待 20 秒。无搜索结果不等于失效；首章失败也可能需要登录。结果仅代表此次检测，配置修改后需重测。切入后台停止检测。" : nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        cell.textLabel?.textColor = Theme.ink
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = Theme.secondary
        cell.detailTextLabel?.numberOfLines = 0
        if indexPath.section == 0 {
            cell.textLabel?.text = checker.message
            cell.textLabel?.font = .systemFont(ofSize: 13)
            cell.selectionStyle = .none
        } else {
            let source = sources[indexPath.row]
            cell.textLabel?.text = source.bookSourceName
            cell.accessibilityIdentifier = "sourceChecks.\(source.bookSourceName)"
            if let record = checker.result(for: source) {
                cell.detailTextLabel?.text = "\(record.title) · \(record.stage) · \(String(format: "%.1f", record.duration)) 秒\n\(record.detail)"
                cell.accessoryType = .detailButton
            } else { cell.detailTextLabel?.text = "尚未检测或配置已修改" }
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        showRecord(indexPath)
    }
    override func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) { showRecord(indexPath) }
    private func showRecord(_ indexPath: IndexPath) {
        guard indexPath.section == 1, let record = checker.result(for: sources[indexPath.row]) else { return }
        let date = DateFormatter.localizedString(from: record.date, dateStyle: .short, timeStyle: .short)
        showMessage(record.title, "\(record.mode.title) · \(record.stage)\n关键词：\(record.keyword)\n时间：\(date)\n\n\(record.detail)")
    }
}
