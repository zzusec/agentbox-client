import AppKit

/// Terminal settings sheet: preset + custom color scheme cards, the custom
/// scheme editor, terminal font family/size, and the mouse reporting mode.
/// Modeled after CLI-Manager's general settings panel. Every change posts the
/// scheme-changed notification and applies live to open terminals.
final class TerminalSettingsViewController: NSViewController {
    private var cards: [SchemeCardView] = []
    private var editor: CustomSchemeEditorView?
    private var fontPopup: NSPopUpButton?
    private var fontPreview: NSTextField?
    private var mouseSegment: NSSegmentedControl?
    private var mouseHint: NSTextField?
    private var autoFontCheck: NSButton?
    private var fitColumnsSegment: NSSegmentedControl?

    private static let fitColumnChoices = [80, 100, 120, 160]

    private static let fontSizes: [(String, CGFloat)] = [
        ("小 12", 12), ("标准 13", 13), ("大 15", 15), ("特大 17", 17),
    ]

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.frame = NSRect(x: 0, y: 0, width: 660, height: 560)
        root.layer?.backgroundColor = NativeTheme.content.cgColor

        let title = NSTextField(labelWithString: "终端设置")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = NativeTheme.primaryText
        let subtitle = NSTextField(labelWithString: "配置终端配色、字体与鼠标行为；修改会即时应用到所有已打开的终端。")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = NativeTheme.secondaryText
        let headerText = NSStackView(views: [title, subtitle])
        headerText.orientation = .vertical
        headerText.spacing = 2
        headerText.alignment = .leading

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeClicked))
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .regular
        closeButton.keyEquivalent = "\r"

        let header = NSStackView(views: [headerText, closeButton])
        header.orientation = .horizontal
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false

        let schemeLabel = sectionLabel("终端配色")
        let schemeHint = sectionHint("选择一套配色方案；浅色方案适合高亮环境。自定义卡片可微调每个颜色。")

        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.xPlacement = .fill
        var row: [NSView] = []
        for scheme in TerminalThemeManager.choices {
            let card = SchemeCardView(scheme: scheme)
            card.onSelect = { [weak self, weak card] in
                self?.selectCard(card)
            }
            cards.append(card)
            row.append(card)
            if row.count == 3 {
                grid.addRow(with: row)
                row = []
            }
        }
        if !row.isEmpty {
            grid.addRow(with: row)
        }

        let editor = CustomSchemeEditorView()
        editor.translatesAutoresizingMaskIntoConstraints = false
        self.editor = editor

        let fontLabel = sectionLabel("终端字体")
        let fontHint = sectionHint("字体族仅列出本机已安装的等宽字体；中文等宽字符始终有苹方等回退。")
        let fontPopup = NSPopUpButton()
        for family in TerminalThemeManager.installedFontFamilies {
            fontPopup.addItem(withTitle: family.displayName)
            fontPopup.lastItem?.representedObject = family.id
        }
        fontPopup.target = self
        fontPopup.action = #selector(fontFamilyChanged(_:))
        self.fontPopup = fontPopup

        let preview = NSTextField(labelWithString: "")
        preview.font = TerminalThemeManager.font()
        preview.textColor = NativeTheme.primaryText
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 6
        preview.layer?.backgroundColor = NativeTheme.card.cgColor
        preview.layer?.borderWidth = 1
        preview.layer?.borderColor = NativeTheme.border.cgColor
        let previewHolder = NSStackView(views: [preview])
        previewHolder.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        self.fontPreview = preview

        let sizeLabel = sectionLabel("终端字号")
        let sizeHint = sectionHint("影响终端文字与行高；界面字体不受影响。")
        let fontSegment = NSSegmentedControl(
            labels: Self.fontSizes.map(\.0), trackingMode: .selectOne, target: self,
            action: #selector(fontSizeChanged(_:))
        )

        let fitLabel = sectionLabel("自动字号")
        let fitHint = sectionHint("窗口放不下目标列数时自动缩小字号（不超过上面选的字号，最小 8pt），避免 TUI 把内容截断。")
        let autoFontCheck = NSButton(
            checkboxWithTitle: "按窗口宽度自动缩小", target: self, action: #selector(autoFontChanged(_:))
        )
        self.autoFontCheck = autoFontCheck
        let fitColumnsSegment = NSSegmentedControl(
            labels: Self.fitColumnChoices.map { "\($0) 列" }, trackingMode: .selectOne, target: self,
            action: #selector(fitColumnsChanged(_:))
        )
        self.fitColumnsSegment = fitColumnsSegment

        let mouseLabel = sectionLabel("鼠标上报")
        let mouseHint = sectionHint("")
        let modes: [TerminalMouseMode] = [.off, .on]
        let mouseSegment = NSSegmentedControl(
            labels: modes.map(\.label), trackingMode: .selectOne, target: self,
            action: #selector(mouseModeChanged(_:))
        )
        self.mouseSegment = mouseSegment
        self.mouseHint = mouseHint

        let scroll = NSScrollView()
        let content = NSStackView(views: [
            schemeLabel, schemeHint, grid, editor,
            fontLabel, fontHint, fontPopup, previewHolder,
            sizeLabel, sizeHint, fontSegment,
            fitLabel, fitHint, autoFontCheck, fitColumnsSegment,
            mouseLabel, mouseHint, mouseSegment,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        view = root
        NotificationCenter.default.addObserver(
            self, selector: #selector(schemeChangedExternally),
            name: TerminalThemeManager.schemeChanged, object: nil
        )
        refreshSelection()
    }

    /// Editor changes post the scheme-changed notification so open terminals
    /// live-update; the sheet mirrors them onto the card swatches. The
    /// handler only reads state, so it cannot feed back into the notification.
    @objc private func schemeChangedExternally() {
        refreshSelection()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = NativeTheme.primaryText
        return label
    }

    private func sectionHint(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = NativeTheme.secondaryText
        return label
    }

    private func selectCard(_ card: SchemeCardView?) {
        guard let card else { return }
        if card.scheme.id == TerminalThemeManager.customSchemeID,
           TerminalThemeManager.customScheme == nil {
            TerminalThemeManager.createCustom(from: TerminalThemeManager.current)
        } else {
            TerminalThemeManager.select(card.scheme.id)
        }
        refreshSelection()
    }

    private func refreshSelection() {
        let current = TerminalThemeManager.current
        for card in cards {
            if card.scheme.id == TerminalThemeManager.customSchemeID {
                card.scheme = TerminalThemeManager.choices.last!
            }
            card.isSelected = card.scheme.id == current.id
        }
        editor?.isHidden = current.id != TerminalThemeManager.customSchemeID
        editor?.refresh()

        if let fontPopup {
            let id = TerminalThemeManager.fontFamily.id
            let index = fontPopup.itemArray.firstIndex { ($0.representedObject as? String) == id } ?? 0
            fontPopup.selectItem(at: index)
        }
        fontPreview?.font = TerminalThemeManager.font()
        fontPreview?.attributedStringValue = NSAttributedString(
            string: "AaBbGg 0O1lI → 中文 ❯ ~!@#",
            attributes: [.font: TerminalThemeManager.font()]
        )

        let auto = TerminalThemeManager.autoFontSize
        autoFontCheck?.state = auto ? .on : .off
        fitColumnsSegment?.isEnabled = auto
        fitColumnsSegment?.selectedSegment =
            Self.fitColumnChoices.firstIndex(of: TerminalThemeManager.fitColumns) ?? 1

        let modes: [TerminalMouseMode] = [.off, .on]
        let mode = TerminalThemeManager.mouseMode
        if let mouseSegment {
            mouseSegment.selectedSegment = modes.firstIndex(of: mode) ?? 0
        }
        mouseHint?.stringValue = {
            switch mode {
            case .off:
                return "鼠标事件不转发给终端应用：拖动即选中，⌘C 复制，滚轮滚动本地缓冲（默认）。"
            case .on:
                return "点击/拖动转发给 TUI 应用（vim、tmux 等）；按住 ⇧ 拖动仍是本地选中，⌘C 可复制。"
            }
        }()
    }

    @objc private func closeClicked() {
        dismiss(self)
    }

    @objc private func fontSizeChanged(_ sender: NSSegmentedControl) {
        let sizes = Self.fontSizes.map(\.1)
        guard sender.selectedSegment >= 0, sender.selectedSegment < sizes.count else { return }
        TerminalThemeManager.update(fontSize: sizes[sender.selectedSegment])
        refreshSelection()
    }

    @objc private func fontFamilyChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        TerminalThemeManager.selectFontFamily(id)
        refreshSelection()
    }

    @objc private func autoFontChanged(_ sender: NSButton) {
        TerminalThemeManager.update(autoFontSize: sender.state == .on)
        refreshSelection()
    }

    @objc private func fitColumnsChanged(_ sender: NSSegmentedControl) {
        let choices = Self.fitColumnChoices
        guard sender.selectedSegment >= 0, sender.selectedSegment < choices.count else { return }
        TerminalThemeManager.update(fitColumns: choices[sender.selectedSegment])
        refreshSelection()
    }

    @objc private func mouseModeChanged(_ sender: NSSegmentedControl) {
        let modes: [TerminalMouseMode] = [.off, .on]
        guard sender.selectedSegment >= 0, sender.selectedSegment < modes.count else { return }
        TerminalThemeManager.update(mouseMode: modes[sender.selectedSegment])
        refreshSelection()
    }
}

