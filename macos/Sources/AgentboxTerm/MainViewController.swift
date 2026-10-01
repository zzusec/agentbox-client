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
    private let toolbarSettings = NSToolbarItem.Identifier("agentbox-client.terminal-settings")
    private let statusBar = NSView()
    private let syncSpinner = NSProgressIndicator()
    /// A determinate bar shown once the engine reports "done/total", so a big
    /// download or upload reads as a real percentage instead of an endless
    /// spinner.
    private let syncBar = NSProgressIndicator()
    private let syncStatusLabel = NSTextField(labelWithString: "")
    /// What the bottom bar currently says, and whether a sync is in flight.
    private(set) var syncStatusText = ""
    private(set) var isSyncing = false
    /// 0...1 when the engine is reporting counts, nil when it is not.
    private(set) var syncFraction: Double?

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
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let bar = buildStatusBar()
        root.addSubview(splitView)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 26),
        ])
        view = root
    }

    /// The always-visible strip along the bottom of the window. Sync used to
    /// report only into the sidebar's status line, which is easy to miss — a
    /// forced overwrite of a big tree looked like nothing was happening.
    private func buildStatusBar() -> NSView {
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NativeTheme.card.cgColor

        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NativeTheme.border.cgColor

        syncSpinner.style = .spinning
        syncSpinner.controlSize = .small
        syncSpinner.isDisplayedWhenStopped = false
        syncSpinner.isHidden = true
        syncSpinner.translatesAutoresizingMaskIntoConstraints = false

        // Shown once counts arrive; the spinner is only for the window before
        // that, when the engine knows it is busy but not yet how much work.
        syncBar.style = .bar
        syncBar.controlSize = .small
        syncBar.minValue = 0
        syncBar.maxValue = 100
        syncBar.isIndeterminate = false
        syncBar.isHidden = true
        syncBar.translatesAutoresizingMaskIntoConstraints = false

        syncStatusLabel.font = .systemFont(ofSize: 11)
        syncStatusLabel.textColor = NativeTheme.secondaryText
        syncStatusLabel.lineBreakMode = .byTruncatingMiddle
        syncStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [syncSpinner, syncBar, syncStatusLabel])
        content.orientation = .horizontal
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false

        statusBar.addSubview(separator)
        statusBar.addSubview(content)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: statusBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            content.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(lessThanOrEqualTo: statusBar.trailingAnchor, constant: -12),
            content.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            syncSpinner.widthAnchor.constraint(equalToConstant: 14),
            syncSpinner.heightAnchor.constraint(equalToConstant: 14),
            syncBar.widthAnchor.constraint(equalToConstant: 130),
        ])
        return statusBar
    }

    /// Shows a sync line in the bottom bar.
    ///
    /// - progress: 0...1 once the engine is counting, which swaps the spinner
    ///   for a determinate bar so a download or upload reads as a real
    ///   percentage. Nil means "busy but not counting yet"; busy=false is the
    ///   finished state, where neither indicator stays up.
    func showSyncStatus(_ message: String, busy: Bool = false, progress: Double? = nil) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        syncStatusLabel.stringValue = text
        syncStatusLabel.toolTip = text.isEmpty ? nil : "\(text)\n日志：\(SyncManager.logURL.path)"
        syncStatusText = text
        isSyncing = busy
        syncFraction = progress

        if let progress {
            syncSpinner.stopAnimation(nil)
            syncSpinner.isHidden = true
            syncBar.isHidden = false
            syncBar.doubleValue = progress * 100
        } else if busy {
            syncBar.isHidden = true
            syncSpinner.isHidden = false
            syncSpinner.startAnimation(nil)
        } else {
            syncSpinner.stopAnimation(nil)
            syncSpinner.isHidden = true
            syncBar.isHidden = true
        }
    }

    /// Routes a line of engine output to the bottom bar. A "done/total" pair is
    /// progress and drives the bar; anything else is the verdict and ends it.
    func handleSyncOutput(_ message: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Progress lines look like "项目: 45/820 (5%)".
        if let counts = parseSyncCounts(text), counts.total > 0 {
            showSyncStatus(text, busy: true, progress: Double(counts.done) / Double(counts.total))
            return
        }

        // A verdict line: mark the finish so it is unmistakable next to the
        // moving bar it replaces.
        let settled = text.contains("同步完成") || text.contains("无需同步") || text.contains("已是最新")
        showSyncStatus(settled ? "✓ \(text)" : text, busy: false)
    }

    /// Pulls "done/total" out of an engine progress line.
    private func parseSyncCounts(_ text: String) -> (done: Int, total: Int)? {
        let pattern = #": (\d+)/(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let doneRange = Range(match.range(at: 1), in: text),
              let totalRange = Range(match.range(at: 2), in: text),
              let done = Int(text[doneRange]),
              let total = Int(text[totalRange])
        else { return nil }
        return (done, total)
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
        terminalGrid.onPaneClosed = { [weak self] terminal in
            self?.terminals.removeValue(forKey: terminal.paneKey)
        }
        sidebar.onRenameProject = { [weak self] project in
            self?.renameProject(project)
        }
        sidebar.onChangeProjectLocalDir = { [weak self] project in
            self?.changeProjectLocalDir(project)
        }
        sidebar.onChangeProjectPolicy = { [weak self] project, policy in
            self?.changeProjectPolicy(project, policy: policy)
        }
        sidebar.onSyncProjectNow = { [weak self] project, policy in
            self?.syncProjectNow(project, policy: policy)
        }
        sidebar.onOpenSyncLog = {
            NSWorkspace.shared.activateFileViewerSelecting([SyncManager.logURL])
        }
        sidebar.projectPolicyForDisplay = { [weak self] project in
            guard let self, let workspace = self.workspace else { return nil }
            return self.projectSettings(for: workspace)[project.id]?.policy
        }
        sidebar.onOpenProject = { [weak self] project in
            self?.open(project)
        }
        sidebar.onCopyProjectPath = { project in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.path, forType: .string)
        }
        sidebar.onDeleteProject = { [weak self] project in
            self?.deleteProject(project)
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
        sidebar.setWorkspaceID(workspace.id)
        let root = UserDefaults.standard.string(forKey: localRootKey(workspace))
        sidebar.setLocalRoot(root)
        if let root {
            startSync(workspace, localRoot: URL(fileURLWithPath: root, isDirectory: true))
        } else {
            showSyncStatus("未配置本地同步目录：点侧栏「选择目录」后开始同步")
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
            terminalGrid.select(existing)
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
            sidebar.setStatus("请先选择实例")
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
        let sheet = NewProjectViewController()
        sheet.localRoot = UserDefaults.standard.string(forKey: localRootKey(workspace))
        sheet.onCreate = { [weak self] draft in
            guard let self else { return }
            Task { @MainActor in
                do {
                    let created = try await self.client.createProject(name: draft.name, in: workspace)
                    if draft.localDir != nil || draft.policy != nil {
                        self.updateProjectSetting(for: workspace, project: created) { setting in
                            setting.localDir = draft.localDir
                            setting.policy = draft.policy
                        }
                    }
                    self.sidebar.setProjects(try await self.client.projects(in: workspace))
                    // A new project has no baseline, so the chosen policy is
                    // what decides the very first sync.
                    if draft.localDir != nil || draft.policy != nil {
                        self.restartSync(workspace)
                    }
                } catch {
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "创建项目失败"
                    errorAlert.informativeText = error.localizedDescription
                    errorAlert.alertStyle = .warning
                    errorAlert.runModal()
                }
            }
        }
        presentAsSheet(sheet)
    }

    /// Right-click rename: stop the sync engine, move the local folder, rename
    /// on the server (which renames the server-side directory), ask which side
    /// wins for the next bootstrap, then restart syncing.
    private func renameProject(_ project: RemoteProject) {
        guard let workspace, workspace.id == self.workspace?.id else { return }
        let alert = NSAlert()
        alert.messageText = "重命名项目"
        alert.informativeText = "服务器目录和本地文件夹会一起改名。"
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = project.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != project.name else { return }
        guard !newName.contains("/"), !newName.hasPrefix(".") else {
            sidebar.setStatus("项目名称无效")
            return
        }

        Task { @MainActor in
            var localRootURL: URL?
            if let root = UserDefaults.standard.string(forKey: localRootKey(workspace)), !root.isEmpty {
                localRootURL = URL(fileURLWithPath: root, isDirectory: true)
            }
            // Sync off while both sides move: a live engine would otherwise see
            // the old project vanish and the new one appear mid-rename.
            syncManager?.stop()
            syncManager = nil
            defer { sidebar.setStatus("双击项目进入 Claude") }

            // Local folder first; roll it back if the server rejects the name.
            // A project with its own local directory keeps it — only the
            // classic <local root>/<name> layout has a folder to rename.
            var movedLocal = false
            if let localRootURL, projectSettings(for: workspace)[project.id]?.localDir?.isEmpty != false {
                let oldURL = localRootURL.appendingPathComponent(project.name)
                let newURL = localRootURL.appendingPathComponent(newName)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: oldURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    if FileManager.default.fileExists(atPath: newURL.path) {
                        let conflict = NSAlert()
                        conflict.messageText = "本地已存在同名文件夹"
                        conflict.informativeText = newURL.path
                        conflict.alertStyle = .warning
                        conflict.runModal()
                        startSyncIfConfigured(workspace, localRoot: localRootURL)
                        return
                    }
                    do {
                        try FileManager.default.moveItem(at: oldURL, to: newURL)
                        movedLocal = true
                    } catch {
                        let failure = NSAlert()
                        failure.messageText = "本地文件夹改名失败"
                        failure.informativeText = error.localizedDescription
                        failure.alertStyle = .warning
                        failure.runModal()
                        startSyncIfConfigured(workspace, localRoot: localRootURL)
                        return
                    }
                }
            }

            do {
                _ = try await client.renameProject(project, to: newName, in: workspace)
            } catch {
                if movedLocal, let localRootURL {
                    let oldURL = localRootURL.appendingPathComponent(project.name)
                    let newURL = localRootURL.appendingPathComponent(newName)
                    try? FileManager.default.moveItem(at: newURL, to: oldURL)
                }
                let failure = NSAlert()
                failure.messageText = "服务器改名失败"
                failure.informativeText = error.localizedDescription
                failure.alertStyle = .warning
                failure.runModal()
                startSyncIfConfigured(workspace, localRoot: localRootURL)
                return
            }

            // The rename orphans any open terminal for the old name; dismiss it
            // to the background so reopening uses the new name.
            let oldKey = "\(workspace.id)/\(project.name)"
            if let stale = terminals.removeValue(forKey: oldKey) {
                terminalGrid.remove(stale)
            }

            if localRootURL != nil {
                let policy = askRenamePolicy()
                if let policy {
                    UserDefaults.standard.set(policy, forKey: initialPolicyKey(workspace))
                }
                startSyncIfConfigured(workspace, localRoot: localRootURL)
            }
            do {
                sidebar.setProjects(try await client.projects(in: workspace))
            } catch {
                sidebar.setStatus("读取项目失败：\(error.localizedDescription)")
            }
        }
    }

    private func startSyncIfConfigured(_ workspace: Workspace, localRoot: URL?) {
        guard let localRoot else { return }
        startSync(workspace, localRoot: localRoot)
    }

    /// Right-click delete: stops syncing, deletes on the server (which trashes
    /// the server-side directory), moves the local folder to the macOS Trash
    /// and closes the project's terminal tab.
    private func deleteProject(_ project: RemoteProject) {
        guard let workspace, workspace.id == self.workspace?.id else { return }
        let alert = NSAlert()
        alert.messageText = "删除项目 \(project.name)？"
        alert.informativeText = "服务器目录会移入回收站；本地同步目录会移到废纸篓"
            + (effectiveProjectDir(project, in: workspace).map { "（\($0)）" } ?? "")
            + "；相关终端标签会关闭。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor in
            var localRootURL: URL?
            if let root = UserDefaults.standard.string(forKey: localRootKey(workspace)), !root.isEmpty {
                localRootURL = URL(fileURLWithPath: root, isDirectory: true)
            }
            syncManager?.stop()
            syncManager = nil
            defer { sidebar.setStatus("双击项目进入 Claude") }

            do {
                try await client.deleteProject(project, in: workspace)
            } catch {
                let failure = NSAlert()
                failure.messageText = "服务器删除失败"
                failure.informativeText = error.localizedDescription
                failure.alertStyle = .warning
                failure.runModal()
                startSyncIfConfigured(workspace, localRoot: localRootURL)
                return
            }

            let key = "\(workspace.id)/\(project.name)"
            if let stale = terminals.removeValue(forKey: key) {
                terminalGrid.remove(stale)
            }
            updateProjectSetting(for: workspace, project: project) { setting in
                setting = ProjectSyncSetting()
            }
            if let folder = effectiveProjectDir(project, in: workspace) {
                let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    do {
                        try FileManager.default.trashItem(at: folderURL, resultingItemURL: nil)
                    } catch {
                        sidebar.setStatus("本地文件夹移入废纸篓失败：\(error.localizedDescription)")
                    }
                }
            }
            startSyncIfConfigured(workspace, localRoot: localRootURL)
            do {
                sidebar.setProjects(try await client.projects(in: workspace))
            } catch {
                sidebar.setStatus("读取项目失败：\(error.localizedDescription)")
            }
        }
    }

    private func askRenamePolicy() -> String? {
        let alert = NSAlert()
        alert.messageText = "重命名完成：以哪边代码为准？"
        alert.informativeText = "同步内容有分歧时，所选一侧将覆盖另一侧；内容一致则无事发生。"
        alert.addButton(withTitle: ProjectSyncSetting.policyLabel("server"))
        alert.addButton(withTitle: ProjectSyncSetting.policyLabel("local"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return "server"
        case .alertSecondButtonReturn:
            return "local"
        default:
            return nil
        }
    }

    private func startSync(_ workspace: Workspace, localRoot: URL) {
        syncManager?.stop()
        let policy = UserDefaults.standard.string(forKey: initialPolicyKey(workspace)) ?? ""
        let manager = SyncManager(
            client: client,
            workspace: workspace,
            localRoot: localRoot,
            initialPolicy: policy,
            projectSettings: projectSettings(for: workspace)
        )
        manager.onStatus = { [weak self] message in
            self?.handleSyncOutput(message)
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

    // MARK: Per-project sync settings

    private func projectSettings(for workspace: Workspace) -> [String: ProjectSyncSetting] {
        ProjectSyncStore.settings(for: workspace.id)
    }

    private func updateProjectSetting(
        for workspace: Workspace,
        project: RemoteProject,
        _ change: (inout ProjectSyncSetting) -> Void
    ) {
        ProjectSyncStore.update(workspace.id, projectID: project.id, change)
    }

    /// The classic location for a project, i.e. the path the sync engine uses
    /// when no override is stored.
    private func classicProjectDir(_ project: RemoteProject, in workspace: Workspace) -> String? {
        guard let root = UserDefaults.standard.string(forKey: localRootKey(workspace)), !root.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(project.name)
            .standardizedFileURL.path
    }

    /// The directory a project syncs to right now, override or classic.
    private func effectiveProjectDir(_ project: RemoteProject, in workspace: Workspace) -> String? {
        if let dir = projectSettings(for: workspace)[project.id]?.localDir, !dir.isEmpty {
            return dir
        }
        return classicProjectDir(project, in: workspace)
    }

    private func restartSync(_ workspace: Workspace) {
        guard let root = UserDefaults.standard.string(forKey: localRootKey(workspace)), !root.isEmpty else {
            return
        }
        startSync(workspace, localRoot: URL(fileURLWithPath: root, isDirectory: true))
    }

    /// Right-click "修改本地工作空间…": point one project at its own local
    /// directory. The engine stores its baseline under the workspace root and
    /// records which directory that baseline describes, so the new directory
    /// starts from a fresh baseline instead of the old one reading as "every
    /// file was deleted locally" and wiping the server copy.
    private func changeProjectLocalDir(_ project: RemoteProject) {
        guard let workspace, workspace.id == self.workspace?.id else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "使用此目录"
        panel.message = "选择「\(project.name)」在本机的同步目录"
        if let current = effectiveProjectDir(project, in: workspace) {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.applyProjectLocalDir(url, for: project, in: workspace)
        }
        guard let window = view.window else {
            handler(panel.runModal())
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        panel.beginSheetModal(for: window, completionHandler: handler)
    }

    private func applyProjectLocalDir(_ url: URL, for project: RemoteProject, in workspace: Workspace) {
        let chosen = url.standardizedFileURL.path
        let wasCustom = projectSettings(for: workspace)[project.id]?.localDir?.isEmpty == false
        // Picking the classic location again is the same as having no override.
        let clearsOverride = chosen == classicProjectDir(project, in: workspace)
        updateProjectSetting(for: workspace, project: project) { setting in
            setting.localDir = clearsOverride ? nil : chosen
        }
        restartSync(workspace)
        if clearsOverride && wasCustom {
            sidebar.setStatus("\(project.name) 已改回工作空间目录：\(chosen)")
        } else {
            sidebar.setStatus("\(project.name) 同步目录已改为：\(chosen)")
        }
    }

    /// Right-click "修改同步方式". The choice decides which side wins when the
    /// project has to build a fresh baseline (a new project, a new local
    /// directory, or a baseline that no longer matches the directory); routine
    /// syncs keep three-way merging and pause on real conflicts.
    private func changeProjectPolicy(_ project: RemoteProject, policy: String?) {
        guard let workspace, workspace.id == self.workspace?.id else { return }
        updateProjectSetting(for: workspace, project: project) { setting in
            setting.policy = policy
        }
        restartSync(workspace)
        sidebar.setStatus("\(project.name) 同步方式：\(ProjectSyncSetting.policyLabel(policy))")
    }

    /// The ⟳ next to a sync mode: overwrite the other side right now.
    ///
    /// This is the only way to make the choice act immediately — the stored
    /// policy otherwise only applies when a project next builds a baseline.
    /// It is destructive by design, so it confirms first, and it also stores
    /// the policy the user picked.
    private func syncProjectNow(_ project: RemoteProject, policy: String) {
        guard let workspace, workspace.id == self.workspace?.id else { return }
        // Sync cannot run without a local directory. Asking for one here beats
        // the old behaviour, which wrote a line into the sidebar and returned —
        // the button looked broken.
        guard let root = requireLocalRoot(for: workspace, policy: policy) else { return }
        let label = ProjectSyncSetting.policyLabel(policy)
        // An empty local directory can only mean "download": the engine forces
        // the server side when there is nothing local to win with. The opposite
        // — an unrelated non-empty folder — would overwrite the server project
        // and delete everything it does not have, so say which one this is.
        let localDir = effectiveProjectDir(project, in: workspace)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let localIsEmpty = (localDir.flatMap {
            try? FileManager.default.contentsOfDirectory(atPath: $0.path)
        } ?? []).isEmpty
        let overwrite: String
        if localIsEmpty {
            overwrite = "本地目录还是空的，这次只会把服务器上的文件下载下来，不会删任何东西。"
        } else if policy == "server" {
            overwrite = "服务器上没有的本地文件会被删除，服务器上的文件会全部下载下来。"
        } else {
            overwrite = "本地文件会全部上传，服务器上多出的文件会被删除。"
        }
        let alert = NSAlert()
        alert.messageText = "立即以\(policy == "server" ? "服务器" : "本地")为准全量同步「\(project.name)」？"
        alert.informativeText = overwrite
            + "\n\n这会跳过三路合并，直接按所选一侧覆盖另一侧；"
            + "同时把该项目的同步方式记为「\(label)」。"
        alert.addButton(withTitle: "立即同步")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = localIsEmpty ? .informational : .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        updateProjectSetting(for: workspace, project: project) { setting in
            setting.policy = policy
        }
        let manager = SyncManager(
            client: client,
            workspace: workspace,
            localRoot: root,
            initialPolicy: UserDefaults.standard.string(forKey: initialPolicyKey(workspace)) ?? "",
            projectSettings: projectSettings(for: workspace)
        )
        manager.onStatus = { [weak self] message in
            self?.handleSyncOutput(message)
        }
        syncManager?.stop()
        syncManager = manager
        showSyncStatus("正在以\(label)全量同步「\(project.name)」…", busy: true)
        manager.runForcedPass(project: project.name, policy: policy) { [weak self] result in
            guard let self else { return }
            // Through the same router, so a finished line gets its ✓.
            self.handleSyncOutput("\(project.name)：\(result)")
            // Resume the watcher, unless the user moved to another workspace.
            guard self.workspace?.id == workspace.id, self.syncManager === manager else { return }
            manager.start()
        }
    }

    /// The workspace's local sync directory, asking for one when it is missing
    /// (and recording the direction the caller just picked as the workspace
    /// default, so the watcher that resumes afterwards is well defined).
    private func requireLocalRoot(for workspace: Workspace, policy: String?) -> URL? {
        if let path = UserDefaults.standard.string(forKey: localRootKey(workspace)), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let alert = NSAlert()
        alert.messageText = "还没有选择本地同步目录"
        alert.informativeText = "同步需要先指定一个本机目录来存放项目文件；选好之后就会立刻开始。"
        alert.addButton(withTitle: "选择目录…")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let url = runDirectoryPanel(startingAt: nil, message: "选择本地同步目录") else { return nil }
        UserDefaults.standard.set(url.path, forKey: localRootKey(workspace))
        if let policy,
           (UserDefaults.standard.string(forKey: initialPolicyKey(workspace)) ?? "").isEmpty {
            UserDefaults.standard.set(policy, forKey: initialPolicyKey(workspace))
        }
        sidebar.setLocalRoot(url.path)
        return url
    }

    private func runDirectoryPanel(startingAt: URL?, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = message
        if let startingAt {
            panel.directoryURL = startingAt
        }
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseInitialPolicy(_ workspace: Workspace) -> String? {
        let alert = NSAlert()
        alert.messageText = "首次同步以哪边为准？"
        alert.informativeText = "只有本地目录和服务器项目同时有内容且没有同步基线时才使用这项选择。"
        alert.addButton(withTitle: ProjectSyncSetting.policyLabel("local"))
        alert.addButton(withTitle: ProjectSyncSetting.policyLabel("server"))
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
        [toolbarSidebar, .flexibleSpace, toolbarSettings]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [toolbarSidebar, .flexibleSpace, toolbarSettings]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == toolbarSidebar {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "项目栏"
            item.paletteLabel = "显示或隐藏项目栏"
            item.toolTip = "显示或隐藏项目栏"
            item.image = NativeTheme.symbol("sidebar.left", size: 15, weight: .medium)
            item.target = self
            item.action = #selector(toggleSidebar(_:))
            return item
        }
        guard itemIdentifier == toolbarSettings else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "终端设置"
        item.paletteLabel = "终端设置"
        item.toolTip = "终端配色与字号"
        item.image = NativeTheme.symbol("paintpalette", size: 15, weight: .medium)
        item.target = self
        item.action = #selector(openTerminalSettings)
        return item
    }

    @objc private func openTerminalSettings() {
        presentAsSheet(TerminalSettingsViewController())
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
