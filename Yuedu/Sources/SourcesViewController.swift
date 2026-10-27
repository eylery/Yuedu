import UIKit
import UniformTypeIdentifiers

@MainActor
final class SourcesViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate, UISearchResultsUpdating {
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let countLabel = UILabel()
    private var operation: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var lastImportReport: SourceImportReport?
    private let search = UISearchController(searchResultsController: nil)
    private let groupButton = UIButton(type: .system)
    private let filterButton = UIButton(type: .system)
    private var visible: [BookSource] = []
    private var selected = Set<UUID>()
    private var managing = false
    private var group: String?
    private var filter: YueduSourceFilter = .all
    private var sorting: YueduSourceSort = .imported
    private var checkObserver: NSObjectProtocol?
    private var batchBar: UIView?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "书源"
        navigationItem.leftItemsSupplementBackButton = true
        view.backgroundColor = Theme.bg
        updateImportMenu()
        table.backgroundColor = Theme.bg
        table.separatorColor = Theme.line
        table.dataSource = self
        table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 86
        table.accessibilityIdentifier = "sources.list"
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "搜索书源名称、网址或分组"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        view.addSubview(table)
        table.pinEdges(to: view)
        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 108))
        countLabel.font = .yueduUI(ofSize: 12, weight: .medium)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = Theme.accent
        countLabel.numberOfLines = 2
        countLabel.accessibilityIdentifier = "sources.count"
        groupButton.showsMenuAsPrimaryAction = true
        groupButton.accessibilityIdentifier = "sources.groups"
        filterButton.showsMenuAsPrimaryAction = true
        filterButton.accessibilityIdentifier = "sources.filter"
        let stack = UIStackView(arrangedSubviews: [countLabel, hstack([groupButton, UIView(), filterButton], spacing: 12)])
        stack.axis = .vertical
        stack.spacing = 13
        header.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -18)
        ])
        table.tableHeaderView = header
        observer = NotificationCenter.default.addObserver(forName: .sourcesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        checkObserver = NotificationCenter.default.addObserver(forName: .yueduSourceChecksChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    deinit {
        operation?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let checkObserver { NotificationCenter.default.removeObserver(checkObserver) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        table.yueduFitHeader()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let error = SourceStore.shared.persistenceError { showMessage("书源存储异常", error) }
    }

    private func reload() {
        let sources = SourceStore.shared.sources
        let groups = Array(Set(sources.flatMap(\.discoveryGroups))).sorted()
        if let group, !group.isEmpty, !groups.contains(group) { self.group = nil }
        visible = YueduSourceChecker.shared.filtered(query: search.searchBar.text ?? "", group: group, filter: filter, sort: sorting)
        selected.formIntersection(visible.map(\.id))
        let incompatible = sources.filter { !$0.isCompatible }.count
        countLabel.text = "显示 \(visible.count)/\(sources.count) 个 · \(sources.filter(\.enabled).count) 个已启用" + (managing ? " · 已选 \(selected.count) 个" : incompatible > 0 ? "\n\(incompatible) 个配置需修正，已停用" : "")
        groupButton.setTitle((group.map { $0.isEmpty ? "未分组" : $0 } ?? "全部分组") + " ▾", for: .normal)
        groupButton.menu = UIMenu(children: [(nil as String?, "全部分组"), ("", "未分组")] .map { value, title in
            UIAction(title: title, state: group == value ? .on : .off) { [weak self] _ in self?.group = value; self?.changedFilter() }
        } + groups.map { name in
            UIAction(title: name, state: group == name ? .on : .off) { [weak self] _ in self?.group = name; self?.changedFilter() }
        })
        filterButton.setTitle(filter.title + " ▾", for: .normal)
        filterButton.menu = UIMenu(children: YueduSourceFilter.allCases.map { value in
            UIAction(title: value.title, state: filter == value ? .on : .off) { [weak self] _ in self?.filter = value; self?.changedFilter() }
        } + [UIMenu(title: "排序", children: YueduSourceSort.allCases.map { value in
            UIAction(title: value.title, state: sorting == value ? .on : .off) { [weak self] _ in self?.sorting = value; self?.reload() }
        })])
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: managing ? "完成" : "管理", primaryAction: UIAction { [weak self] _ in
            self?.managing.toggle()
            self?.selected.removeAll()
            self?.reload()
        })
        table.reloadData()
        renderBatchBar()
    }

    func updateSearchResults(for searchController: UISearchController) { changedFilter() }
    private func changedFilter() { selected.removeAll(); reload() }

    private func updateImportMenu() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "plus"), menu: UIMenu(children: [
            UIAction(title: "从文件导入", image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in self?.importFile() },
            UIAction(title: "从网址导入", image: UIImage(systemName: "link")) { [weak self] _ in self?.importURL() },
            UIAction(title: "粘贴 JSON 导入", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.importText() },
            UIAction(title: "检测当前列表", image: UIImage(systemName: "stethoscope")) { [weak self] _ in
                guard let self else { return }
                self.openChecks(Set(self.visible.map(\.id)))
            },
            UIAction(title: "新建书源", image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in self?.edit(nil) },
            UIAction(title: "上次导入详情", image: UIImage(systemName: "doc.text.magnifyingglass"), attributes: lastImportReport == nil ? .disabled : []) { [weak self] _ in
                guard let self, let report = self.lastImportReport else { return }
                self.showImportDetails(report)
            },
            UIAction(title: "导出全部书源", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.exportSources() }
        ]))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "添加与管理书源"
    }

    func numberOfSections(in tableView: UITableView) -> Int { 2 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? max(1, visible.count) : 1 }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "我的书源" : "使用指南" }
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "开关控制书源启用；点“···”可设置发现页显示。隐藏发现仍可搜索，点书源名称可编辑。" : "导入 Legado 文字书源；漫画、有声和视频等类型会排除。需要登录或自定义参数的书源，请先打开“登录与设置”。"
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        cell.textLabel?.textColor = Theme.ink
        cell.detailTextLabel?.textColor = Theme.secondary
        cell.textLabel?.font = .yueduUI(ofSize: 16, weight: .medium)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.font = .yueduUI(ofSize: 12)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.numberOfLines = 2
        cell.tintColor = Theme.accent
        if indexPath.section == 1 {
            cell.textLabel?.text = "让第一本书，与你相遇"
            cell.detailTextLabel?.text = "导入 JSON 书源，或从示例开始编辑"
            cell.imageView?.image = UIImage(systemName: "book.closed")
            cell.accessoryType = .disclosureIndicator
        } else if visible.isEmpty {
            cell.textLabel?.text = SourceStore.shared.sources.isEmpty ? "添加你的第一个书源" : "没有匹配的书源"
            cell.detailTextLabel?.text = SourceStore.shared.sources.isEmpty ? "点击右上角 ＋，从文件或网址导入" : "轻点清除搜索和筛选"
            cell.imageView?.image = UIImage(systemName: "plus.circle")
        } else {
            let source = visible[indexPath.row]
            cell.accessibilityIdentifier = "sources.row.\(source.bookSourceName)"
            let compatibilityIssues = source.compatibilityIssues
            cell.textLabel?.text = source.bookSourceName
            let host = URL(string: source.bookSourceUrl)?.host ?? source.bookSourceUrl
            if let reason = compatibilityIssues.first {
                cell.detailTextLabel?.text = "配置需修正 · \(SourceImportDisplay.reason(reason))"
                cell.detailTextLabel?.textColor = UIColor(red: 0.56, green: 0.36, blue: 0.18, alpha: 1)
            } else {
                cell.detailTextLabel?.text = "\(source.bookSourceGroup)\n\(host)"
            }
            if let result = YueduSourceChecker.shared.result(for: source) {
                cell.detailTextLabel?.text = (cell.detailTextLabel?.text ?? "") + "\n\(result.title) · \(result.stage) · \(String(format: "%.1f", result.duration)) 秒"
            }
            var content = cell.defaultContentConfiguration()
            content.text = source.bookSourceName
            content.textProperties.font = .yueduUI(ofSize: 16, weight: .medium)
            content.textProperties.color = Theme.ink
            content.textProperties.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 0 : 2
            content.secondaryTextProperties.font = .yueduUI(ofSize: 12)
            content.secondaryTextProperties.color = cell.detailTextLabel?.textColor ?? Theme.secondary
            content.secondaryTextProperties.numberOfLines = 0
            let detail = (cell.detailTextLabel?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let discoveryStatus = source.supportsDiscovery
                ? (source.isDiscoveryEnabled ? "发现：显示" : "发现：隐藏") : "无发现分类"
            content.secondaryText = detail + "\n" + discoveryStatus
            content.textToSecondaryTextVerticalPadding = 6
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 12)
            cell.contentConfiguration = content
            if managing {
                cell.accessoryType = selected.contains(source.id) ? .checkmark : .none
                cell.accessibilityValue = selected.contains(source.id) ? "已选择" : "未选择"
                return cell
            }
            let toggle = UISwitch()
            toggle.isOn = compatibilityIssues.isEmpty && source.enabled
            toggle.isEnabled = compatibilityIssues.isEmpty
            toggle.onTintColor = Theme.accent
            toggle.accessibilityLabel = compatibilityIssues.isEmpty ? "启用\(source.bookSourceName)" : "\(source.bookSourceName)，配置需修正，已停用"
            toggle.accessibilityHint = compatibilityIssues.isEmpty ? "停用后不参与在线搜索和发现" : "点击书源可编辑配置并查看兼容性说明"
            toggle.accessibilityIdentifier = "sources.enabled.\(source.id.uuidString)"
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                do { try SourceStore.shared.setEnabled(id: source.id, enabled: toggle?.isOn ?? false) }
                catch { toggle?.isOn = source.enabled; self?.showMessage("无法更新书源", error.localizedDescription) }
            }, for: .valueChanged)
            let more = UIButton(type: .system)
            more.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19)), for: .normal)
            more.tintColor = Theme.secondary
            more.accessibilityLabel = "\(source.bookSourceName)更多操作"
            more.accessibilityIdentifier = "sources.more.\(source.id.uuidString)"
            more.accessibilityHint = "设置发现显示、编辑书源或登录"
            more.showsMenuAsPrimaryAction = true
            more.menu = sourceMenu(source)
            more.widthAnchor.constraint(equalToConstant: 44).isActive = true
            more.heightAnchor.constraint(equalToConstant: 44).isActive = true
            let controls = hstack([toggle, more], spacing: 14)
            controls.frame.size = controls.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            cell.accessoryView = controls
        }
        return cell
    }

    private func sourceMenu(_ source: BookSource) -> UIMenu {
        var actions: [UIAction] = []
        if source.supportsDiscovery {
            actions.append(UIAction(title: source.isDiscoveryEnabled ? "在发现页隐藏" : "在发现页显示",
                                    image: UIImage(systemName: source.isDiscoveryEnabled ? "eye.slash" : "eye")) { [weak self] _ in
                do {
                    try SourceStore.shared.manage([source.id]) { $0.isDiscoveryEnabled = !source.isDiscoveryEnabled }
                } catch {
                    self?.showMessage("无法更新发现显示", error.localizedDescription)
                }
            })
        }
        actions.append(UIAction(title: "编辑书源", image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
            self?.edit(SourceStore.shared.source(id: source.id) ?? source)
        })
        actions.append(UIAction(title: "登录与设置", image: UIImage(systemName: "person.crop.circle")) { [weak self] _ in
            let current = SourceStore.shared.source(id: source.id) ?? source
            self?.navigationController?.pushViewController(SourceLoginViewController(source: current), animated: true)
        })
        return UIMenu(children: actions)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 { showGuide() }
        else if visible.isEmpty {
            if SourceStore.shared.sources.isEmpty { importFile() }
            else { group = nil; filter = .all; search.searchBar.text = ""; changedFilter() }
        } else if managing {
            let id = visible[indexPath.row].id
            if !selected.insert(id).inserted { selected.remove(id) }
            reload()
        } else { edit(visible[indexPath.row]) }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 0, !visible.isEmpty, !managing else { return nil }
        let source = visible[indexPath.row]
        let action = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in
            let alert = UIAlertController(title: "删除“\(source.bookSourceName)”？", message: "已缓存的章节仍可阅读；未缓存章节将无法继续加载。建议先导出书源备份。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in done(false) })
            alert.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in
                do { try SourceStore.shared.remove(id: source.id); done(true) }
                catch { self?.showMessage("删除失败", error.localizedDescription); done(false) }
            })
            self?.present(alert, animated: true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }

    private func importFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .plainText, .data], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        beginImport(status: "正在读取并解析书源…") {
            try await SourceStore.shared.importFile(url)
        }
    }

    private func importURL() {
        let alert = UIAlertController(title: "从网址导入", message: "输入返回书源 JSON 的 HTTP 或 HTTPS 地址。支持最大 50 MB 的书源合集。", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://example.com/sources.json"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "导入", style: .default) { [weak self, weak alert] _ in
            guard let self, let text = alert?.textFields?.first?.text else { return }
            self.beginImport(status: "正在下载书源…") { [weak self] in
                let url = try SourceURL.resolve(text, relativeTo: nil)
                let (data, _) = try await SourceEngine.shared.downloadSourceCollection(url)
                try Task.checkCancellation()
                self?.countLabel.text = "下载完成，正在解析书源…"
                return try await SourceStore.shared.importDataAsync(data)
            }
        })
        present(alert, animated: true)
    }

    private func beginImport(status: String, load: @escaping @MainActor () async throws -> SourceImportReport) {
        operation?.cancel()
        navigationItem.rightBarButtonItem?.isEnabled = false
        countLabel.text = status
        operation = Task { [weak self] in
            do {
                let report = try await load()
                try Task.checkCancellation()
                self?.lastImportReport = report
                self?.showImportResult(report)
            } catch is CancellationError { }
            catch { self?.showMessage("导入失败", error.localizedDescription) }
            self?.updateImportMenu()
            self?.reload()
        }
    }

    private func showImportResult(_ report: SourceImportReport) {
        let alert = UIAlertController(title: SourceImportDisplay.title(report), message: SourceImportDisplay.summary(report), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "查看详情", style: .default) { [weak self] _ in self?.showImportDetails(report) })
        alert.addAction(UIAlertAction(title: "完成", style: .cancel))
        present(alert, animated: true)
    }

    private func showImportDetails(_ report: SourceImportReport) {
        navigationController?.pushViewController(SourceImportReportViewController(report: report), animated: true)
    }

    private func exportSources(ids: Set<UUID>? = nil) {
        guard !SourceStore.shared.sources.isEmpty else { showMessage("还没有书源", "添加书源后即可导出为 JSON 文件。"); return }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("阅读书源-\(UUID().uuidString.prefix(8)).json")
            try (ids.map { try SourceStore.shared.exportData(ids: $0) } ?? SourceStore.shared.exportData()).write(to: url, options: .atomic)
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            present(picker, animated: true)
        } catch { showMessage("导出失败", error.localizedDescription) }
    }

    private func edit(_ source: BookSource?) { navigationController?.pushViewController(SourceEditorViewController(source: source), animated: true) }

    private func importText() {
        let editor = YueduSourcePasteViewController()
        editor.onImport = { [weak self] text in
            self?.navigationController?.popViewController(animated: false)
            self?.beginImport(status: "正在解析书源…") { try await SourceStore.shared.importDataAsync(Data(text.utf8)) }
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    private func openChecks(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { showMessage("未选择书源", "先选择要检测的书源，或调整筛选范围。"); return }
        search.isActive = false
        navigationController?.pushViewController(YueduSourceCheckViewController(ids: ids), animated: true)
    }

    private func batchEdit(_ ids: Set<UUID>, edit: (inout BookSource) throws -> Void) {
        do { try SourceStore.shared.manage(ids, edit: edit) }
        catch { showMessage("未能保存", error.localizedDescription) }
    }

    private func assignGroup(_ ids: Set<UUID>, name: String) {
        do { try SourceStore.shared.setGroup(ids: ids, name: name) }
        catch { showMessage("未能设置分组", error.localizedDescription) }
    }

    private func renderBatchBar() {
        batchBar?.removeFromSuperview()
        batchBar = nil
        table.contentInset.bottom = managing ? 76 : 0
        guard managing else { return }
        let ids = selected
        let all = UIButton(type: .system)
        let allSelected = !visible.isEmpty && selected.count == visible.count
        all.setTitle(allSelected ? "取消全选" : "全选", for: .normal)
        all.accessibilityIdentifier = "sources.selectAll"
        all.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.selected = allSelected ? [] : Set(self.visible.map(\.id))
            self.reload()
        }, for: .touchUpInside)
        let status = UIButton(type: .system)
        status.setTitle("启停", for: .normal)
        status.menu = UIMenu(children: [
            UIAction(title: "启用所选") { [weak self] _ in self?.batchEdit(ids) { $0.enabled = true } },
            UIAction(title: "停用所选") { [weak self] _ in self?.batchEdit(ids) { $0.enabled = false } },
            UIAction(title: "开启发现") { [weak self] _ in self?.batchEdit(ids) { $0.isDiscoveryEnabled = true } },
            UIAction(title: "关闭发现") { [weak self] _ in self?.batchEdit(ids) { $0.isDiscoveryEnabled = false } }
        ])
        status.showsMenuAsPrimaryAction = true
        status.accessibilityIdentifier = "sources.batch.status"
        let groups = UIButton(type: .system)
        groups.setTitle("分组", for: .normal)
        var groupActions = [UIAction(title: "设为未分组") { [weak self] _ in self?.assignGroup(ids, name: "") }]
        groupActions += Array(Set(SourceStore.shared.sources.flatMap(\.discoveryGroups))).sorted().map { name in
            UIAction(title: name) { [weak self] _ in self?.assignGroup(ids, name: name) }
        }
        groupActions.append(UIAction(title: "新建分组并移入") { [weak self] _ in
            let alert = UIAlertController(title: "设置书源分组", message: "替换所选书源原有分组，不修改书源规则。", preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "例如：常用网文" }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
                self?.assignGroup(ids, name: alert?.textFields?.first?.text ?? "")
            })
            self?.present(alert, animated: true)
        })
        groups.menu = UIMenu(children: groupActions)
        groups.showsMenuAsPrimaryAction = true
        groups.accessibilityIdentifier = "sources.batch.group"
        let check = UIButton(type: .system)
        check.setTitle("检测", for: .normal)
        check.accessibilityIdentifier = "sources.batch.check"
        check.addAction(UIAction { [weak self] _ in self?.openChecks(ids) }, for: .touchUpInside)
        let more = UIButton(type: .system)
        more.setTitle("更多", for: .normal)
        more.accessibilityIdentifier = "sources.batch.more"
        more.menu = UIMenu(children: [
            UIAction(title: "导出所选书源") { [weak self] _ in self?.exportSources(ids: ids) },
            UIAction(title: "删除所选书源", attributes: .destructive) { [weak self] _ in self?.confirmRemove(ids) }
        ])
        more.showsMenuAsPrimaryAction = true
        [status, groups, check, more].forEach { $0.isEnabled = !ids.isEmpty }
        let bar = hstack([all, status, groups, check, more], spacing: 4)
        bar.distribution = .fillEqually
        bar.backgroundColor = Theme.surface
        bar.layer.cornerRadius = 14
        view.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            bar.heightAnchor.constraint(equalToConstant: 52)
        ])
        batchBar = bar
    }

    private func confirmRemove(_ ids: Set<UUID>) {
        let alert = UIAlertController(title: "删除 \(ids.count) 个书源？", message: "书架中的书籍和已缓存正文保留，未缓存章节需要重新导入原书源或换源。可先导出所选书源备份。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            do { try SourceStore.shared.remove(ids: ids) }
            catch { self?.showMessage("删除失败", error.localizedDescription) }
        })
        present(alert, animated: true)
    }

    private func showGuide() {
        let alert = UIAlertController(title: "从一份书源开始", message: "1. 导入 Legado JSON 书源，自动排除非文字类型。\n2. 需要账号或参数时，在书源编辑页打开“登录与设置”。\n3. 到“发现”搜索，或使用书源的“浏览分类”。\n\n网站是否可访问取决于书源地址和登录状态。示例连接 localhost，需要自行提供本地服务。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "查看示例并编辑", style: .default) { [weak self] _ in self?.edit(nil) })
        alert.addAction(UIAlertAction(title: "知道了", style: .cancel))
        present(alert, animated: true)
    }
}

