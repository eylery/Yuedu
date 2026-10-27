import UIKit
import UniformTypeIdentifiers

@MainActor
final class YueduPurificationViewController: UITableViewController, UIDocumentPickerDelegate {
    private let book: Book?
    private let chapterTitle: String
    private let original: String?
    private let store = YueduPurificationStore.shared
    private var exportedURL: URL?

    init(book: Book? = nil, chapterTitle: String = "第一章 初见", original: String? = nil) {
        self.book = book
        self.chapterTitle = chapterTitle
        self.original = original
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { if let exportedURL { try? FileManager.default.removeItem(at: exportedURL) } }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "正文净化"
        tableView.backgroundColor = Theme.bg
        tableView.accessibilityIdentifier = "purification.list"
        let add = UIBarButtonItem(barButtonSystemItem: .add, target: nil, action: nil)
        add.accessibilityLabel = "添加净化规则"
        add.menu = UIMenu(children: [UIAction(title: "自定义替换规则") { [weak self] _ in
            self?.edit(YueduPurificationRule(name: ""), isNew: true)
        }, UIMenu(title: "常用规则", children: YueduPurificationRule.presets.map { rule in
            UIAction(title: rule.name) { [weak self] _ in self?.edit(rule, isNew: true) }
        })])
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [
            UIAction(title: "导入净化规则") { [weak self] _ in
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
                picker.delegate = self
                self?.present(picker, animated: true)
            },
            UIAction(title: "导出净化规则") { [weak self] _ in self?.exportRules() }
        ]))
        more.accessibilityLabel = "导入与导出净化规则"
        navigationItem.rightBarButtonItems = [add, editButtonItem, more]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? (book == nil ? 2 : 3) : store.settings.rules.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "阅读显示" : "替换规则 · 按顺序执行"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if let error = store.loadError { return error }
        if section == 0 {
            return "原文指书源解析后或本地导入的正文。净化只影响阅读和听书，不覆盖缓存。关闭净化或本书开关即可恢复原文；阅读位置按章内比例保留。"
        }
        return "点规则编辑，左滑删除；点“编辑”拖动排序。规则可限定本书或书源。导入规则默认停用，请预览后启用。\n\n净化规则单独导出，不包含在书架备份内；跨设备的限定范围需核对后重新指定。"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        cell.detailTextLabel?.numberOfLines = 2
        if indexPath.section == 0 {
            if indexPath.row == 0 {
                cell.textLabel?.text = "启用正文净化"
                addSwitch(to: cell, value: store.settings.enabled, identifier: "purification.enabled") { settings, value in settings.enabled = value }
            } else if indexPath.row == 1, let book {
                cell.textLabel?.text = "本书应用净化"
                cell.detailTextLabel?.text = book.title
                addSwitch(to: cell, value: !store.settings.originalBookIDs.contains(book.id), identifier: "purification.bookEnabled") { settings, value in
                    if value { settings.originalBookIDs.remove(book.id) }
                    else { settings.originalBookIDs.insert(book.id) }
                }
            } else {
                cell.textLabel?.text = original == nil ? "粘贴文字预览" : "预览当前章节"
                cell.detailTextLabel?.text = "对比原文与净化结果，查看规则命中次数"
                cell.accessoryType = .disclosureIndicator
                cell.accessibilityIdentifier = "purification.preview"
            }
        } else {
            let rule = store.settings.rules[indexPath.row]
            cell.textLabel?.text = rule.name
            cell.detailTextLabel?.text = rule.kind.title + " · " + (rule.scope == .all ? "所有书籍" : (rule.targetName ?? rule.scope.title))
            cell.accessibilityIdentifier = "purification.rule.\(rule.name)"
            addSwitch(to: cell, value: rule.enabled, identifier: "purification.ruleEnabled.\(rule.name)") { settings, value in
                if let index = settings.rules.firstIndex(where: { $0.id == rule.id }) { settings.rules[index].enabled = value }
            }
        }
        return cell
    }

    private func addSwitch(to cell: UITableViewCell, value: Bool, identifier: String,
                           edit: @escaping (inout YueduPurificationSettings, Bool) -> Void) {
        let toggle = UISwitch()
        toggle.isOn = value
        toggle.accessibilityIdentifier = identifier
        toggle.accessibilityLabel = cell.textLabel?.text
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let self, let toggle else { return }
            do { try self.store.update { edit(&$0, toggle.isOn) } }
            catch { self.showMessage("保存失败", error.localizedDescription) }
            self.tableView.reloadData()
        }, for: .valueChanged)
        cell.accessoryView = toggle
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 { edit(store.settings.rules[indexPath.row], isNew: false) }
        else if indexPath.row == (book == nil ? 1 : 2) {
            let preview = YueduPurificationPreviewController(settings: store.settings, book: book, chapterTitle: chapterTitle, original: original)
            navigationController?.pushViewController(preview, animated: true)
        }
    }

    private func edit(_ rule: YueduPurificationRule, isNew: Bool) {
        var rule = rule
        if isNew, let book {
            rule.scope = .book
            rule.targetID = book.id
            rule.targetName = book.title
        }
        navigationController?.pushViewController(YueduPurificationRuleEditor(rule: rule, book: book, chapterTitle: chapterTitle, original: original), animated: true)
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { indexPath.section == 1 }
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { indexPath.section == 1 }

    override func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        proposedDestinationIndexPath.section == 1 ? proposedDestinationIndexPath : IndexPath(row: 0, section: 1)
    }

    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        change { settings in
            let rule = settings.rules.remove(at: sourceIndexPath.row)
            settings.rules.insert(rule, at: destinationIndexPath.row)
        }
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete { change { $0.rules.remove(at: indexPath.row) } }
    }

    private func change(_ edit: (inout YueduPurificationSettings) throws -> Void) {
        do { try store.update(edit) }
        catch { showMessage("保存失败", error.localizedDescription) }
        tableView.reloadData()
    }

    private func exportRules() {
        do {
            let data = try store.exportData()
            if let exportedURL { try? FileManager.default.removeItem(at: exportedURL) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Yuedu-净化规则-\(UUID().uuidString.prefix(8)).json")
            try data.write(to: url, options: .atomic)
            exportedURL = url
            present(UIDocumentPickerViewController(forExporting: [url], asCopy: true), animated: true)
        } catch { showMessage("导出失败", error.localizedDescription) }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: 1_000_001) ?? Data()
            let count = try store.importData(data)
            tableView.reloadData()
            showMessage("已导入 \(count) 条规则", "新增规则已停用，请检查范围并预览后启用。重复规则未再次添加。")
        } catch { showMessage("导入失败", error.localizedDescription) }
    }
}

