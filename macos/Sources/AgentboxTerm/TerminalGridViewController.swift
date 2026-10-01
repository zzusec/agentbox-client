import AppKit

/// Tabbed terminal area: one terminal per tab (status dot + project name +
/// close), a single terminal visible at a time. Closing a tab dismisses the
/// terminal to the background — the instance keeps running server-side.
final class TerminalGridViewController: NSViewController {
    /// A tab was closed; the owner must forget it so the project can be
    /// reopened from the sidebar.
    var onPaneClosed: ((TerminalViewController) -> Void)?

    private let tabBar = NSStackView()
    private let container = NSView()
    private let emptyState = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "选择一个项目开始")
    private let emptyDetail = NSTextField(labelWithString: "打开的终端会出现在顶部标签里，点 × 收起后实例继续运行。")
    private var terminals: [TerminalViewController] = []
    private var selected: TerminalViewController?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NativeTheme.terminalBackground.cgColor

        tabBar.orientation = .horizontal
        tabBar.alignment = .centerY
        tabBar.spacing = 6
        tabBar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NativeTheme.terminalBackground.cgColor

        let icon = NSImageView(image: NativeTheme.symbol("rectangle.grid.2x2", size: 30, weight: .regular) ?? NSImage())
        icon.contentTintColor = NativeTheme.secondaryText
        emptyTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        emptyTitle.textColor = NSColor(calibratedWhite: 0.86, alpha: 1)
        emptyDetail.font = .systemFont(ofSize: 12)
        emptyDetail.textColor = NSColor(calibratedWhite: 0.62, alpha: 1)
        let title = emptyTitle
        let detail = emptyDetail
        emptyState.setViews([icon, title, detail], in: .top)
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(container)
        root.addSubview(tabBar)
        root.addSubview(emptyState)
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
        applySchemeBackground()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applySchemeBackground),
            name: TerminalThemeManager.schemeChanged, object: nil
        )
        updateEmptyState()
    }

    /// The terminal area (tab strip, container, empty state) follows the
    /// terminal scheme's background instead of the fixed dark chrome, so a
    /// light scheme does not clash with the app chrome.
    @objc private func applySchemeBackground() {
        let scheme = TerminalThemeManager.current
        let background = TerminalThemeManager.nsColor(scheme.background)
        view.layer?.backgroundColor = background.cgColor
        container.layer?.backgroundColor = background.cgColor
        let light = scheme.isLight
        emptyTitle.textColor = light
            ? NativeTheme.primaryText
            : NSColor(calibratedWhite: 0.86, alpha: 1)
        emptyDetail.textColor = light
            ? NativeTheme.secondaryText
            : NSColor(calibratedWhite: 0.62, alpha: 1)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func contains(workspaceID: String, projectName: String) -> TerminalViewController? {
        terminals.first {
            $0.workspace.id == workspaceID && $0.project.name == projectName
        }
    }

    func add(client: AgentboxClient, workspace: Workspace, project: RemoteProject) -> TerminalViewController {
        let terminal = TerminalViewController(client: client, workspace: workspace, project: project)
        terminal.onClose = { [weak self, weak terminal] in
            guard let self, let terminal else { return }
            self.remove(terminal)
        }
        terminal.onConnectionState = { [weak self, weak terminal] _ in
            guard let self, let terminal else { return }
            self.refreshChip(for: terminal)
        }
        addChild(terminal)
        terminals.append(terminal)
        rebuildTabs()
        select(terminal)
        return terminal
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Window resize / sidebar toggle: keep the PTY width in lockstep with
        // the visible width, or SwiftTerm leaves the uncovered strip with
        // stale cells (bottom rows appearing at the right edge).
        selected?.refitPTY()
    }

    /// Bring an already-open terminal to the front.
    func select(_ terminal: TerminalViewController) {
        guard terminals.contains(where: { $0 === terminal }) else { return }
        if selected === terminal, terminal.view.superview === container {
            terminal.activateTerminal()
            return
        }
        selected?.isActive = false
        selected = terminal
        terminal.isActive = true
        container.subviews.forEach { $0.removeFromSuperview() }
        terminal.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal.view)
        NSLayoutConstraint.activate([
            terminal.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.view.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        rebuildTabs()
        updateEmptyState()
        view.window?.title = terminal.project.name
        terminal.refitPTY()
        terminal.activateTerminal()
    }

    /// Close a tab and dismiss the terminal to the background: drop the local
    /// connection, keep the server-side session running (tmux survives
    /// disconnects by contract).
    func remove(_ terminal: TerminalViewController) {
        let window = terminal.view.window
        let firstResponder = window?.firstResponder as? NSView
        let wasFocused = firstResponder?.isDescendant(of: terminal.view) == true
        terminal.closeSession()
        terminals.removeAll { $0 === terminal }
        terminal.removeFromParent()
        if selected === terminal {
            selected = terminals.last
        }
        if let next = selected {
            select(next)
        } else {
            rebuildTabs()
            updateEmptyState()
        }
        onPaneClosed?(terminal)
    }

    private func refreshChip(for terminal: TerminalViewController) {
        for case let chip as TerminalTabChip in tabBar.arrangedSubviews where chip.paneKey == terminal.paneKey {
            chip.setConnection(terminal.connectionState)
        }
    }

    private func rebuildTabs() {
        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for terminal in terminals {
            let chip = TerminalTabChip(
                title: terminal.project.name,
                path: terminal.project.path,
                state: terminal.connectionState
            )
            chip.paneKey = terminal.paneKey
            chip.isSelected = terminal === selected
            chip.onSelect = { [weak self] in self?.select(terminal) }
            chip.onClose = { [weak self] in self?.remove(terminal) }
            chip.translatesAutoresizingMaskIntoConstraints = false
            tabBar.addArrangedSubview(chip)
        }
        updateEmptyState()
    }

    private func updateEmptyState() {
        emptyState.isHidden = !terminals.isEmpty
        tabBar.isHidden = terminals.isEmpty
        container.isHidden = terminals.isEmpty
    }
}

/// One tab in the terminal tab bar: status dot, terminal glyph, project name
/// and a close button. Clicking selects; the × button dismisses.
final class TerminalTabChip: NSView {
    var paneKey = ""
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var isSelected = false {
        didSet { restyle() }
    }

    private let dot = NSView()
    private let closeButton: NSButton
    private let nameLabel: NSTextField

    init(title: String, path: String, state: TerminalConnectionState) {
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])

        let icon = NSImageView(image: NativeTheme.symbol("terminal.fill", size: 11, weight: .semibold) ?? NSImage())
        icon.contentTintColor = NativeTheme.secondaryText

        nameLabel = NSTextField(labelWithString: title)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton = NSButton()
        closeButton.isBordered = false
        closeButton.image = NativeTheme.symbol("xmark", size: 10, weight: .semibold)
        closeButton.contentTintColor = NativeTheme.secondaryText
        closeButton.toolTip = "收起终端（实例继续运行）"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        let content = NSStackView(views: [dot, icon, nameLabel, closeButton])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        toolTip = path
        addSubview(content)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        setConnection(state)
        restyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let buttonPoint = closeButton.convert(local, from: self)
        if closeButton.bounds.contains(buttonPoint) {
            return closeButton
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    func setConnection(_ state: TerminalConnectionState) {
        let color: NSColor
        switch state {
        case .connecting:
            color = NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.32, alpha: 1)
        case .connected:
            color = NSColor(calibratedRed: 0.20, green: 0.83, blue: 0.60, alpha: 1)
        case .error:
            color = NSColor(calibratedRed: 0.98, green: 0.44, blue: 0.52, alpha: 1)
        }
        dot.layer?.backgroundColor = color.cgColor
    }

    private func restyle() {
        layer?.backgroundColor = isSelected
            ? NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
            : NSColor(calibratedWhite: 0.10, alpha: 1).cgColor
        layer?.borderWidth = isSelected ? 1 : 0
        layer?.borderColor = NSColor(calibratedWhite: 0.30, alpha: 1).cgColor
        nameLabel.textColor = isSelected ? .white : NSColor(calibratedWhite: 0.70, alpha: 1)
    }

    @objc private func closeClicked() {
        onClose?()
    }
}