@MainActor
private final class SourceEditorViewController: UIViewController {
    private let original: BookSource?
    private let editor = UITextView()

    init(source: BookSource?) { original = source; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = original == nil ? "新建书源" : "编辑书源"
        view.backgroundColor = Theme.bg
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "保存", style: .done, target: self, action: #selector(save))
        let hint = UILabel()
        hint.text = "编辑完整 Legado JSON 配置。保存时检查字段结构；有错误的配置会保留并停用。"
        hint.font = .yueduUI(ofSize: 12)
        hint.adjustsFontForContentSizeCategory = true
        hint.textColor = Theme.secondary
        hint.numberOfLines = 0
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.backgroundColor = Theme.surface
        editor.textColor = Theme.ink
        editor.tintColor = Theme.accent
        editor.autocorrectionType = .no
        editor.autocapitalizationType = .none
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        editor.layer.cornerRadius = 14
        editor.accessibilityLabel = "书源 JSON 编辑器"
        if let data = try? SourceStore.encode(original ?? BookSource.example) { editor.text = String(data: data, encoding: .utf8) }
        let header = UIStackView(arrangedSubviews: [hint])
        header.axis = .vertical
        header.alignment = .fill
        header.spacing = 4
        if let original {
            for (title, action) in [("登录与设置", "login"), ("浏览分类", "explore")] {
                let button = UIButton(type: .system)
                button.setTitle(title + "  →", for: .normal)
                button.contentHorizontalAlignment = .leading
                button.tintColor = Theme.accent
                button.accessibilityIdentifier = "sources.editor." + action
                button.addAction(UIAction { [weak self] _ in
                    let controller: UIViewController = action == "login" ? SourceLoginViewController(source: original) : SourceExploreViewController(source: original)
                    self?.navigationController?.pushViewController(controller, animated: true)
                }, for: .touchUpInside)
                header.addArrangedSubview(button)
            }
        }
        if let original, !original.isCompatible {
            let details = UIButton(type: .system)
            details.setTitle("查看兼容性说明  →", for: .normal)
            details.titleLabel?.font = .yueduUI(ofSize: 13, weight: .medium)
            details.titleLabel?.adjustsFontForContentSizeCategory = true
            details.tintColor = Theme.accent
            details.contentHorizontalAlignment = .leading
            details.accessibilityIdentifier = "sources.editor.compatibility"
            details.addAction(UIAction { [weak self] _ in
                self?.navigationController?.pushViewController(SourceImportReportViewController(source: original), animated: true)
            }, for: .touchUpInside)
            header.addArrangedSubview(details)
        }
        view.addSubview(header)
        view.addSubview(editor)
        header.translatesAutoresizingMaskIntoConstraints = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            editor.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            editor.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            editor.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            editor.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12)
        ])
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        toolbar.items = [.flexibleSpace(), UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(endEditing))]
        editor.inputAccessoryView = toolbar
    }

    @objc private func endEditing() { view.endEditing(true) }
    @objc private func save() {
        do {
            let sources = try SourceStore.decode(Data(editor.text.utf8))
            guard sources.count == 1, var source = sources.first else { throw SourceError.invalid("编辑器中只能保存一个书源对象。") }
            if let original { source.id = original.id }
            let issues = source.compatibilityIssues
            if !issues.isEmpty { source.enabled = false }
            try SourceStore.shared.save(source)
            view.endEditing(true)
            if issues.isEmpty {
                navigationController?.popViewController(animated: true)
            } else {
                let alert = UIAlertController(title: "已保存并停用", message: "完整配置已保留。这份书源存在字段结构错误，修正后可参与搜索。\n\n\(SourceImportDisplay.reason(issues[0]))", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "查看详情", style: .default) { [weak self] _ in
                    guard let self, let navigation = self.navigationController else { return }
                    let details = SourceImportReportViewController(source: source)
                    navigation.setViewControllers(Array(navigation.viewControllers.dropLast()) + [details], animated: true)
                })
                alert.addAction(UIAlertAction(title: "完成", style: .cancel) { [weak self] _ in self?.navigationController?.popViewController(animated: true) })
                present(alert, animated: true)
            }
        } catch { showMessage("无法保存", error.localizedDescription) }
    }
}