@MainActor
private final class YueduPurificationRuleEditor: UIViewController {
    private var rule: YueduPurificationRule
    private let book: Book?
    private let chapterTitle: String
    private let original: String?
    private let name = UITextField()
    private let pattern = UITextView()
    private let replacement = UITextView()
    private let kind = UISegmentedControl(items: YueduPurificationRule.Kind.allCases.map(\.title))
    private let scope = UIButton(type: .system)

    init(rule: YueduPurificationRule, book: Book?, chapterTitle: String, original: String?) {
        self.rule = rule
        self.book = book
        self.chapterTitle = chapterTitle
        self.original = original
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "编辑净化规则"
        view.backgroundColor = Theme.bg
        navigationItem.rightBarButtonItems = [UIBarButtonItem(title: "保存", style: .done, target: self, action: #selector(save)),
                                             UIBarButtonItem(title: "预览", style: .plain, target: self, action: #selector(preview))]
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .onDrag
        view.addSubview(scroll)
        scroll.pinEdges(to: view)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        scroll.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -30),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        name.borderStyle = .roundedRect
        name.placeholder = "规则名称"
        name.text = rule.name
        name.accessibilityIdentifier = "purification.name"
        stack.addArrangedSubview(name)
        kind.selectedSegmentIndex = YueduPurificationRule.Kind.allCases.firstIndex(of: rule.kind) ?? 0
        kind.addAction(UIAction { [weak self] _ in self?.updateKind() }, for: .valueChanged)
        stack.addArrangedSubview(kind)
        scope.showsMenuAsPrimaryAction = true
        scope.contentHorizontalAlignment = .leading
        scope.accessibilityIdentifier = "purification.scope"
        stack.addArrangedSubview(scope)
        stack.addArrangedSubview(textLabel("匹配内容", size: 14, weight: .semibold))
        pattern.text = rule.pattern
        configure(pattern, identifier: "purification.pattern", height: 120)
        stack.addArrangedSubview(pattern)
        stack.addArrangedSubview(textLabel("替换为（留空表示删除）", size: 14, weight: .semibold))
        replacement.text = rule.replacement
        configure(replacement, identifier: "purification.replacement", height: 100)
        stack.addArrangedSubview(replacement)
        let note = textLabel("普通替换按原样匹配，替换文字中的 $ 和反斜线按字面处理。正则替换支持 $1、$2 捕获组；多行匹配可使用 (?m)。重复章名只移除正文开头与当前章名完全一致的一行。\n\n规则按列表顺序执行。保存前可用当前章节或粘贴文字预览；预览不会修改书籍。", size: 12, color: Theme.secondary)
        note.numberOfLines = 0
        stack.addArrangedSubview(note)
        updateScope()
        updateKind()
    }

    private func configure(_ text: UITextView, identifier: String, height: CGFloat) {
        text.backgroundColor = Theme.surface
        text.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        text.layer.cornerRadius = 10
        text.autocorrectionType = .no
        text.smartQuotesType = .no
        text.smartDashesType = .no
        text.autocapitalizationType = .none
        text.accessibilityIdentifier = identifier
        text.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    private func updateKind() {
        rule.kind = YueduPurificationRule.Kind.allCases[kind.selectedSegmentIndex]
        pattern.isEditable = rule.kind != .chapterTitle
        replacement.isEditable = rule.kind != .chapterTitle
        pattern.alpha = pattern.isEditable ? 1 : 0.4
        replacement.alpha = replacement.isEditable ? 1 : 0.4
    }

    private func updateScope() {
        scope.setTitle("范围：" + (rule.scope == .all ? "所有书籍" : "\(rule.scope.title) · \(rule.targetName ?? "未命名")") + " ▾", for: .normal)
        var choices: [(YueduPurificationRule.Scope, UUID?, String?)] = [(.all, nil, nil)]
        if let book {
            choices.append((.book, book.id, book.title))
            if let id = book.sourceID { choices.append((.source, id, book.sourceName)) }
        }
        scope.menu = UIMenu(children: choices.map { value, id, label in
            UIAction(title: label.map { "\(value.title) · \($0)" } ?? value.title, state: rule.scope == value && rule.targetID == id ? .on : .off) { [weak self] _ in
                self?.rule.scope = value
                self?.rule.targetID = id
                self?.rule.targetName = label
                self?.updateScope()
            }
        })
    }

    private func draft() throws -> YueduPurificationRule {
        var draft = rule
        draft.name = name.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        draft.pattern = pattern.text
        draft.replacement = replacement.text
        try draft.validate()
        return draft
    }

    @objc private func save() {
        do {
            try YueduPurificationStore.shared.save(draft())
            navigationController?.popViewController(animated: true)
        } catch { showMessage("无法保存规则", error.localizedDescription) }
    }

    @objc private func preview() {
        do {
            let draft = try draft()
            var settings = YueduPurificationStore.shared.settings
            if let index = settings.rules.firstIndex(where: { $0.id == draft.id }) { settings.rules[index] = draft }
            else { settings.rules.append(draft) }
            navigationController?.pushViewController(YueduPurificationPreviewController(settings: settings, book: book, chapterTitle: chapterTitle, original: original), animated: true)
        } catch { showMessage("无法预览", error.localizedDescription) }
    }
}

@MainActor
private final class YueduPurificationPreviewController: UIViewController {
    private let settings: YueduPurificationSettings
    private let book: Book?
    private let chapterTitle: String
    private let original: String?
    private let input = UITextView()
    private let output = UITextView()
    private let report = UILabel()
    private let mode = UISegmentedControl(items: ["原文 / 可粘贴", "净化结果"])
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(settings: YueduPurificationSettings, book: Book?, chapterTitle: String, original: String?) {
        self.settings = settings
        self.book = book
        self.chapterTitle = chapterTitle
        self.original = original
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { task?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "净化预览"
        view.backgroundColor = Theme.bg
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "运行预览", style: .done, target: self, action: #selector(run))
        mode.selectedSegmentIndex = 0
        mode.addAction(UIAction { [weak self] _ in self?.changeMode() }, for: .valueChanged)
        input.text = original ?? "第一章 初见\n\n这里是示例正文。\n\n\n请粘贴需要测试的文字，然后运行预览。"
        input.accessibilityIdentifier = "purification.original"
        output.accessibilityIdentifier = "purification.output"
        output.isEditable = false
        report.font = .yueduUI(ofSize: 12)
        report.adjustsFontForContentSizeCategory = true
        report.textColor = Theme.secondary
        report.numberOfLines = 0
        report.accessibilityIdentifier = "purification.report"
        report.text = "\(original == nil ? "示例文本" : chapterTitle) · 编辑预览文字不会修改缓存。"
        for text in [input, output] {
            text.font = .yueduUI(ofSize: 17)
            text.adjustsFontForContentSizeCategory = true
            text.backgroundColor = Theme.surface
            text.layer.cornerRadius = 12
            text.smartQuotesType = .no
            text.smartDashesType = .no
        }
        for item in [mode, report, input, output] {
            view.addSubview(item)
            item.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            mode.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            mode.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            mode.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            report.topAnchor.constraint(equalTo: mode.bottomAnchor, constant: 12),
            report.leadingAnchor.constraint(equalTo: mode.leadingAnchor),
            report.trailingAnchor.constraint(equalTo: mode.trailingAnchor),
            report.heightAnchor.constraint(lessThanOrEqualToConstant: 160)
        ])
        for text in [input, output] {
            NSLayoutConstraint.activate([
                text.topAnchor.constraint(equalTo: report.bottomAnchor, constant: 12),
                text.leadingAnchor.constraint(equalTo: mode.leadingAnchor),
                text.trailingAnchor.constraint(equalTo: mode.trailingAnchor),
                text.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12)
            ])
        }
        changeMode()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        task?.cancel()
        generation = UUID()
    }

    private func changeMode() {
        input.isHidden = mode.selectedSegmentIndex != 0
        output.isHidden = mode.selectedSegmentIndex == 0
    }

    @objc private func run() {
        view.endEditing(true)
        task?.cancel()
        let token = UUID()
        generation = token
        let text = input.text ?? ""
        report.text = "正在预览…"
        let settings = settings
        let title = chapterTitle
        let bookID = book?.id
        let sourceID = book?.sourceID
        task = Task { [weak self] in
            do {
                let result = try await YueduTextPurifier.process(text, chapterTitle: title, bookID: bookID, sourceID: sourceID, settings: settings)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.output.text = result.text
                let hits = settings.rules.compactMap { rule in result.hits[rule.id].map { "\(rule.name)：\($0) 处" } }
                self.report.text = (hits.isEmpty ? "没有命中规则（请检查开关、范围及匹配内容）。" : hits.joined(separator: "\n"))
                    + (result.warnings.isEmpty ? "" : "\n" + result.warnings.joined(separator: "\n"))
                self.mode.selectedSegmentIndex = 1
                self.changeMode()
            } catch { }
        }
    }
}
