import AppKit

final class MainViewController: NSViewController, NSToolbarDelegate, NSSplitViewDelegate {
    private let client: AgentboxClient
    private let sidebar = SidebarViewController()
    private let terminalGrid = TerminalGridViewController()
    private let splitView = NSSplitView()
    private var workspaces: [Workspace] = []
    private var workspace: Workspace?
    private var selectionGeneration = 0
    private var terminals: [String: TerminalViewController] = [:]
    private var syncManager: SyncManager?
    private var sidebarCollapsed = false
    private var sidebarWidth: CGFloat = 270
    private let toolbarSidebar = NSToolbarItem.Identifier("agentbox-client.sidebar")

    init(client: AgentboxClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NativeTheme.content.cgColor
        root.autoresizesSubviews = true

        addChild(sidebar)
        addChild(terminalGrid)
        let sidebarView = sidebar.view
        let terminalView = terminalGrid.view

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(sidebarView)
        splitView.addArrangedSubview(terminalView)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.frame = root.bounds
        splitView.autoresizingMask = [.width, .height]
        root.addSubview(splitView)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        sidebar.onSelectWorkspace = { [weak self] workspace in
            self?.select(workspace)
        }
        sidebar.onSelectProject = { [weak self] project in
            self?.open(project)
        }
        sidebar.onChooseLocalRoot = { [weak self] in
            self?.chooseLocalRoot()
        }
        sidebar.onCreateProject = { [weak self] in
            self?.createProject()
        }

        Task { @MainActor in
            do {
                workspaces = try await client.workspaces()
                sidebar.setWorkspaces(workspaces)
            } catch {
                sidebar.setStatus("加载空间失败：\(error.localizedDescription)")
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !sidebarCollapsed, splitView.bounds.width > 0 else { return }

        let maximumSidebarWidth = min(340, max(250, splitView.bounds.width - 420))
        let targetWidth = min(max(sidebarWidth, 250), maximumSidebarWidth)
        if abs(sidebar.view.frame.width - targetWidth) > 0.5 {
            splitView.setPosition(targetWidth, ofDividerAt: 0)
        }
    }

    func installToolbar(in window: NSWindow) {
        guard window.toolbar == nil else { return }
        let toolbar = NSToolbar(identifier: "agentbox-client.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
    }

    private func select(_ workspace: Workspace) {
        selectionGeneration += 1
        let generation = selectionGeneration
        self.workspace = workspace
        syncManager?.stop()
        syncManager = nil
        let root = UserDefaults.standard.string(forKey: localRootKey(workspace))
        sidebar.setLocalRoot(root)
        if let root {
            startSync(workspace, localRoot: URL(fileURLWithPath: root, isDirectory: true))
        }
        sidebar.setProjects([])
        sidebar.setStatus("正在读取项目…")
        Task { @MainActor in
            do {
                let projects = try await client.projects(in: workspace)
                guard selectionGeneration == generation else { return }
                sidebar.setProjects(projects)
            } catch {
                guard selectionGeneration == generation else { return }
                sidebar.setProjects([])
                sidebar.setStatus("读取项目失败：\(error.localizedDescription)")
            }
        }
    }

    private func open(_ project: RemoteProject) {
        guard let workspace else { return }
        let key = "\(workspace.id)/\(project.name)"
        if let existing = terminals[key] {
            view.window?.makeFirstResponder(existing.view)
            return
        }
        let terminal = terminalGrid.add(client: client, workspace: workspace, project: project)
        terminals[key] = terminal
    }

    private func chooseLocalRoot() {
        if workspace == nil, let first = workspaces.first {
            select(first)
        }
        guard let workspace else {
            sidebar.setStatus("请先选择工作空间")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择或修改 \(workspace.name) 的本地项目根目录"
        if let current = UserDefaults.standard.string(forKey: localRootKey(workspace)) {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        guard let window = view.window else {
            if panel.runModal() == .OK, let url = panel.url {
                applyLocalRoot(url, for: workspace)
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.applyLocalRoot(url, for: workspace)
        }
    }

    private func applyLocalRoot(_ url: URL, for workspace: Workspace) {
        syncManager?.stop()
        syncManager = nil
        UserDefaults.standard.set(url.path, forKey: localRootKey(workspace))
        sidebar.setLocalRoot(url.path)
        let savedPolicy = UserDefaults.standard.string(forKey: initialPolicyKey(workspace))
        if let policy = savedPolicy ?? chooseInitialPolicy(workspace) {
            UserDefaults.standard.set(policy, forKey: initialPolicyKey(workspace))
            startSync(workspace, localRoot: url)
        } else {
            sidebar.setStatus("已修改同步目录，等待选择同步方式")
        }
    }

    private func createProject() {
        guard let workspace else { return }
        let alert = NSAlert()
        alert.messageText = "新建项目"
        alert.informativeText = "项目会在服务器 /workspace 下创建，并同步到本地同步目录。"
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "项目名称"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task { @MainActor in
            do {
                _ = try await client.createProject(name: name, in: workspace)
                sidebar.setProjects(try await client.projects(in: workspace))
            } catch {
                let errorAlert = NSAlert()
                errorAlert.messageText = "创建项目失败"
                errorAlert.informativeText = error.localizedDescription
                errorAlert.alertStyle = .warning
                errorAlert.runModal()
            }
        }
    }

    private func startSync(_ workspace: Workspace, localRoot: URL) {
        syncManager?.stop()
        let policy = UserDefaults.standard.string(forKey: initialPolicyKey(workspace)) ?? ""
        let manager = SyncManager(
            client: client,
            workspace: workspace,
            localRoot: localRoot,
            initialPolicy: policy
        )
        manager.onStatus = { [weak self] message in
            self?.sidebar.setStatus(message)
        }
        syncManager = manager
        manager.start()
    }

    private func localRootKey(_ workspace: Workspace) -> String {
        "agentbox.local-root.\(workspace.id)"
    }

    private func initialPolicyKey(_ workspace: Workspace) -> String {
        "agentbox.initial-policy.\(workspace.id)"
    }

    private func chooseInitialPolicy(_ workspace: Workspace) -> String? {
        let alert = NSAlert()
        alert.messageText = "首次同步以哪边为准？"
        alert.informativeText = "只有本地目录和服务器项目同时有内容且没有同步基线时才使用这项选择。"
        alert.addButton(withTitle: "以本地为准")
        alert.addButton(withTitle: "以服务器为准")
        alert.addButton(withTitle: "稍后决定")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return "local"
        case .alertSecondButtonReturn:
            return "server"
        default:
            return nil
        }
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        guard !sidebarCollapsed else {
            sidebarCollapsed = false
            sidebar.view.isHidden = false
            splitView.adjustSubviews()
            splitView.setPosition(max(250, sidebarWidth), ofDividerAt: 0)
            return
        }

        sidebarWidth = max(250, sidebar.view.frame.width)
        sidebarCollapsed = true
        sidebar.view.isHidden = true
        splitView.adjustSubviews()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [toolbarSidebar, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [toolbarSidebar, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == toolbarSidebar else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "项目栏"
        item.paletteLabel = "显示或隐藏项目栏"
        item.toolTip = "显示或隐藏项目栏"
        item.image = NativeTheme.symbol("sidebar.left", size: 15, weight: .medium)
        item.target = self
        item.action = #selector(toggleSidebar(_:))
        return item
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(proposedMinimumPosition, 250)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(proposedMaximumPosition, 340)
    }

    func splitView(
        _ splitView: NSSplitView,
        canCollapseSubview subview: NSView
    ) -> Bool {
        subview === sidebar.view
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !sidebarCollapsed else { return }
        let width = sidebar.view.frame.width
        if width >= 249.5, width <= 340.5 {
            sidebarWidth = width
        }
    }
}
