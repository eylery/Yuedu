import UIKit

@MainActor
final class YueduSearchScopeViewController: UITableViewController, UISearchResultsUpdating {
    var onApply: ((Set<UUID>?) -> Void)?
    private let sources: [BookSource]
    private var selected: Set<UUID>
    private var visible: [BookSource] = []
    private var group: String?
    private let search = UISearchController(searchResultsController: nil)
    private let groupButton = UIButton(type: .system)

    init(sources: [BookSource], selected: Set<UUID>?) {
        self.sources = sources
        self.selected = selected ?? Set(sources.map(\.id))
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "搜索范围"
        view.backgroundColor = Theme.bg
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "应用", style: .done, target: self, action: #selector(apply))
        search.searchBar.placeholder = "查找书源或分组"
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        groupButton.showsMenuAsPrimaryAction = true
        groupButton.accessibilityIdentifier = "search.scope.groups"
        let select = UIButton(type: .system)
        select.setTitle("选中当前列表", for: .normal)
        select.addTarget(self, action: #selector(selectVisible), for: .touchUpInside)
        let clear = UIButton(type: .system)
        clear.setTitle("清空选择", for: .normal)
        clear.addTarget(self, action: #selector(clearSelection), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [groupButton, select, clear])
        stack.axis = .horizontal
        stack.distribution = .equalSpacing
        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 58))
        header.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        tableView.tableHeaderView = header
        tableView.accessibilityIdentifier = "search.scope.list"
        refresh()
    }

    private func refresh() {
        let term = search.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        visible = sources.filter {
            (group == nil || $0.discoveryGroups.contains(group!))
                && (term.isEmpty || "\($0.bookSourceName) \($0.bookSourceGroup)".localizedCaseInsensitiveContains(term))
        }
        groupButton.setTitle(group ?? "全部分组", for: .normal)
        let groups = Array(Set(sources.flatMap(\.discoveryGroups))).sorted()
        groupButton.menu = UIMenu(children: ([nil] + groups.map(Optional.some)).map { name in
            UIAction(title: name ?? "全部分组", state: name == group ? .on : .off) { [weak self] _ in
                self?.group = name
                self?.refresh()
            }
        })
        navigationItem.prompt = "已选择 \(selected.intersection(Set(sources.map(\.id))).count) / \(sources.count) 个书源"
        tableView.reloadData()
    }

    func updateSearchResults(for searchController: UISearchController) { refresh() }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { visible.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let source = visible[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = source.bookSourceName
        cell.detailTextLabel?.text = source.bookSourceGroup
        cell.accessoryType = selected.contains(source.id) ? .checkmark : .none
        cell.accessibilityIdentifier = "search.scope.\(source.bookSourceName)"
        cell.accessibilityValue = selected.contains(source.id) ? "已选择" : "未选择"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let id = visible[indexPath.row].id
        if !selected.insert(id).inserted { selected.remove(id) }
        refresh()
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "仅列出已启用且具有搜索地址的文字书源。选择全部时，之后启用的书源也会参与搜索；自选范围仅用于本次搜索页面。"
    }

    @objc private func selectVisible() {
        selected.formUnion(visible.map(\.id))
        refresh()
    }

    @objc private func clearSelection() {
        selected.removeAll()
        refresh()
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func apply() {
        let ids = selected.intersection(Set(sources.map(\.id)))
        guard !ids.isEmpty else {
            showMessage("请选择书源", "至少选择一个书源后再应用搜索范围。")
            return
        }
        onApply?(ids.count == sources.count ? nil : ids)
        dismiss(animated: true)
    }
}
