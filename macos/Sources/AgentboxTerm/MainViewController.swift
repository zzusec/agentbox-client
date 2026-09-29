import AppKit

final class MainViewController: NSSplitViewController {
    private let client: AgentboxClient
    private let sidebar = SidebarViewController()
    private let tabs = NSTabViewController()
    private var workspaces: [Workspace] = []
    private var workspace: Workspace?
    private var terminals: [String: TerminalViewController] = [:]
    private var syncManager: SyncManager?

    init(client: AgentboxClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true

        tabs.tabStyle = .toolbar
        let terminalItem = NSSplitViewItem(viewController: tabs)
        terminalItem.minimumThickness = 520
        addSplitViewItem(sidebarItem)
        addSplitViewItem(terminalItem)

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

    private func select(_ workspace: Workspace) {
        self.workspace = workspace
        syncManager?.stop()
        syncManager = nil
        let root = UserDefaults.standard.string(forKey: localRootKey(workspace))
        sidebar.setLocalRoot(root)
        if let root {
            startSync(workspace, localRoot: URL(fileURLWithPath: root, isDirectory: true))
        }
        sidebar.setStatus("正在读取项目…")
        Task { @MainActor in
            do {
                sidebar.setProjects(try await client.projects(in: workspace))
            } catch {
                sidebar.setProjects([])
                sidebar.setStatus("读取项目失败：\(error.localizedDescription)")
            }
        }
    }

    private func open(_ project: RemoteProject) {
        guard let workspace else { return }
        let key = "\(workspace.id)/\(project.name)"
        if let existing = terminals[key] {
            tabs.selectedTabViewItemIndex = tabs.tabViewItems.firstIndex {
                $0.viewController === existing
            } ?? 0
            return
        }
        let terminal = TerminalViewController(
            client: client,
            workspace: workspace,
            project: project
        )
        let item = NSTabViewItem(viewController: terminal)
        item.label = project.name
        item.identifier = key
        tabs.addTabViewItem(item)
        tabs.selectedTabViewItemIndex = tabs.tabViewItems.count - 1
        terminals[key] = terminal
    }

    private func chooseLocalRoot() {
        guard let workspace else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择 \(workspace.name) 的本地项目根目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: localRootKey(workspace))
        sidebar.setLocalRoot(url.path)
        if let policy = chooseInitialPolicy(workspace) {
            UserDefaults.standard.set(policy, forKey: initialPolicyKey(workspace))
            startSync(workspace, localRoot: url)
        } else {
            syncManager?.stop()
            syncManager = nil
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
}
