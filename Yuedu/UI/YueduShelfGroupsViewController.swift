import UIKit

final class YueduShelfGroupsViewController: UITableViewController {
    private var groups: [YueduShelfGroup] { LibraryStore.shared.shelfGroups }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "管理分组"
        tableView.backgroundColor = Theme.bg
        tableView.accessibilityIdentifier = "shelf.groupList"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "新建", primaryAction: UIAction { [weak self] _ in self?.editGroup(nil) }
        )
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    private func reload() {
        tableView.reloadData()
        if groups.isEmpty {
            let label = textLabel("还没有分组\n点右上角新建，再从书架移入书籍。", size: 15, color: Theme.secondary)
            label.textAlignment = .center
            tableView.backgroundView = label
        } else {
            tableView.backgroundView = nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { groups.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let group = groups[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var configuration = cell.defaultContentConfiguration()
        configuration.text = group.name
        let count = LibraryStore.shared.books.filter { $0.shelfInfo.groupID == group.id }.count
        configuration.secondaryText = "\(count) 本 · 轻点重命名"
        configuration.image = UIImage(systemName: "folder")
        configuration.imageProperties.tintColor = Theme.accent
        cell.contentConfiguration = configuration
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        editGroup(groups[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        groups.isEmpty ? nil : "左滑可删除分组，组内书籍会保留在「未分组」。"
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let group = groups[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in
            guard let self else { done(false); return }
            let alert = UIAlertController(title: "删除「\(group.name)」？", message: "只删除分组，组内书籍会移到「未分组」。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in done(false) })
            alert.addAction(UIAlertAction(title: "删除分组", style: .destructive) { [weak self] _ in
                do {
                    try LibraryStore.shared.deleteShelfGroup(id: group.id)
                    done(true)
                    self?.reload()
                } catch {
                    done(false)
                    self?.showMessage("未能删除", error.localizedDescription)
                }
            })
            self.present(alert, animated: true)
        }
        let configuration = UISwipeActionsConfiguration(actions: [delete])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    private func editGroup(_ group: YueduShelfGroup?) {
        let alert = UIAlertController(title: group == nil ? "新建分组" : "重命名分组", message: "名称为 1–20 个字", preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "例如：正在追更"
            $0.text = group?.name
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            do {
                try LibraryStore.shared.saveShelfGroup(name: alert?.textFields?.first?.text ?? "", id: group?.id)
                self?.reload()
            } catch {
                self?.showMessage("未能保存", error.localizedDescription)
            }
        })
        present(alert, animated: true)
    }
}
