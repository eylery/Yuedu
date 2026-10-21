import UIKit

final class YueduSourcePasteViewController: UIViewController {
    var onImport: ((String) -> Void)?
    private let editor = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "粘贴书源 JSON"
        view.backgroundColor = Theme.bg
        let hint = textLabel("在下方粘贴一个书源或书源数组，导入后查看逐项结果。", size: 13, color: Theme.secondary)
        editor.backgroundColor = Theme.surface
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.autocorrectionType = .no
        editor.autocapitalizationType = .none
        editor.accessibilityIdentifier = "sources.pasteJSON"
        view.addSubview(hint)
        view.addSubview(editor)
        hint.translatesAutoresizingMaskIntoConstraints = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            editor.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            editor.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            editor.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            editor.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12)
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "导入", primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            guard !self.editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.showMessage("内容为空", "请先粘贴书源 JSON。")
                return
            }
            self.view.endEditing(true)
            self.onImport?(self.editor.text)
        })
    }
}
