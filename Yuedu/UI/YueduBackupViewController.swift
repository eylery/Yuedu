import UIKit
import UniformTypeIdentifiers

final class YueduBackupViewController: UITableViewController, UIDocumentPickerDelegate {
    private var busy = false
    private var operation: Task<Void, Never>?
    private var exportedURL: URL?

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "备份与恢复"
        tableView.backgroundColor = Theme.bg
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    deinit {
        operation?.cancel()
        if let exportedURL { try? FileManager.default.removeItem(at: exportedURL) }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 3 }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        busy ? "正在处理，请稍候…"
            : "书架备份包含书籍、已缓存正文、进度、书签和阅读统计，最大 200 MB。恢复采用合并方式，已有书籍的进度与正文保持不变。\n\n书源配置单独导出；换设备时先导入书源，再恢复书架。登录状态、Cookie、系统设置不在书架备份内。"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let titles = ["导出书架备份", "从文件恢复书架", "导出书源配置"]
        let symbols = ["square.and.arrow.up", "arrow.counterclockwise", "square.stack.3d.up"]
        var content = cell.defaultContentConfiguration()
        content.text = titles[indexPath.row]
        content.image = UIImage(systemName: symbols[indexPath.row])
        content.textProperties.color = busy ? Theme.secondary : Theme.ink
        content.imageProperties.tintColor = Theme.accent
        cell.contentConfiguration = content
        cell.backgroundColor = Theme.surface
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "backup.action.\(indexPath.row)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !busy else { return }
        if indexPath.row == 1 {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
            picker.delegate = self
            present(picker, animated: true)
        } else {
            export(sourcesOnly: indexPath.row == 2)
        }
    }

    private func export(sourcesOnly: Bool) {
        setBusy(true)
        operation = Task { [weak self] in
            do {
                let data: Data
                if sourcesOnly {
                    if let error = SourceStore.shared.persistenceError { throw SourceError.invalid(error) }
                    data = try SourceStore.shared.exportData()
                } else {
                    let store = LibraryStore.shared
                    if let error = store.persistenceError { throw SourceError.invalid(error) }
                    let sourceURLs = Dictionary(uniqueKeysWithValues: SourceStore.shared.sources.map {
                        ($0.id.uuidString, $0.bookSourceUrl)
                    })
                    let backup = YueduLibraryBackup(library: store.snapshot, sourceURLs: sourceURLs)
                    data = try await Task.detached(priority: .userInitiated) {
                        let data = try JSONEncoder().encode(backup)
                        guard data.count <= YueduLibraryBackup.maximumBytes else {
                            throw SourceError.invalid("书架备份超过 200 MB 上限，暂无法导出。")
                        }
                        return data
                    }.value
                }
                try Task.checkCancellation()
                guard let self else { return }
                if let previous = self.exportedURL { try? FileManager.default.removeItem(at: previous) }
                let name = sourcesOnly ? "书源" : "书架备份"
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Yuedu-\(name)-\(UUID().uuidString.prefix(8)).json")
                try data.write(to: url, options: .atomic)
                self.exportedURL = url
                self.setBusy(false)
                let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
                self.present(picker, animated: true)
            } catch {
                self?.setBusy(false)
                self?.showMessage("导出失败", error.localizedDescription)
            }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        setBusy(true)
        operation = Task { [weak self] in
            do {
                let backup = try await Task.detached(priority: .userInitiated) {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= YueduLibraryBackup.maximumBytes else {
                        throw SourceError.invalid("书架备份超过 200 MB 上限。")
                    }
                    return try YueduLibraryBackup.decode(Data(contentsOf: url))
                }.value
                try Task.checkCancellation()
                guard let self else { return }
                self.setBusy(false)
                let alert = UIAlertController(
                    title: "恢复书架备份",
                    message: "备份时间：\(backup.createdAt.formatted(date: .abbreviated, time: .shortened))\n"
                        + "\(backup.library.books.count) 本书 · \(backup.library.bookmarks.count) 个书签\n\n"
                        + "添加缺少的书籍和可匹配书签；已有书籍的进度与缓存保持不变。统计取较大值，不重复累加。",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "取消", style: .cancel))
                alert.addAction(UIAlertAction(title: "合并恢复", style: .default) { [weak self] _ in
                    do {
                        let counts = try backup.merge(into: .shared, sources: SourceStore.shared.sources)
                        self?.showMessage("恢复完成", "新增 \(counts.books) 本书、\(counts.bookmarks) 个书签。\n未能匹配已有目录的旧书签不会覆盖当前数据，原备份文件保持不变。")
                    } catch { self?.showMessage("恢复失败", error.localizedDescription) }
                })
                self.present(alert, animated: true)
            } catch {
                self?.setBusy(false)
                self?.showMessage("无法读取备份", error.localizedDescription)
            }
        }
    }

    private func setBusy(_ value: Bool) {
        busy = value
        tableView.reloadData()
    }
}
