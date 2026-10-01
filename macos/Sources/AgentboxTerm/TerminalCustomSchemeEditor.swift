import AppKit

/// Editor for the user-defined color scheme: background/foreground/cursor via
/// color wells plus hex fields, the 16 ANSI slots as hex fields with swatches,
/// and a "copy from preset" shortcut. Every valid change is stored through
/// TerminalThemeManager.updateCustom and live-applies to open terminals.
final class CustomSchemeEditorView: NSView, NSTextFieldDelegate {
    private var topFields: [NSTextField] = []
    private var topWells: [NSColorWell] = []
    private var ansiFields: [NSTextField] = []
    private var ansiSwatches: [NSView] = []
    private var presetPopup: NSPopUpButton?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUp() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NativeTheme.card.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NativeTheme.border.cgColor

        // Background / foreground / cursor: label above a well + hex field row.
        var topViews: [NSView] = []
        for (index, title) in ["背景", "前景", "光标"].enumerated() {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = NativeTheme.secondaryText

            let well = NSColorWell()
            well.tag = index
            well.isBordered = true
            well.isContinuous = true
            well.target = self
            well.action = #selector(wellChanged(_:))
            well.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                well.widthAnchor.constraint(equalToConstant: 34),
                well.heightAnchor.constraint(equalToConstant: 22),
            ])

            let field = hexField(tag: index)
            field.delegate = self
            field.target = self
            field.action = #selector(fieldSubmitted(_:))

            let row = NSStackView(views: [well, field])
            row.orientation = .horizontal
            row.spacing = 6
            let column = NSStackView(views: [label, row])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 4
            topViews.append(column)
            topFields.append(field)
            topWells.append(well)
        }

        let ansiLabel = NSTextField(labelWithString: "ANSI 16 色")
        ansiLabel.font = .systemFont(ofSize: 11, weight: .medium)
        ansiLabel.textColor = NativeTheme.secondaryText

        let ansiGrid = NSGridView(numberOfColumns: 8, rows: 0)
        ansiGrid.rowSpacing = 5
        ansiGrid.columnSpacing = 6
        var row: [NSView] = []
        for index in 0..<16 {
            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = 3
            swatch.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                swatch.widthAnchor.constraint(equalToConstant: 10),
                swatch.heightAnchor.constraint(equalToConstant: 10),
            ])
            let field = hexField(tag: 100 + index)
            field.delegate = self
            field.target = self
            field.action = #selector(fieldSubmitted(_:))
            field.toolTip = "槽位 \(index) · \(TerminalThemeManager.ansiSlotNames[index])"

            let cell = NSStackView(views: [swatch, field])
            cell.orientation = .horizontal
            cell.spacing = 4
            row.append(cell)
            ansiFields.append(field)
            ansiSwatches.append(swatch)
            if row.count == 8 {
                ansiGrid.addRow(with: row)
                row = []
            }
        }
        if !row.isEmpty {
            ansiGrid.addRow(with: row)
        }

        let presetLabel = NSTextField(labelWithString: "复制预设")
        presetLabel.font = .systemFont(ofSize: 11, weight: .medium)
        presetLabel.textColor = NativeTheme.secondaryText
        let popup = NSPopUpButton()
        for scheme in TerminalThemeManager.schemes {
            popup.addItem(withTitle: scheme.name)
            popup.lastItem?.representedObject = scheme.id
        }
        popup.target = self
        popup.action = #selector(copyPreset(_:))
        presetPopup = popup
        let presetHint = NSTextField(labelWithString: "先用预设打底，再微调单个颜色。")
        presetHint.font = .systemFont(ofSize: 10)
        presetHint.textColor = NativeTheme.secondaryText

        let content = NSStackView(views: [
            topViews[0], topViews[1], topViews[2],
            ansiLabel, ansiGrid,
            presetLabel, popup, presetHint,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refresh()
    }

    private func hexField(tag: Int) -> NSTextField {
        let field = NSTextField(string: "")
        field.tag = tag
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        field.textColor = NativeTheme.primaryText
        field.placeholderString = "#RRGGBB"
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: 78),
            field.heightAnchor.constraint(equalToConstant: 22),
        ])
        return field
    }

    /// Syncs all fields/wells from the stored custom scheme. The field the
    /// user is typing in is left untouched so live updates never clobber it.
    func refresh() {
        guard let scheme = TerminalThemeManager.customScheme else { return }
        let topHexes = [scheme.background, scheme.foreground, scheme.cursor]
        for (index, hex) in topHexes.enumerated() where index < topFields.count {
            let field = topFields[index]
            if field.currentEditor() == nil {
                field.stringValue = hex
            }
            markValid(field, valid: TerminalThemeManager.normalizedHex(field.stringValue) != nil)
            topWells[index].color = TerminalThemeManager.nsColor(hex)
        }
        for (index, hex) in scheme.ansi.enumerated() where index < ansiFields.count {
            let field = ansiFields[index]
            if field.currentEditor() == nil {
                field.stringValue = hex
            }
            markValid(field, valid: TerminalThemeManager.normalizedHex(field.stringValue) != nil)
            ansiSwatches[index].layer?.backgroundColor = TerminalThemeManager.nsColor(hex).cgColor
        }
    }

    private func markValid(_ field: NSTextField, valid: Bool) {
        field.textColor = valid ? NativeTheme.primaryText : NSColor.systemRed
    }

    private func apply(_ hex: String?, toField field: NSTextField) {
        guard let hex else {
            markValid(field, valid: false)
            return
        }
        markValid(field, valid: true)
        let index = field.tag < 100 ? field.tag : -1
        let slot = field.tag >= 100 ? field.tag - 100 : -1
        TerminalThemeManager.updateCustom { scheme in
            if index >= 0 {
                switch index {
                case 0: scheme = scheme.with(background: hex)
                case 1: scheme = scheme.with(foreground: hex)
                case 2: scheme = scheme.with(cursor: hex)
                default: break
                }
            } else if slot >= 0, slot < scheme.ansi.count {
                var colors = scheme.ansi
                colors[slot] = hex
                scheme = scheme.with(ansi: colors)
            }
        }
        if index >= 0, index < topWells.count {
            topWells[index].color = TerminalThemeManager.nsColor(hex)
        } else if slot >= 0, slot < ansiSwatches.count {
            ansiSwatches[slot].layer?.backgroundColor = TerminalThemeManager.nsColor(hex).cgColor
        }
    }

    // MARK: Actions

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        // Validate as the user types but only commit complete values, so a
        // half-typed "#12" neither flashes red nor clobbers the scheme.
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
        let complete = TerminalThemeManager.normalizedHex(trimmed)
        let plausible = trimmed.dropFirst().allSatisfy({ $0.isHexDigit }) || trimmed.isEmpty
        markValid(field, valid: complete != nil || plausible)
        guard let complete else { return }
        apply(complete, toField: field)
    }

    @objc private func fieldSubmitted(_ sender: NSTextField) {
        apply(TerminalThemeManager.normalizedHex(sender.stringValue), toField: sender)
    }

    @objc private func wellChanged(_ sender: NSColorWell) {
        guard sender.tag < topFields.count else { return }
        let color = sender.color.usingColorSpace(.sRGB) ?? sender.color
        let red = Int(round(color.redComponent * 255))
        let green = Int(round(color.greenComponent * 255))
        let blue = Int(round(color.blueComponent * 255))
        let hex = String(format: "#%02X%02X%02X", red, green, blue)
        apply(hex, toField: topFields[sender.tag])
    }

    @objc private func copyPreset(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String,
              let source = TerminalThemeManager.schemes.first(where: { $0.id == id }) else { return }
        TerminalThemeManager.updateCustom { scheme in
            scheme = source.with(id: TerminalThemeManager.customSchemeID, name: scheme.name, detail: scheme.detail)
        }
        refresh()
    }
}
