import AppKit

/// Terminal settings sheet: preset color scheme cards (background/foreground/
/// cursor swatches, live preview via the scheme-changed notification) and the
/// terminal font size. Modeled after CLI-Manager's general settings panel.
final class TerminalSettingsViewController: NSViewController {
    private var cards: [SchemeCardView] = []

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.frame = NSRect(x: 0, y: 0, width: 660, height: 520)
        root.layer?.backgroundColor = NativeTheme.content.cgColor

        let title = NSTextField(labelWithString: "终端设置")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = NativeTheme.primaryText
        let subtitle = NSTextField(labelWithString: "配置终端配色与字号；修改会即时应用到所有已打开的终端。")
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
        let schemeHint = sectionHint("选择一套配色方案；浅色方案适合高亮环境。")

        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.xPlacement = .fill
        var row: [NSView] = []
        for scheme in TerminalThemeManager.schemes {
            let card = SchemeCardView(scheme: scheme)
            card.onSelect = { [weak self] in
                TerminalThemeManager.select(scheme.id)
                self?.refreshSelection()
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

        let fontLabel = sectionLabel("终端字号")
        let fontHint = sectionHint("影响终端文字与行高；界面字体不受影响。")
        let sizes: [(String, CGFloat)] = [("小 12", 12), ("标准 13", 13), ("大 15", 15), ("特大 17", 17)]
        let fontSegment = NSSegmentedControl(
            labels: sizes.map(\.0), trackingMode: .selectOne, target: self,
            action: #selector(fontSizeChanged(_:))
        )
        let current = TerminalThemeManager.fontSize
        if let index = sizes.firstIndex(where: { $0.1 == current }) {
            fontSegment.selectedSegment = index
        }

        let scroll = NSScrollView()
        let content = NSStackView(views: [schemeLabel, schemeHint, grid, fontLabel, fontHint, fontSegment])
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
        refreshSelection()
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

    private func refreshSelection() {
        let current = TerminalThemeManager.current
        for card in cards {
            card.isSelected = card.scheme.id == current.id
        }
    }

    @objc private func closeClicked() {
        dismiss(self)
    }

    @objc private func fontSizeChanged(_ sender: NSSegmentedControl) {
        let sizes: [CGFloat] = [12, 13, 15, 17]
        guard sender.selectedSegment >= 0, sender.selectedSegment < sizes.count else { return }
        TerminalThemeManager.update(fontSize: sizes[sender.selectedSegment])
    }
}

/// One preset card: three color swatches, the scheme name, its description and
/// a "当前" badge when active. Click selects the scheme (live preview).
final class SchemeCardView: NSView {
    let scheme: TerminalScheme
    var onSelect: (() -> Void)?
    var isSelected = false {
        didSet { restyle() }
    }

    private let badge = NSTextField(labelWithString: "当前")

    init(scheme: TerminalScheme) {
        self.scheme = scheme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10

        let swatches = NSStackView(views: [
            swatch(TerminalThemeManager.nsColor(scheme.background), bordered: scheme.isLight),
            swatch(TerminalThemeManager.nsColor(scheme.foreground)),
            swatch(TerminalThemeManager.nsColor(scheme.cursor)),
        ])
        swatches.orientation = .horizontal
        swatches.spacing = 6

        let name = NSTextField(labelWithString: scheme.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = NativeTheme.primaryText

        let badgeRow = NSStackView(views: [name, badge])
        badgeRow.orientation = .horizontal
        badgeRow.spacing = 6
        badgeRow.alignment = .centerY

        let detail = NSTextField(labelWithString: scheme.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = NativeTheme.secondaryText
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 2
        detail.setContentCompressionResistancePriority(.required, for: .vertical)

        let content = NSStackView(views: [swatches, badgeRow, detail])
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
        restyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func swatch(_ color: NSColor, bordered: Bool = false) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.layer?.cornerRadius = 4
        view.layer?.borderWidth = bordered ? 1 : 0
        view.layer?.borderColor = NativeTheme.cardHover.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 18),
            view.heightAnchor.constraint(equalToConstant: 18),
        ])
        return view
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
