import UIKit

final class YueduTypographyViewController: UIViewController, UIFontPickerViewControllerDelegate {
    var onChange: ((ReaderPreferences) -> Void)?
    private var preferences = ReaderPreferences.load()
    private let preview = UILabel()
    private let previewCard = UIScrollView()
    private let fontButton = UIButton(type: .system)
    private let fontNotice = UILabel()
    private let bold = UISegmentedControl(items: ["普通", "加粗"])
    private let alignment = UISegmentedControl(items: ["左对齐", "两端对齐"])
    private let titleAlignment = UISegmentedControl(items: ["标题靠左", "标题居中"])
    private let indent = UISwitch()
    private var previewHeight: NSLayoutConstraint?
    private var previewMargins: [NSLayoutConstraint] = []
    private var sliders: [String: UISlider] = [:]
    private var values: [String: UILabel] = [:]

    private struct Metric {
        let title: String
        let id: String
        let range: ClosedRange<Float>
        let step: Float
        let key: WritableKeyPath<ReaderPreferences, CGFloat>
    }

    private let metrics: [Metric] = [
        Metric(title: "字号", id: "fontSize", range: 14...36, step: 1, key: \.fontSize),
        Metric(title: "行间距", id: "lineSpacing", range: 0...24, step: 1, key: \.lineSpacing),
        Metric(title: "段间距", id: "paragraphSpacing", range: 0...40, step: 1, key: \.typography.paragraphSpacing),
        Metric(title: "字间距", id: "characterSpacing", range: 0...4, step: 0.5, key: \.typography.characterSpacing),
        Metric(title: "左右留白", id: "horizontalMargin", range: 12...56, step: 1, key: \.typography.horizontalMargin),
        Metric(title: "顶部留白", id: "topMargin", range: 8...56, step: 1, key: \.typography.topMargin),
        Metric(title: "底部留白", id: "bottomMargin", range: 8...56, step: 1, key: \.typography.bottomMargin)
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "字体与排版"
        view.backgroundColor = Theme.bg
        navigationItem.largeTitleDisplayMode = .never
        buildPreview()

        let scroll = UIScrollView()
        scroll.accessibilityIdentifier = "typography.controls"
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: previewCard.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        let content = vstack(spacing: 24)
        scroll.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
        ])
        let presets = UIButton(type: .system)
        presets.setTitle("排版预设", for: .normal)
        presets.accessibilityIdentifier = "typography.presets"
        presets.showsMenuAsPrimaryAction = true
        presets.menu = UIMenu(children: ReaderPreferences.TypographyPreset.allCases.map { preset in
            UIAction(title: preset.title) { [weak self] _ in
                self?.preferences.apply(preset)
                self?.changed()
            }
        })
        fontButton.contentHorizontalAlignment = .leading
        fontButton.titleLabel?.numberOfLines = 2
        fontButton.accessibilityIdentifier = "typography.font"
        fontButton.showsMenuAsPrimaryAction = true
        fontNotice.font = .systemFont(ofSize: 12)
        fontNotice.textColor = Theme.secondary
        fontNotice.numberOfLines = 0
        fontNotice.accessibilityIdentifier = "typography.fontNotice"
        content.addArrangedSubview(hstack([heading("字体"), presets]))
        content.addArrangedSubview(vstack([fontButton, fontNotice], spacing: 8))
        configure(bold, id: "bold") { [weak self] index in
            self?.preferences.typography.bold = index == 1
            self?.changed()
        }
        content.addArrangedSubview(bold)
        for metric in metrics.prefix(4) { content.addArrangedSubview(sliderRow(metric)) }

        indent.accessibilityLabel = "首行缩进两字"
        indent.accessibilityIdentifier = "typography.indent"
        indent.onTintColor = Theme.accent
        indent.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.preferences.typography.firstLineIndent = self.indent.isOn
            self.changed()
        }, for: .valueChanged)
        content.addArrangedSubview(vstack([
            hstack([heading("首行缩进两字"), indent]),
            textLabel("保留正文已有的段首留白，避免重复缩进。", size: 12, color: Theme.secondary)
        ]))
        configure(alignment, id: "alignment") { [weak self] index in
            self?.preferences.typography.alignment = index == 0 ? .left : .justified
            self?.changed()
        }
        configure(titleAlignment, id: "titleAlignment") { [weak self] index in
            self?.preferences.typography.centeredTitle = index == 1
            self?.changed()
        }
        content.addArrangedSubview(alignment)
        content.addArrangedSubview(titleAlignment)
        for metric in metrics.suffix(3) { content.addArrangedSubview(sliderRow(metric)) }
        content.addArrangedSubview(textLabel("留白在屏幕安全区域内生效；分页空间不足时会自动收紧，保证文字可读。", size: 12, color: Theme.secondary))
        let reset = UIButton(type: .system)
        reset.setTitle("恢复默认排版", for: .normal)
        reset.accessibilityIdentifier = "typography.reset"
        reset.addAction(UIAction { [weak self] _ in self?.confirmReset() }, for: .touchUpInside)
        content.addArrangedSubview(reset)
        updateControls()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height: CGFloat = view.bounds.height < 500 ? 100 : 190
        if previewHeight?.constant != height { previewHeight?.constant = height }
    }

    private func buildPreview() {
        previewCard.layer.cornerRadius = 14
        previewCard.layer.borderWidth = 1
        previewCard.accessibilityIdentifier = "typography.previewContent"
        previewCard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewCard)
        previewHeight = previewCard.heightAnchor.constraint(equalToConstant: 190)
        NSLayoutConstraint.activate([
            previewCard.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            previewCard.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            previewCard.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            previewHeight!
        ])
        preview.numberOfLines = 0
        preview.accessibilityIdentifier = "typography.preview"
        preview.translatesAutoresizingMaskIntoConstraints = false
        previewCard.addSubview(preview)
        previewMargins = [
            preview.topAnchor.constraint(equalTo: previewCard.contentLayoutGuide.topAnchor),
            preview.leadingAnchor.constraint(equalTo: previewCard.contentLayoutGuide.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: previewCard.contentLayoutGuide.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: previewCard.contentLayoutGuide.bottomAnchor),
            preview.widthAnchor.constraint(equalTo: previewCard.frameLayoutGuide.widthAnchor)
        ]
        NSLayoutConstraint.activate(previewMargins)
    }

    private func heading(_ text: String) -> UILabel {
        textLabel(text, size: 14, weight: .semibold, color: Theme.ink)
    }

    private func configure(_ control: UISegmentedControl, id: String, changed: @escaping (Int) -> Void) {
        control.accessibilityIdentifier = "typography.\(id)"
        control.addAction(UIAction { [weak control] _ in
            guard let control else { return }
            changed(control.selectedSegmentIndex)
        }, for: .valueChanged)
    }

    private func sliderRow(_ metric: Metric) -> UIView {
        let value = UILabel()
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        value.textColor = Theme.secondary
        value.textAlignment = .right
        value.accessibilityIdentifier = "typography.\(metric.id).value"
        let slider = UISlider()
        slider.minimumValue = metric.range.lowerBound
        slider.maximumValue = metric.range.upperBound
        slider.tintColor = Theme.accent
        slider.isContinuous = false
        slider.accessibilityLabel = metric.title
        slider.accessibilityIdentifier = "typography.\(metric.id)"
        slider.addAction(UIAction { [weak self, weak slider] _ in
            guard let self, let slider else { return }
            self.preferences[keyPath: metric.key] = CGFloat((slider.value / metric.step).rounded() * metric.step)
            self.changed()
        }, for: .valueChanged)
        sliders[metric.id] = slider
        values[metric.id] = value
        return vstack([hstack([heading(metric.title), value]), slider], spacing: 8)
    }

    private func updateControls() {
        for metric in metrics {
            let value = preferences[keyPath: metric.key]
            sliders[metric.id]?.value = Float(value)
            values[metric.id]?.text = String(format: value.rounded() == value ? "%.0f pt" : "%.1f pt", Double(value))
        }
        bold.selectedSegmentIndex = preferences.typography.bold ? 1 : 0
        alignment.selectedSegmentIndex = preferences.typography.alignment == .left ? 0 : 1
        titleAlignment.selectedSegmentIndex = preferences.typography.centeredTitle ? 1 : 0
        indent.isOn = preferences.typography.firstLineIndent
        fontButton.setTitle(preferences.typography.fontTitle + "  ▾", for: .normal)
        fontNotice.text = preferences.typography.isFontAvailable
            ? "可选择本机可用字体；缺失的汉字由系统补全。"
            : "所选字体在此设备不可用，已使用默认字体显示。"
        var actions = YueduTypography.Family.allCases.filter { $0 != .selected }.map { family in
            UIAction(title: family.title, attributes: family.font(size: 21) == nil ? .disabled : [],
                     state: preferences.typography.family == family ? .on : .off) { [weak self] _ in
                self?.preferences.typography.family = family
                self?.changed()
            }
        }
        actions.append(UIAction(title: "更多系统字体…") { [weak self] _ in self?.chooseFont() })
        fontButton.menu = UIMenu(children: actions)
        previewCard.backgroundColor = preferences.paper.background
        previewCard.layer.borderColor = preferences.paper.rule.cgColor
        let insets = preferences.typography.insets
        for (constraint, constant) in zip(previewMargins, [insets.top, insets.left, -insets.right, -insets.bottom, -insets.left - insets.right]) {
            constraint.constant = constant
        }
        let text = NSMutableAttributedString(attributedString: preferences.attributedText("第一章 灯火\n", size: preferences.titleFontSize, isTitle: true))
        text.append(preferences.attributedText("夜色渐深，远处的灯火仍在山间闪烁。他合上书，听见窗外传来细雨的声音。\n新的故事，便从这一刻开始。"))
        preview.attributedText = text
        previewCard.setContentOffset(.zero, animated: false)
    }

    private func changed() {
        preferences.save()
        updateControls()
        onChange?(preferences)
    }

    private func chooseFont() {
        let configuration = UIFontPickerViewController.Configuration()
        configuration.includeFaces = false
        let picker = UIFontPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
        guard let descriptor = viewController.selectedFontDescriptor else { return }
        preferences.typography.family = .selected
        preferences.typography.selectedFontName = UIFont(descriptor: descriptor, size: 21).fontName
        changed()
        viewController.dismiss(animated: true)
    }

    func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) {
        viewController.dismiss(animated: true)
    }

    private func confirmReset() {
        let alert = UIAlertController(title: "恢复默认排版", message: "将字体、字号、间距、缩进、对齐与页边距恢复为默认值。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "恢复", style: .default) { [weak self] _ in
            self?.preferences.resetTypography()
            self?.changed()
        })
        present(alert, animated: true)
    }
}
