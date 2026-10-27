import UIKit

final class ReadingSettingsViewController: UIViewController {
    var onChange: ((ReaderPreferences) -> Void)?
    var onDismiss: (() -> Void)?
    var purificationBook: Book?
    var purificationChapterTitle = "第一章 初见"
    var purificationOriginal: String?
    private var preferences = ReaderPreferences.load()
    private let stack = UIStackView()
    private let preview = UILabel()
    private let previewCard = UIView()
    private let fontValue = UILabel()
    private let spacingValue = UILabel()
    private var themeButtons: [UIButton] = []
    private var sliders: [String: UISlider] = [:]
    private let typographyButton = UIButton(type: .system)

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        preferences = ReaderPreferences.load()
        updatePreview()
        navigationController?.setNavigationBarHidden(false, animated: animated)
        // UIKit may load this view while constructing the navigation controller,
        // before that controller has a presenter. Decide once presentation begins.
        if navigationController?.presentingViewController != nil {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(close))
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "阅读设置"
        view.backgroundColor = Theme.bg
        navigationItem.largeTitleDisplayMode = .never
        let scrollView = UIScrollView()
        scrollView.accessibilityIdentifier = "readingSettings.content"
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        stack.axis = .vertical
        stack.spacing = 27
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -36),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -48)
        ])
        previewCard.layer.cornerRadius = 18
        previewCard.layer.borderWidth = 1
        preview.numberOfLines = 0
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.accessibilityIdentifier = "readingSettings.preview"
        previewCard.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: previewCard.topAnchor, constant: 22),
            preview.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor, constant: 22),
            preview.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor, constant: -22),
            preview.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor, constant: -22)
        ])
        stack.addArrangedSubview(previewCard)
        let purification = UIButton(type: .system)
        purification.setTitle("正文净化 · 规则与预览", for: .normal)
        purification.contentHorizontalAlignment = .leading
        purification.accessibilityIdentifier = "readingSettings.purification"
        purification.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.navigationController?.pushViewController(YueduPurificationViewController(book: self.purificationBook,
                chapterTitle: self.purificationChapterTitle, original: self.purificationOriginal), animated: true)
            self.navigationController?.sheetPresentationController?.selectedDetentIdentifier = .large
        }, for: .touchUpInside)
        stack.addArrangedSubview(purification)
        let turnStyle = UISegmentedControl(items: ReaderPreferences.TurnStyle.allCases.map(\.title))
        turnStyle.selectedSegmentIndex = ReaderPreferences.TurnStyle.allCases.firstIndex(of: preferences.turnStyle) ?? 0
        turnStyle.accessibilityIdentifier = "readingSettings.turnStyle"
        turnStyle.addAction(UIAction { [weak self, weak turnStyle] _ in
            guard let self, let turnStyle else { return }
            self.preferences.turnStyle = ReaderPreferences.TurnStyle.allCases[turnStyle.selectedSegmentIndex]
            self.changed()
        }, for: .valueChanged)
        stack.addArrangedSubview(vstack([sectionTitle("翻页方式"), turnStyle,
            textLabel("平移模式可左右滑动，也可轻点左右区域翻页。", size: 12, color: Theme.secondary)
        ], spacing: 12))
        stack.addArrangedSubview(sliderSection(title: "文字大小", symbol: "textformat.size", valueLabel: fontValue,
                                              value: Float(preferences.fontSize), min: 14, max: 36, action: #selector(fontChanged(_:)), id: "fontSize"))
        stack.addArrangedSubview(sliderSection(title: "行间留白", symbol: "line.3.horizontal", valueLabel: spacingValue,
                                              value: Float(preferences.lineSpacing), min: 0, max: 24, action: #selector(spacingChanged(_:)), id: "lineSpacing"))
        typographyButton.contentHorizontalAlignment = .leading
        typographyButton.titleLabel?.numberOfLines = 2
        typographyButton.accessibilityIdentifier = "readingSettings.typography"
        typographyButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let controller = YueduTypographyViewController()
            controller.onChange = { [weak self] preferences in
                self?.preferences = preferences
                self?.updatePreview()
                self?.onChange?(preferences)
            }
            self.navigationController?.pushViewController(controller, animated: true)
            self.navigationController?.sheetPresentationController?.selectedDetentIdentifier = .large
        }, for: .touchUpInside)
        stack.addArrangedSubview(typographyButton)
        let themeSection = UIStackView()
        themeSection.axis = .vertical
        themeSection.spacing = 14
        themeSection.addArrangedSubview(sectionTitle("纸张与背景"))
        let themeRow = UIStackView()
        themeRow.spacing = 12
        themeRow.distribution = .fillEqually
        for (index, paper) in ReaderPreferences.Paper.allCases.enumerated() {
            let button = UIButton(type: .system)
            button.tag = index
            button.backgroundColor = paper.background
            button.setTitle(paper.title, for: .normal)
            button.setTitleColor(paper.ink, for: .normal)
            button.titleLabel?.font = .yueduUI(ofSize: 15, weight: .medium)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.layer.cornerRadius = 13
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
            button.accessibilityLabel = "\(paper.title)主题"
            button.accessibilityIdentifier = "readingSettings.theme.\(paper.rawValue)"
            button.addTarget(self, action: #selector(themeChanged(_:)), for: .touchUpInside)
            themeButtons.append(button)
            themeRow.addArrangedSubview(button)
        }
        themeSection.addArrangedSubview(themeRow)
        stack.addArrangedSubview(themeSection)
        stack.addArrangedSubview(sliderSection(title: "屏幕亮度", symbol: "sun.max", valueLabel: nil,
                                              value: Float(UIScreen.main.brightness), min: 0.05, max: 1, action: #selector(brightnessChanged(_:)), id: "brightness"))
        stack.addArrangedSubview(vstack([
            switchRow(title: "章末预读下一章", id: "prefetch", isOn: preferences.prefetchNextChapter) { [weak self] value in
                self?.preferences.prefetchNextChapter = value
                self?.changed()
            },
            switchRow(title: "全屏阅读", id: "fullScreen", isOn: preferences.fullScreen) { [weak self] value in
                self?.preferences.fullScreen = value
                self?.changed()
            },
            switchRow(title: "全屏时显示状态栏", id: "fullScreenStatusBar", isOn: preferences.showsStatusBarInFullScreen) { [weak self] value in
                self?.preferences.showsStatusBarInFullScreen = value
                self?.changed()
            },
            textLabel("轻点正文中央可显示或隐藏功能栏。功能栏覆盖在正文上方，显隐不改变排版；正文始终按全屏安全区域显示。", size: 12, color: Theme.secondary)
        ], spacing: 16))
        let note = UILabel()
        note.text = "文字、间距与纸张偏好会自动保存。\n留一点空白，让阅读慢下来。"
        note.font = .yueduUI(ofSize: 12)
        note.adjustsFontForContentSizeCategory = true
        note.textColor = Theme.secondary
        note.numberOfLines = 0
        stack.addArrangedSubview(note)
        updatePreview()
    }

    private func sectionTitle(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .yueduUI(ofSize: 14, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.ink
        return label
    }

    private func switchRow(title: String, id: String, isOn: Bool, onChange: @escaping (Bool) -> Void) -> UIView {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.onTintColor = Theme.accent
        toggle.accessibilityLabel = title
        toggle.accessibilityIdentifier = "readingSettings.\(id)"
        toggle.addAction(UIAction { [weak toggle] _ in
            guard let toggle else { return }
            onChange(toggle.isOn)
        }, for: .valueChanged)
        let row = UIStackView(arrangedSubviews: [sectionTitle(title), toggle])
        row.alignment = .center
        row.spacing = 12
        return row
    }

    private func sliderSection(title: String, symbol: String, valueLabel: UILabel?, value: Float, min: Float, max: Float, action: Selector, id: String) -> UIView {
        let section = UIStackView()
        section.axis = .vertical
        section.spacing = 10
        let header = UIStackView()
        header.addArrangedSubview(sectionTitle(title))
        if let valueLabel {
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            valueLabel.textColor = Theme.secondary
            valueLabel.textAlignment = .right
            header.addArrangedSubview(valueLabel)
        }
        section.addArrangedSubview(header)
        let sliderRow = UIStackView()
        sliderRow.alignment = .center
        sliderRow.spacing = 14
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = Theme.secondary
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let slider = UISlider()
        slider.minimumValue = min
        slider.maximumValue = max
        slider.value = value
        slider.isContinuous = id == "brightness"
        slider.tintColor = Theme.accent
        slider.accessibilityLabel = title
        slider.accessibilityIdentifier = "readingSettings.\(id)"
        slider.addTarget(self, action: action, for: .valueChanged)
        sliders[id] = slider
        sliderRow.addArrangedSubview(icon)
        sliderRow.addArrangedSubview(slider)
        section.addArrangedSubview(sliderRow)
        return section
    }

    private func updatePreview() {
        fontValue.text = "\(Int(preferences.fontSize)) pt"
        spacingValue.text = "\(Int(preferences.lineSpacing)) pt"
        sliders["fontSize"]?.value = Float(preferences.fontSize)
        sliders["lineSpacing"]?.value = Float(preferences.lineSpacing)
        typographyButton.setTitle("字体与排版  ›\n\(preferences.typography.fontTitle) · 字距、段距、缩进与页边距", for: .normal)
        previewCard.backgroundColor = preferences.paper.background
        previewCard.layer.borderColor = preferences.paper.rule.cgColor
        preview.attributedText = preferences.attributedText("日光从树叶间落下来，\n翻过一页，又是一个世界。", size: min(preferences.fontSize, 25))
        for (index, button) in themeButtons.enumerated() {
            let selected = ReaderPreferences.Paper.allCases[index] == preferences.paper
            button.layer.borderWidth = selected ? 2 : 1
            button.layer.borderColor = (selected ? Theme.accent : Theme.line).cgColor
            button.accessibilityTraits = selected ? [.button, .selected] : [.button]
        }
    }

    private func changed() {
        preferences.save()
        updatePreview()
        onChange?(preferences)
    }

    @objc private func fontChanged(_ slider: UISlider) { preferences.fontSize = CGFloat(slider.value.rounded()); changed() }
    @objc private func spacingChanged(_ slider: UISlider) { preferences.lineSpacing = CGFloat(slider.value.rounded()); changed() }
    @objc private func themeChanged(_ button: UIButton) { preferences.paper = ReaderPreferences.Paper.allCases[button.tag]; changed() }
    @objc private func brightnessChanged(_ slider: UISlider) { UIScreen.main.brightness = CGFloat(slider.value) }
    @objc private func close() {
        let completion = onDismiss
        dismiss(animated: true, completion: completion)
    }
}
