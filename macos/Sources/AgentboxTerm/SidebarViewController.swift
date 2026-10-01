import AppKit

final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelectWorkspace: ((Workspace) -> Void)?
    var onSelectProject: ((RemoteProject) -> Void)?
    var onChooseLocalRoot: (() -> Void)?
    var onCreateProject: (() -> Void)?
    var onRenameProject: ((RemoteProject) -> Void)?
    var onChangeProjectLocalDir: ((RemoteProject) -> Void)?
    var onChangeProjectPolicy: ((RemoteProject, String?) -> Void)?
    var onOpenProject: ((RemoteProject) -> Void)?
    var onCopyProjectPath: ((RemoteProject) -> Void)?
    var onDeleteProject: ((RemoteProject) -> Void)?
    /// Current per-project sync policy, for the checkmark in the submenu.
    var projectPolicyForDisplay: ((RemoteProject) -> String?)?

    private let workspacePicker = NSPopUpButton()
    private let projectTable = NSTableView()
    private let projectScroll = NSScrollView()
    private let emptyState = NSStackView()
    private let projectCount = NSTextField(labelWithString: "0")
    private let localRoot = NSTextField(labelWithString: "尚未选择")
    private let chooseRootButton = FirstMouseButton(title: "选择目录", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "正在连接…")
    private var workspaces: [Workspace] = []
    private var projects: [RemoteProject] = []
    private let projectMenu = NSMenu()
    private var menuProject: RemoteProject?

    override func viewDidLoad() {
        super.viewDidLoad()
        projectMenu.delegate = self
        projectTable.menu = projectMenu
    }

    @objc private func openClicked() {
        guard let menuProject else { return }
        onOpenProject?(menuProject)
    }

    @objc private func copyPathClicked() {
        guard let menuProject else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(menuProject.path, forType: .string)
    }

    @objc private func renameClicked() {
        guard let menuProject else { return }
        onRenameProject?(menuProject)
    }

    @objc private func changeLocalDirClicked() {
        guard let menuProject else { return }
        onChangeProjectLocalDir?(menuProject)
    }

    @objc private func changePolicyClicked(_ sender: NSMenuItem) {
        guard let menuProject else { return }
        // The tag carries the policy; 0 is "follow the workspace".
        let policy = sender.tag == 0 ? nil : (sender.tag == 1 ? "server" : "local")
        onChangeProjectPolicy?(menuProject, policy)
    }

    @objc private func deleteClicked() {
        guard let menuProject else { return }
        onDeleteProject?(menuProject)
    }

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .sidebar
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState

        let brandIcon = NSImageView()
        brandIcon.image = NSApp.applicationIconImage ?? NativeTheme.symbol("shippingbox.fill", size: 26)
        brandIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        brandIcon.contentTintColor = NativeTheme.accent
        brandIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            brandIcon.widthAnchor.constraint(equalToConstant: 30),
            brandIcon.heightAnchor.constraint(equalToConstant: 30),
        ])

        let brandTitle = NSTextField(labelWithString: "agentbox-client")
        brandTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        brandTitle.textColor = NativeTheme.primaryText
        let brandSubtitle = NSTextField(labelWithString: "项目终端")
        brandSubtitle.font = .systemFont(ofSize: 11)
        brandSubtitle.textColor = NativeTheme.secondaryText
        let brandText = NSStackView(views: [brandTitle, brandSubtitle])
        brandText.orientation = .vertical
        brandText.spacing = 0
        brandText.alignment = .leading
        let brand = NSStackView(views: [brandIcon, brandText])
        brand.orientation = .horizontal
        brand.spacing = 10
        brand.alignment = .centerY

        let workspaceLabel = sectionLabel("实例")
        configureWorkspacePicker()

        let projectsTitle = sectionLabel("项目")
        projectCount.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        projectCount.textColor = NativeTheme.secondaryText
        projectCount.alignment = .center
        projectCount.wantsLayer = true
        projectCount.layer?.backgroundColor = NativeTheme.cardHover.cgColor
        projectCount.layer?.cornerRadius = 9
        projectCount.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            projectCount.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            projectCount.heightAnchor.constraint(equalToConstant: 18),
        ])
        let addButton = iconButton("plus", tip: "新建项目", action: #selector(createProject))
        let projectHeader = NSStackView(views: [projectsTitle, projectCount, NSView(), addButton])
        projectHeader.orientation = .horizontal
        projectHeader.alignment = .centerY
        projectHeader.spacing = 8

        configureProjectTable()
        configureEmptyState()
        let projectArea = NSView()
        projectArea.translatesAutoresizingMaskIntoConstraints = false
        projectArea.addSubview(projectScroll)
        projectArea.addSubview(emptyState)
        NSLayoutConstraint.activate([
            projectScroll.leadingAnchor.constraint(equalTo: projectArea.leadingAnchor),
            projectScroll.trailingAnchor.constraint(equalTo: projectArea.trailingAnchor),
            projectScroll.topAnchor.constraint(equalTo: projectArea.topAnchor),
            projectScroll.bottomAnchor.constraint(equalTo: projectArea.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: projectArea.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: projectArea.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: projectArea.leadingAnchor, constant: 18),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: projectArea.trailingAnchor, constant: -18),
        ])

        let syncPanel = makeSyncPanel()
        status.font = .systemFont(ofSize: 11)
        status.textColor = NativeTheme.secondaryText
        status.lineBreakMode = .byTruncatingTail
        status.maximumNumberOfLines = 2

        let stack = NSStackView(views: [
            brand,
            workspaceLabel,
            workspacePicker,
            projectHeader,
            projectArea,
            syncPanel,
            status,
        ])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(18, after: brand)
        stack.setCustomSpacing(7, after: workspaceLabel)
        stack.setCustomSpacing(14, after: workspacePicker)
        stack.setCustomSpacing(7, after: projectHeader)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            projectArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        view = root
    }

    func setWorkspaces(_ workspaces: [Workspace]) {
        self.workspaces = workspaces
        workspacePicker.removeAllItems()
        workspacePicker.addItems(withTitles: workspaces.map { "\($0.name) · \($0.toolsLabel)" })
        workspacePicker.isEnabled = !workspaces.isEmpty
        status.stringValue = workspaces.isEmpty ? "没有可用实例" : ""
        if !workspaces.isEmpty {
            workspacePicker.selectItem(at: 0)
            onSelectWorkspace?(workspaces[0])
        }
    }

    func setProjects(_ projects: [RemoteProject]) {
        self.projects = projects
        projectCount.stringValue = String(projects.count)
        projectTable.reloadData()
        projectScroll.isHidden = projects.isEmpty
        emptyState.isHidden = !projects.isEmpty
        status.stringValue = projects.isEmpty ? "" : "双击项目进入 Claude"
    }

    func setStatus(_ value: String) {
        status.stringValue = value
    }

    func setLocalRoot(_ path: String?) {
        localRoot.stringValue = path ?? "尚未选择"
        localRoot.toolTip = path
        chooseRootButton.title = path == nil ? "选择目录" : "修改目录"
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        projects.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        44
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ProjectCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ProjectCellView
            ?? ProjectCellView()
        cell.identifier = identifier
        cell.configure(projects[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = projectTable.selectedRow
        guard row >= 0, row < projects.count else { return }
        onSelectProject?(projects[row])
    }

    @objc private func workspaceChanged() {
        let index = workspacePicker.indexOfSelectedItem
        guard index >= 0, index < workspaces.count else { return }
        projectTable.deselectAll(nil)
        onSelectWorkspace?(workspaces[index])
    }

    @objc private func chooseLocalRoot() {
        onChooseLocalRoot?()
    }

    @objc private func createProject() {
        onCreateProject?()
    }

    private func configureWorkspacePicker() {
        workspacePicker.controlSize = .large
        workspacePicker.bezelStyle = .rounded
        workspacePicker.font = .systemFont(ofSize: 13, weight: .medium)
        workspacePicker.target = self
        workspacePicker.action = #selector(workspaceChanged)
        workspacePicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func configureProjectTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project"))
        column.resizingMask = .autoresizingMask
        projectTable.addTableColumn(column)
        projectTable.headerView = nil
        projectTable.style = .sourceList
        projectTable.rowHeight = 44
        projectTable.intercellSpacing = NSSize(width: 0, height: 2)
        projectTable.backgroundColor = .clear
        projectTable.dataSource = self
        projectTable.delegate = self
        projectTable.focusRingType = .none
        projectTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        projectScroll.documentView = projectTable
        projectScroll.drawsBackground = false
        projectScroll.hasVerticalScroller = true
        projectScroll.borderType = .noBorder
        projectScroll.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureEmptyState() {
        let icon = NSImageView()
        icon.image = NativeTheme.symbol("shippingbox", size: 28)
        icon.contentTintColor = NativeTheme.accent
        let title = NSTextField(labelWithString: "还没有项目")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = NativeTheme.primaryText
        let detail = NSTextField(labelWithString: "在服务器创建第一个项目，然后开始 Claude 会话。")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = NativeTheme.secondaryText
        detail.alignment = .center
        detail.maximumNumberOfLines = 2
        let button = textButton("创建第一个项目", symbol: "plus", action: #selector(createProject))
        emptyState.setViews([icon, title, detail, button], in: .top)
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        emptyState.translatesAutoresizingMaskIntoConstraints = false
    }

    private func makeSyncPanel() -> NSBox {
        let panel = NSBox()
        panel.boxType = .custom
        panel.cornerRadius = 12
        panel.borderWidth = 1
        panel.borderColor = NativeTheme.border
        panel.fillColor = NativeTheme.card
        panel.contentViewMargins = NSSize(width: 0, height: 0)

        let title = NSTextField(labelWithString: "本地同步")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = NativeTheme.secondaryText
        localRoot.font = .systemFont(ofSize: 12, weight: .medium)
        localRoot.textColor = NativeTheme.primaryText
        localRoot.lineBreakMode = .byTruncatingMiddle
        localRoot.isSelectable = true
        localRoot.toolTip = "双击选择或修改本地同步目录"
        chooseRootButton.target = self
        chooseRootButton.action = #selector(chooseLocalRoot)
        chooseRootButton.image = NativeTheme.symbol("folder", size: 12, weight: .semibold)
        chooseRootButton.imagePosition = .imageLeading
        chooseRootButton.bezelStyle = .rounded
        chooseRootButton.controlSize = .small
        chooseRootButton.font = .systemFont(ofSize: 12, weight: .medium)
        localRoot.target = self
        localRoot.action = #selector(chooseLocalRoot)
        let stack = NSStackView(views: [title, localRoot, chooseRootButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = stack
        return panel
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NativeTheme.secondaryText
        return label
    }

    private func iconButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let button = NSButton(image: NativeTheme.symbol(symbol, size: 12, weight: .semibold) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = NativeTheme.secondaryText
        button.toolTip = tip
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])
        return button
    }

    private func textButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NativeTheme.symbol(symbol, size: 12, weight: .semibold)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: .medium)
        return button
    }
}

/// 侧栏按钮在窗口未激活时也要响应第一次点击：否则 macOS 会吞掉这一击去激活窗口，
/// 用户只会看到「点了没反应」。
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class ProjectCellView: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.image = NativeTheme.symbol("shippingbox", size: 15, weight: .medium)
        icon.contentTintColor = NativeTheme.accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = NativeTheme.primaryText
        name.lineBreakMode = .byTruncatingTail
        path.font = .systemFont(ofSize: 10.5)
        path.textColor = NativeTheme.secondaryText
        path.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView(views: [name, path])
        labels.orientation = .vertical
        labels.spacing = 0
        labels.alignment = .leading
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(labels)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ project: RemoteProject) {
        name.stringValue = project.name
        path.stringValue = project.path
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = projectTable.clickedRow
        guard row >= 0, row < projects.count else { return }
        populate(menu, with: projects[row])
    }

    /// Builds the right-click menu for one project. Kept separate from
    /// menuNeedsUpdate, which can only run under a real click, so the
    /// contents and the actions stay reachable from the smoke checks.
    func populate(_ menu: NSMenu, with project: RemoteProject) {
        menu.removeAllItems()
        menuProject = project

        func item(_ title: String, _ symbol: String, _ action: Selector, red: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NativeTheme.symbol(symbol, size: 13, weight: .medium)
            if red {
                item.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.foregroundColor: NSColor.systemRed]
                )
            }
            return item
        }

        menu.addItem(item("打开终端", "play", #selector(openClicked)))
        menu.addItem(item("复制路径", "doc.on.doc", #selector(copyPathClicked)))
        menu.addItem(.separator())
        menu.addItem(item("修改项目名称…", "pencil", #selector(renameClicked)))
        menu.addItem(item("修改本地工作空间…", "folder", #selector(changeLocalDirClicked)))
        menu.addItem(policyItem(for: project))
        menu.addItem(.separator())
        menu.addItem(item("删除…", "trash", #selector(deleteClicked), red: true))
    }

    /// "修改同步方式" as a submenu, with the project's current choice checked.
    private func policyItem(for project: RemoteProject) -> NSMenuItem {
        let current = projectPolicyForDisplay?(project) ?? nil
        let parent = NSMenuItem(title: "修改同步方式", action: nil, keyEquivalent: "")
        parent.image = NativeTheme.symbol("arrow.triangle.2.circlepath", size: 13, weight: .medium)
        let submenu = NSMenu()
        let options: [(String, Int, String?)] = [
            ("跟随工作空间", 0, nil),
            ("以服务器为准", 1, "server"),
            ("以本地为准", 2, "local"),
        ]
        for (title, tag, policy) in options {
            let entry = NSMenuItem(title: title, action: #selector(changePolicyClicked(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = tag
            entry.state = current == policy ? .on : .off
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }
}