private enum SourceImportDisplay {
    static func title(_ report: SourceImportReport) -> String {
        report.importedCount > 0 ? "已导入 \(report.importedCount) 个书源" : "没有可导入的书源"
    }

    static func summary(_ report: SourceImportReport) -> String {
        var lines: [String] = []
        if report.importedCount > 0 {
            lines.append("已保留 \(report.importedCount) 个文字书源，\(report.readyCount) 个配置通过检查。")
        }
        if report.disabledCount > 0 { lines.append("\(report.disabledCount) 个配置需修正，已停用。") }
        if report.excludedCount > 0 { lines.append("\(report.excludedCount) 个漫画、有声、视频等非文字源已排除。") }
        if report.skippedCount > 0 { lines.append("\(report.skippedCount) 项配置无效，已跳过。") }
        if report.readyCount > 0 { lines.append("通过检查不代表网站已联网验证。需要账号或参数时，请打开书源的“登录与设置”。") }
        return lines.joined(separator: "\n\n")
    }

    // Only human-readable diagnostics belong in import reports. The full raw
    // configuration remains available in the explicit JSON editor and export.
    static func reason(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()
        if ["<js>", "@js:", "javascript:", "function(", "function (", "=>"].contains(where: lower.contains) {
            return "字段结构无效，请在 JSON 编辑器中检查对应规则。"
        }
        return normalized.isEmpty ? "这项配置需修正，请检查书源规则。" : normalized
    }
}

