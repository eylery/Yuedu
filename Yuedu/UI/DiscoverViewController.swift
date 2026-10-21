import UIKit

final class DiscoverViewController: UITableViewController, UISearchResultsUpdating {
    private let model = YueduDiscoveryModel()
    private let search = UISearchController(searchResultsController: nil)
    private let groupButton = UIButton(type: .system)
    private let countLabel = UILabel()
    private var group: String?
    private var visibleSources: [BookSource] = []
    private var observer: NSObjectProtocol?

    private enum Row {
        case source
        case message(String, retry: Bool)
        case categories([SourceCategory])
        case heading(String)
    }
    private var rows: [[Row]] = []

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "发现"
        tableView.backgroundColor = Theme.bg
        tableView.separatorColor = Theme.line
        tableView.estimatedRowHeight = 64
        tableView.rowHeight = UITableView.automaticDimension
        tableView.keyboardDismissMode = .onDrag
        tableView.accessibilityIdentifier = "discovery.sources"
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "筛选书源名称、分组"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        let online = UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"), primaryAction: UIAction { [weak self] _ in
            self?.navigationController?.pushViewController(OnlineSearchViewController(), animated: true)
        })
        online.accessibilityLabel = "搜索书籍"
        online.accessibilityIdentifier = "discovery.searchBooks"
        let options = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [
            UIAction(title: "管理书源", image: UIImage(systemName: "square.stack.3d.up")) { [weak self] _ in self?.manageSources() },
            UIAction(title: "刷新分类", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.model.refreshExpanded() },
            UIAction(title: "全部收起", image: UIImage(systemName: "rectangle.compress.vertical")) { [weak self] _ in self?.model.collapseAll() }
        ]))
        options.accessibilityLabel = "发现选项"
        navigationItem.rightBarButtonItems = [options, online]
        buildFilterHeader()
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        model.onChange = { [weak self] in self?.render() }
        observer = NotificationCenter.default.addObserver(forName: .sourcesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.updateSources(SourceStore.shared.sources) }
        }
        model.updateSources(SourceStore.shared.sources)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        model.updateSources(SourceStore.shared.sources)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.suspend()
    }

    private func buildFilterHeader() {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 54))
        groupButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        groupButton.titleLabel?.lineBreakMode = .byTruncatingTail
        groupButton.contentHorizontalAlignment = .leading
        groupButton.showsMenuAsPrimaryAction = true
        groupButton.accessibilityIdentifier = "discovery.groups"
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = Theme.secondary
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = hstack([groupButton, UIView(), countLabel], spacing: 12)
        header.addSubview(row)
        row.pinEdges(to: header, insets: UIEdgeInsets(top: 4, left: 20, bottom: 8, right: 20))
        tableView.tableHeaderView = header
    }

    func updateSearchResults(for searchController: UISearchController) { render() }

    @objc private func refresh() {
        model.updateSources(SourceStore.shared.sources)
        model.refreshExpanded()
        refreshControl?.endRefreshing()
    }

    private func render() {
        guard isViewLoaded else { return }
        if let group, !model.groups.contains(group) { self.group = nil }
        visibleSources = model.filtered(query: search.searchBar.text ?? "", group: group)
        rows = visibleSources.map(makeRows)
        groupButton.setTitle((group ?? "全部分组") + " ▾", for: .normal)
        var actions = [UIAction(title: "全部分组", state: group == nil ? .on : .off) { [weak self] _ in
            self?.group = nil
            self?.render()
        }]
        actions += model.groups.map { name in
            UIAction(title: name, state: group == name ? .on : .off) { [weak self] _ in
                self?.group = name
                self?.render()
            }
        }
        groupButton.menu = UIMenu(children: actions)
        countLabel.text = "\(visibleSources.count) 个书源"
        tableView.reloadData()
        tableView.backgroundView = visibleSources.isEmpty ? emptyState() : nil
    }

    private func makeRows(_ source: BookSource) -> [Row] {
        guard model.expanded.contains(source.id) else { return [.source] }
        var result: [Row] = [.source]
        switch model.states[source.id] {
        case .waiting:
            result.append(.message("等待加载分类…", retry: false))
        case .loading, nil:
            result.append(.message("正在加载分类…", retry: false))
        case .failed(let message):
            result.append(.message("加载失败：\(message)\n轻点重试，或长按书源进入登录与设置。", retry: true))
        case .loaded(let categories):
            if categories.isEmpty {
                result.append(.message("此书源没有返回分类，轻点重新加载。", retry: true))
            }
            var batch: [SourceCategory] = []
            for category in categories {
                if category.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if !batch.isEmpty { result.append(.categories(batch)); batch.removeAll() }
                    result.append(.heading(category.title))
                } else {
                    batch.append(category)
                    if batch.count == 3 { result.append(.categories(batch)); batch.removeAll() }
                }
            }
            if !batch.isEmpty { result.append(.categories(batch)) }
        }
        return result
    }

    private func emptyState() -> UIView {
        let panel = UIView()
        let hasSources = !model.sources.isEmpty
        let title = textLabel(hasSources ? "没有匹配的书源" : "还没有可用的发现书源", size: 20, weight: .semibold)
        let detail = textLabel(hasSources ? "试试其他名称或切换分组。" : "导入并启用带发现规则的文字书源，\n这里就会显示它提供的分类和榜单。\n只有搜索功能的书源，可用右上角搜索书籍。", size: 14, color: Theme.secondary)
        title.textAlignment = .center
        detail.textAlignment = .center
        let button = UIButton(type: .system)
        button.setTitle(hasSources ? "清除筛选" : "管理书源", for: .normal)
        button.accessibilityIdentifier = "discovery.emptyAction"
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if hasSources {
                self.group = nil
                self.search.searchBar.text = ""
                self.render()
            } else { self.manageSources() }
        }, for: .touchUpInside)
        let stack = vstack([title, detail, button], spacing: 16)
        panel.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -30),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        return panel
    }

    private func manageSources() {
        navigationController?.pushViewController(SourcesViewController(), animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { visibleSources.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows[section].count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let source = visibleSources[indexPath.section]
        // Category rows contain controls; reuse is reset before applying a new row.
        let cell = tableView.dequeueReusableCell(withIdentifier: "discoveryRow") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "discoveryRow")
        cell.contentView.subviews.filter { $0.tag == 901 }.forEach { $0.removeFromSuperview() }
        cell.textLabel?.text = nil
        cell.detailTextLabel?.text = nil
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.imageView?.image = nil
        cell.selectionStyle = .none
        cell.accessibilityIdentifier = nil
        cell.accessibilityValue = nil
        cell.backgroundColor = Theme.surface
        cell.textLabel?.textColor = Theme.ink
        cell.textLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = Theme.secondary
        cell.detailTextLabel?.font = .systemFont(ofSize: 12)
        cell.detailTextLabel?.numberOfLines = 0
        switch rows[indexPath.section][indexPath.row] {
        case .source:
            cell.textLabel?.text = source.bookSourceName
            cell.detailTextLabel?.text = source.discoveryGroups.joined(separator: " · ")
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = "discovery.source.\(source.bookSourceName)"
            let expanded = model.expanded.contains(source.id)
            cell.accessibilityValue = expanded ? "已展开" : "已收起"
            let chevron = UIImageView(image: UIImage(systemName: expanded ? "chevron.down" : "chevron.right"))
            chevron.tintColor = Theme.secondary
            chevron.frame.size = CGSize(width: 14, height: 14)
            chevron.contentMode = .scaleAspectFit
            cell.accessoryView = chevron
        case .message(let message, let retry):
            cell.textLabel?.text = message
            cell.textLabel?.font = .systemFont(ofSize: 13)
            cell.textLabel?.textColor = retry ? Theme.accent : Theme.secondary
            cell.selectionStyle = retry ? .default : .none
            cell.accessibilityIdentifier = retry ? "discovery.retry.\(source.bookSourceName)" : "discovery.loading"
        case .heading(let title):
            cell.textLabel?.text = title
            cell.textLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            cell.textLabel?.textColor = Theme.secondary
        case .categories(let categories):
            let row = hstack([], spacing: 8)
            row.tag = 901
            row.distribution = .fillEqually
            for category in categories {
                let button = UIButton(type: .system)
                var config = UIButton.Configuration.tinted()
                config.title = category.title
                config.baseForegroundColor = Theme.accent
                config.baseBackgroundColor = Theme.pale
                config.cornerStyle = .medium
                config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 5, bottom: 12, trailing: 5)
                config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                    var result = attributes
                    result.font = .systemFont(ofSize: 13, weight: .medium)
                    return result
                }
                button.configuration = config
                button.titleLabel?.numberOfLines = 0
                button.accessibilityIdentifier = "discovery.category.\(category.title)"
                button.addAction(UIAction { [weak self] _ in
                    guard let self, let current = SourceStore.shared.source(id: source.id), current.hasDiscovery else { return }
                    self.search.isActive = false
                    self.navigationController?.pushViewController(SourceExploreViewController(source: current, category: category), animated: true)
                }, for: .touchUpInside)
                row.addArrangedSubview(button)
            }
            while row.arrangedSubviews.count < 3 { row.addArrangedSubview(UIView()) }
            cell.contentView.addSubview(row)
            row.pinEdges(to: cell.contentView, insets: UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 12))
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let source = visibleSources[indexPath.section]
        switch rows[indexPath.section][indexPath.row] {
        case .source: model.toggle(source.id)
        case .message(_, let retry): if retry { model.retry(source.id) }
        default: break
        }
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.row == 0 else { return nil }
        let source = visibleSources[indexPath.section]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "刷新分类", image: UIImage(systemName: "arrow.clockwise")) { _ in
                    self?.model.retry(source.id)
                },
                UIAction(title: "登录与设置", image: UIImage(systemName: "person.crop.circle")) { _ in
                    self?.navigationController?.pushViewController(SourceLoginViewController(source: source), animated: true)
                }
            ])
        }
    }
}
