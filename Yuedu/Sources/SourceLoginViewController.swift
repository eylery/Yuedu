import UIKit

/// Source-defined account/settings form. Source code executes only through the
/// isolated rule runtime; this controller only renders JSON field descriptions.
@MainActor
final class SourceLoginViewController: UIViewController, UITextFieldDelegate {
    private let source: BookSource
    private let scroll = UIScrollView()
    private let content = UIStackView()
    private let fieldsStack = UIStackView()
    private let statusLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)
    private let variableInput = UITextView()
    private var operation: Task<Void, Never>?
    private var descriptors: [[String: Any]] = []
    private var info: [String: String] = [:]
    private var textFields: [String: UITextField] = [:]
    private var switches: [String: (UISwitch, [String])] = [:]
    private var selects: [String: UIButton] = [:]
    private var controls: [UIControl] = []
    private var hasLoaded = false
    private var busy = false
    private var secureNames = Set<String>()

    init(source: BookSource) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { operation?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "登录与设置"
        view.backgroundColor = Theme.bg
        view.accessibilityIdentifier = "sources.loginSettings"
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        content.axis = .vertical
        content.spacing = 22
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -32),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -22)
        ])
        let eyebrow = label("SOURCE PREFERENCES", size: 10, weight: .semibold, color: Theme.accent)
        let name = label(source.bookSourceName, size: 27)
        name.font = .readingSerif(27)
        let subtitle = label("管理此书源的账户、登录状态与阅读选项。", size: 13, color: Theme.secondary)
        let heading = UIStackView(arrangedSubviews: [eyebrow, name, subtitle])
        heading.axis = .vertical
        heading.spacing = 11
        content.addArrangedSubview(heading)
        fieldsStack.axis = .vertical
        fieldsStack.spacing = 14
        content.addArrangedSubview(fieldsStack)

        let variableTitle = label("书源变量", size: 15, weight: .semibold)
        let comment = source.rawFields["variableComment"]?.scalarString ?? "供书源保存筛选条件或自定义参数。"
        let variableDescription = label(String(comment.prefix(8_000)), size: 12, color: Theme.secondary)
        variableInput.font = .systemFont(ofSize: 15)
        variableInput.textColor = Theme.ink
        variableInput.backgroundColor = Theme.bg
        variableInput.layer.cornerRadius = 10
        variableInput.textContainerInset = UIEdgeInsets(top: 12, left: 9, bottom: 12, right: 9)
        variableInput.autocorrectionType = .no
        variableInput.autocapitalizationType = .none
        variableInput.accessibilityLabel = "书源变量"
        variableInput.accessibilityIdentifier = "sources.sourceVariable"
        variableInput.heightAnchor.constraint(equalToConstant: 126).isActive = true
        content.addArrangedSubview(card([variableTitle, variableDescription, variableInput]))

        statusLabel.numberOfLines = 0
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = Theme.secondary
        statusLabel.accessibilityIdentifier = "sources.loginStatus"
        activity.color = Theme.accent
        activity.hidesWhenStopped = true
        let status = UIStackView(arrangedSubviews: [activity, statusLabel])
        status.axis = .horizontal
        status.alignment = .top
        status.spacing = 10
        content.addArrangedSubview(status)
        readState()
        updateNavigation()
        loadForm()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.isBeingDismissed == true {
            operation?.cancel()
        }
    }

    private func loadForm() {
        guard operation == nil else { return }
        if let raw = source.rawFields["loginUi"], let parsed = Self.staticItems(raw) {
            descriptors = parsed
            hasLoaded = true
            renderFields()
            statusLabel.text = "填写后可保存设置，或使用书源提供的操作。"
            return
        }
        guard source.rawFields["loginUi"]?.isEmpty == false else {
            hasLoaded = true
            descriptors = []
            renderFields()
            statusLabel.text = "设置只应用于当前书源。"
            return
        }
        setBusy(true, message: "正在加载书源设置…")
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await SourceEngine.shared.execute("loginUI", source: source, payload: ["interactive": true])
                try Task.checkCancellation()
                descriptors = result["items"] as? [[String: Any]] ?? []
                hasLoaded = true
                readState()
                renderFields()
                statusLabel.text = "填写后可保存设置，或使用书源提供的操作。"
            } catch is CancellationError { statusLabel.text = "已取消加载。点击重试可重新打开设置。" }
            catch { statusLabel.text = "无法加载设置：\(error.localizedDescription)" }
            operation = nil
            setBusy(false)
            if !hasLoaded { showLoadRetry() }
        }
    }

    private func readState() {
        let state = SourceEngine.shared.runtimeState(for: source)
        info = (state["loginInfo"] as? [String: Any] ?? [:]).reduce(into: [:]) { result, item in
            result[item.key] = Self.string(item.value)
        }
        variableInput.text = state["sourceVariable"] as? String ?? source.rawFields["sourceVariable"]?.scalarString ?? ""
    }

    private func renderFields() {
        fieldsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        textFields.removeAll()
        switches.removeAll()
        selects.removeAll()
        controls.removeAll()
        secureNames.removeAll()
        for descriptor in descriptors.prefix(150) {
            guard let key = descriptor["name"] as? String, !key.isEmpty else { continue }
            let displayName = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = (descriptor["type"] as? String ?? "text").lowercased()
            let action = descriptor["action"] as? String ?? ""
            let initial = info[key] ?? Self.string(descriptor["default"])
            if kind == "button" {
                if action.isEmpty {
                    fieldsStack.addArrangedSubview(label(displayName, size: 13, weight: .semibold, color: Theme.secondary))
                } else {
                    let button = actionButton(displayName, icon: "arrow.up.right", primary: false)
                    button.accessibilityIdentifier = "sources.loginAction.\(key)"
                    button.addAction(UIAction { [weak self] _ in self?.perform(action: action, name: displayName) }, for: .touchUpInside)
                    fieldsStack.addArrangedSubview(button)
                }
                continue
            }
            info[key] = initial
            var row: [UIView] = [label(displayName, size: 14, weight: .medium)]
            if let hint = descriptor["hint"] as? String, !hint.isEmpty { row.append(label(hint, size: 12, color: Theme.secondary)) }
            let choices = (descriptor["chars"] as? [Any])?.map(Self.string) ?? []
            if kind == "toggle", choices.count <= 2 {
                let values = choices.count >= 2 ? Array(choices.prefix(2)) : ["false", "true"]
                let toggle = UISwitch()
                toggle.onTintColor = Theme.accent
                toggle.isOn = initial == values[1]
                toggle.accessibilityLabel = displayName
                toggle.accessibilityIdentifier = "sources.loginField.\(key)"
                toggle.accessibilityValue = toggle.isOn ? values[1] : values[0]
                let current = label(toggle.isOn ? values[1] : values[0], size: 13, color: Theme.secondary)
                let spacer = UIView()
                let line = UIStackView(arrangedSubviews: [current, spacer, toggle])
                line.alignment = .center
                row.append(line)
                switches[key] = (toggle, values)
                controls.append(toggle)
                toggle.addAction(UIAction { [weak self, weak toggle, weak current] _ in
                    guard let self, let toggle else { return }
                    info[key] = values[toggle.isOn ? 1 : 0]
                    current?.text = info[key]
                    toggle.accessibilityValue = info[key]
                    if !action.isEmpty { perform(action: action, name: displayName) }
                }, for: .valueChanged)
            } else if (kind == "select" || kind == "toggle"), !choices.isEmpty {
                let selected = initial.isEmpty ? choices[0] : initial
                info[key] = selected
                let button = actionButton(selected, icon: "chevron.up.chevron.down", primary: false)
                button.accessibilityLabel = displayName
                button.accessibilityValue = selected
                button.accessibilityIdentifier = "sources.loginField.\(key)"
                button.showsMenuAsPrimaryAction = true
                selects[key] = button
                updateMenu(button, key: key, values: choices, action: action)
                row.append(button)
            } else {
                let input = UITextField()
                input.text = initial
                input.placeholder = descriptor["placeholder"] as? String ?? descriptor["hint"] as? String ?? displayName
                input.font = .systemFont(ofSize: 16)
                input.textColor = Theme.ink
                input.backgroundColor = Theme.bg
                input.borderStyle = .roundedRect
                input.autocapitalizationType = .none
                input.autocorrectionType = .no
                input.clearButtonMode = .whileEditing
                input.returnKeyType = .done
                input.delegate = self
                input.isSecureTextEntry = kind == "password" || key.contains("密码")
                if input.isSecureTextEntry { secureNames.insert(key); input.textContentType = .password }
                else if key.contains("邮箱") { input.keyboardType = .emailAddress; input.textContentType = .emailAddress }
                else if key.contains("验证码") { input.textContentType = .oneTimeCode }
                else if key.contains("账号") || key.lowercased() == "username" { input.textContentType = .username }
                input.accessibilityLabel = displayName
                input.accessibilityIdentifier = "sources.loginField.\(key)"
                input.heightAnchor.constraint(equalToConstant: 44).isActive = true
                textFields[key] = input
                controls.append(input)
                row.append(input)
                if !action.isEmpty {
                    let apply = actionButton("应用\(displayName)", icon: "checkmark", primary: false)
                    apply.addAction(UIAction { [weak self] _ in self?.perform(action: action, name: displayName) }, for: .touchUpInside)
                    row.append(apply)
                }
            }
            fieldsStack.addArrangedSubview(card(row))
        }
        let login = source.rawFields["loginUrl"]?.scalarString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !login.isEmpty {
            let isWeb = login.lowercased().hasPrefix("http://") || login.lowercased().hasPrefix("https://")
            let button = actionButton(isWeb ? "打开网页登录" : "登录 / 执行书源设置", icon: isWeb ? "globe" : "person.crop.circle.badge.checkmark", primary: true)
            button.accessibilityIdentifier = "sources.loginDefaultAction"
            button.addAction(UIAction { [weak self] _ in self?.perform(action: nil, name: isWeb ? "网页登录" : "登录") }, for: .touchUpInside)
            fieldsStack.addArrangedSubview(button)
        } else if descriptors.isEmpty {
            fieldsStack.addArrangedSubview(card([label("此书源未提供登录表单。", size: 14), label("你仍可在下方编辑书源变量。", size: 12, color: Theme.secondary)]))
        }
        controls.forEach { $0.isEnabled = !busy }
    }

    private func updateMenu(_ button: UIButton, key: String, values: [String], action: String) {
        button.menu = UIMenu(children: values.prefix(100).map { value in
            UIAction(title: value, state: info[key] == value ? .on : .off) { [weak self, weak button] _ in
                guard let self, let button else { return }
                info[key] = value
                button.configuration?.title = value
                button.accessibilityValue = value
                updateMenu(button, key: key, values: values, action: action)
                if !action.isEmpty { perform(action: action, name: key) }
            }
        })
    }

    private func collectValues() {
        for (key, field) in textFields { info[key] = field.text ?? "" }
        for (key, value) in switches { info[key] = value.1[value.0.isOn ? 1 : 0] }
    }

    private func perform(action: String?, name: String) {
        guard operation == nil else { return }
        view.endEditing(true)
        collectValues()
        let values = info
        let variable = variableInput.text ?? ""
        setBusy(true, message: name == "保存" ? "正在保存设置…" : "正在执行\(name)…")
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let logs = try await SourceEngine.shared.login(source: source, info: values, variable: variable, action: action)
                try Task.checkCancellation()
                var messages = logs.suffix(15).joined(separator: "\n")
                for key in secureNames {
                    if let secret = values[key], !secret.isEmpty { messages = messages.replacingOccurrences(of: secret, with: "••••••") }
                }
                readState()
                renderFields()
                statusLabel.textColor = Theme.secondary
                statusLabel.text = (name == "保存" ? "设置已保存。" : "\(name)已完成。") + (messages.isEmpty ? "" : "\n\n" + String(messages.prefix(4_000)))
                UIAccessibility.post(notification: .announcement, argument: name == "保存" ? "设置已保存" : "操作已完成")
            } catch is CancellationError { statusLabel.text = "已取消操作。" }
            catch {
                statusLabel.textColor = .systemRed
                statusLabel.text = "\(name)未完成：\(error.localizedDescription)"
            }
            operation = nil
            setBusy(false)
        }
    }

    private func setBusy(_ value: Bool, message: String? = nil) {
        busy = value
        controls.forEach { $0.isEnabled = !value }
        variableInput.isEditable = !value
        value ? activity.startAnimating() : activity.stopAnimating()
        if let message { statusLabel.text = message; statusLabel.textColor = Theme.secondary }
        updateNavigation()
    }

    private func updateNavigation() {
        let item = UIBarButtonItem(title: busy ? "停止" : "保存", style: .done, target: self, action: #selector(navigationAction))
        item.accessibilityIdentifier = busy ? "sources.loginStop" : "sources.loginSave"
        navigationItem.rightBarButtonItem = item
    }
    @objc private func navigationAction() {
        if busy { operation?.cancel() }
        else { perform(action: "void 0", name: "保存") }
    }

    private func showLoadRetry() {
        fieldsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let retry = actionButton("重新加载设置", icon: "arrow.clockwise", primary: false)
        retry.addAction(UIAction { [weak self] _ in self?.loadForm() }, for: .touchUpInside)
        fieldsStack.addArrangedSubview(retry)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); return true }
    func textFieldDidBeginEditing(_ textField: UITextField) {
        let rect = textField.convert(textField.bounds.insetBy(dx: 0, dy: -24), to: scroll)
        scroll.scrollRectToVisible(rect, animated: true)
    }

    private func actionButton(_ title: String, icon: String, primary: Bool) -> UIButton {
        var config = primary ? UIButton.Configuration.filled() : .tinted()
        config.title = title
        config.image = UIImage(systemName: icon)
        config.imagePlacement = .trailing
        config.imagePadding = 10
        config.baseBackgroundColor = Theme.accent
        config.baseForegroundColor = primary ? .white : Theme.accent
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        let button = UIButton(configuration: config)
        button.titleLabel?.numberOfLines = 0
        button.contentHorizontalAlignment = .leading
        controls.append(button)
        return button
    }

    private func card(_ views: [UIView]) -> UIView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = 10
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.backgroundColor = Theme.surface
        stack.layer.cornerRadius = 14
        return stack
    }
    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor? = nil) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color ?? Theme.ink
        return label
    }
    private static func string(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let string = value as? String { return string }
        return String(describing: value)
    }
    private static func staticItems(_ raw: JSONValue) -> [[String: Any]]? {
        let data: Data
        if let text = raw.stringValue { data = Data(text.utf8) }
        else { guard let encoded = try? JSONEncoder().encode(raw) else { return nil }; data = encoded }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }
}