@MainActor
private final class SourceImportReportViewController: UITableViewController {
    private struct IssueRow {
        let title: String
        let reason: String
        let status: String
        let index: Int
    }

    private let summaryTitle: String
    private let summaryText: String
    private let issueRows: [IssueRow]

    init(report: SourceImportReport) {
        summaryTitle = SourceImportDisplay.title(report)
        summaryText = SourceImportDisplay.summary(report)
        issueRows = report.issues.map { issue in
            IssueRow(title: "第 \(issue.index) 项 · \(issue.name)", reason: SourceImportDisplay.reason(issue.reason), status: issue.kind == .excluded ? "已排除" : issue.kind == .invalid ? "已跳过" : "已保存并停用", index: issue.index)
        }
        super.init(style: .insetGrouped)
        title = "导入详情"
    }

    init(source: BookSource) {
        summaryTitle = source.bookSourceName
        summaryText = "配置已保存并停用。请修正以下字段结构错误；可返回书源列表编辑配置或导出完整 JSON。"
        issueRows = source.compatibilityIssues.enumerated().map { index, reason in
            IssueRow(title: "兼容性说明 \(index + 1)", reason: SourceImportDisplay.reason(reason), status: "已保存并停用", index: index + 1)
        }
        super.init(style: .insetGrouped)
        title = "兼容性详情"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = Theme.bg
        tableView.separatorColor = Theme.line
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 120
        tableView.accessibilityIdentifier = "sources.importReport"
        tableView.allowsSelection = false
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : max(1, issueRows.count)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "处理结果" : (issueRows.isEmpty ? "规则检查" : "需处理的配置 · \(issueRows.count) 项")
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? "此页仅列出配置与规则检查结果。在线搜索和正文加载还取决于站点的实际响应。" : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        var content = cell.defaultContentConfiguration()
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 19, leading: 18, bottom: 19, trailing: 18)
        content.textProperties.font = .yueduUI(ofSize: 15, weight: .semibold)
        content.textProperties.color = Theme.ink
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.font = .yueduUI(ofSize: 13)
        content.secondaryTextProperties.color = Theme.secondary
        content.secondaryTextProperties.numberOfLines = 0
        content.textToSecondaryTextVerticalPadding = 10
        if indexPath.section == 0 {
            content.text = summaryTitle
            content.textProperties.font = .yueduUISerif(23)
            content.secondaryText = summaryText
            cell.accessibilityIdentifier = "sources.importReport.summary"
        } else if issueRows.isEmpty {
            content.text = "未发现配置结构问题"
            content.secondaryText = "可返回书源列表选择要启用的书源，再到发现页搜索。"
            content.image = UIImage(systemName: "checkmark.circle")
            content.imageProperties.tintColor = Theme.accent
        } else {
            let issue = issueRows[indexPath.row]
            content.text = issue.title
            content.secondaryText = "\(issue.status)\n\(issue.reason)"
            content.image = UIImage(systemName: issue.status == "已保存并停用" ? "pause.circle" : "info.circle")
            content.imageProperties.tintColor = UIColor(red: 0.56, green: 0.36, blue: 0.18, alpha: 1)
            cell.accessibilityIdentifier = "sources.importReport.issue.\(issue.index)"
        }
        cell.contentConfiguration = content
        return cell
    }
}