/// One scheme card: three color swatches, the scheme name, its description and
/// a "当前" badge when active. Click selects the scheme (live preview).
final class SchemeCardView: NSView {
    var scheme: TerminalScheme {
        didSet { refreshContent() }
    }
    var onSelect: (() -> Void)?
    var isSelected = false {
        didSet { restyle() }
    }

    private let badge = NSTextField(labelWithString: "当前")
    private let swatches: [NSView] = (0..<3).map { _ in
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 4
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 18),
            view.heightAnchor.constraint(equalToConstant: 18),
        ])
        return view
    }
    private let nameLabel: NSTextField
    private let detailLabel: NSTextField

    init(scheme: TerminalScheme) {
        self.scheme = scheme
        nameLabel = NSTextField(labelWithString: scheme.name)
        detailLabel = NSTextField(labelWithString: scheme.detail)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10

        let swatchRow = NSStackView(views: swatches)
        swatchRow.orientation = .horizontal
        swatchRow.spacing = 6

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = NativeTheme.primaryText

        let badgeRow = NSStackView(views: [nameLabel, badge])
        badgeRow.orientation = .horizontal
        badgeRow.spacing = 6
        badgeRow.alignment = .centerY

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = NativeTheme.secondaryText
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2
        detailLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        let content = NSStackView(views: [swatchRow, badgeRow, detailLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 104),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 14),
        ])
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NativeTheme.accent.cgColor
        badge.layer?.cornerRadius = 8
        badge.font = .systemFont(ofSize: 9, weight: .medium)
        badge.textColor = .white
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 34),
            badge.heightAnchor.constraint(equalToConstant: 16),
        ])
        refreshContent()
        restyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func refreshContent() {
        let colors = [scheme.background, scheme.foreground, scheme.cursor]
        for (index, hex) in colors.enumerated() where index < swatches.count {
            swatches[index].layer?.backgroundColor = TerminalThemeManager.nsColor(hex).cgColor
            swatches[index].layer?.borderWidth = scheme.isLight ? 1 : 0
            swatches[index].layer?.borderColor = NativeTheme.cardHover.cgColor
        }
        nameLabel.stringValue = scheme.name
        detailLabel.stringValue = scheme.detail
    }

    private func restyle() {
        layer?.backgroundColor = isSelected
            ? NativeTheme.accent.withAlphaComponent(0.10).cgColor
            : NativeTheme.card.cgColor
        layer?.borderWidth = isSelected ? 1.5 : 1
        layer?.borderColor = isSelected
            ? NativeTheme.accent.cgColor
            : NativeTheme.cardHover.cgColor
        badge.isHidden = !isSelected
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }
}
