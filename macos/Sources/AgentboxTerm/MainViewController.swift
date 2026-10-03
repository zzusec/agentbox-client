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
    /// Stops a transfer in flight, or starts the whole pass again.
    private let syncControl = NSButton(title: "重新同步", target: nil, action: nil)
    /// What the bottom bar currently says, and whether a sync is in flight.
    private(set) var syncStatusText = ""
    private(set) var isSyncing = false
    /// 0...1 when the engine is reporting counts, nil when it is not.
    private(set) var syncFraction: Double?

    /// One line, from one job.
    struct StatusLine {
        var text = ""
        var busy = false
        var progress: Double?
    }

    /// The bar carries two independent jobs: the project's sync engine, and
    /// whatever a terminal tab is uploading. They are kept apart because a drop
    /// in one tab used to take the line over and then clear it — the running
    /// project sync looked like it had stopped. An upload is shown on top for
    /// its own duration and then hands the bar back to the engine.
    private var engineStatus = StatusLine()
    /// Lines from the engine's log that name no project. Shown only while no
    /// tab is in front: with one in front, they are about something else.
    private var engineChatter = StatusLine()
    /// Whether the chatter arrived after the last notice, so the newer of the
    /// two wins when neither a project line nor an upload has the bar.
    private var chatterIsNewer = false
    /// The newest line per project, so the bar can report the project in front
    /// rather than whichever one the engine happened to touch last.
    private var projectStatus: [String: StatusLine] = [:]
    /// The project of the tab in front.
    private var focusedProject: String?
    /// The current workspace's project names, for recognising which project an
    /// engine log line is about.
    private var knownProjects: [String] = []
    /// The newest project line of all, for when no tab is in front yet (at
    /// launch, or while the projects are still loading): the bar should still
    /// show that something is syncing.
    private var lastProjectLine: StatusLine?
    private var uploadStatus: StatusLine?
    private var uploadHold: DispatchWorkItem?
    /// How long a finished upload stays up before the engine's line returns.
    static var uploadHoldSeconds: TimeInterval = 3

    /// What the indicator says, for the checks.
    private(set) var syncIndicatorText = ""
    /// Left end of the bar: are both sides identical right now?
    private let syncStateDot = NSView()
    private let syncStateLabel = NSTextField(labelWithString: "")
    /// Right end of the bar: when that answer was last confirmed.
    private let syncCheckedLabel = NSTextField(labelWithString: "")
    /// The latest verdict per project, from the watcher's status events.
    private(set) var projectSyncStatus: [String: SyncStatus] = [:]
    /// Projects with a transfer in flight, and how far along.
    private var activeTransfers: [String: SyncProgress] = [:]
    /// Most recent transfers first, shown as the bar's tooltip.
    private(set) var recentTransfers: [String] = []
    /// The newest transfer, for the summary line once a pass settles.
    private var lastTransferLine: String?
    private var uploadObserver: NSObjectProtocol?
    /// How many shell tabs each project has opened, for "终端 N" titles.
    private var shellCounts: [String: Int] = [:]
    /// The instance server's clock, shown in the sidebar. nil until the first
    /// answer arrives, and on servers too old to report their time.
    private var serverClock: ServerClock?
    private var clockTimer: Timer?
    private var clockSyncedAt = Date.distantPast
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

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
        // One line, always: the bar is one line high, and a second one is drawn
        // on top of the first rather than below it.
        syncStatusLabel.maximumNumberOfLines = 1
        syncStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        syncStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        syncStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        syncStateDot.wantsLayer = true
        syncStateDot.layer?.cornerRadius = 4
        syncStateDot.isHidden = true
        syncStateDot.translatesAutoresizingMaskIntoConstraints = false
        syncStateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        syncStateLabel.textColor = NativeTheme.primaryText
        syncStateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        syncStateLabel.isHidden = true
        syncCheckedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        syncCheckedLabel.textColor = NativeTheme.secondaryText
        syncCheckedLabel.alignment = .right
        syncCheckedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        syncCheckedLabel.isHidden = true

        syncControl.bezelStyle = .rounded
        syncControl.controlSize = .small
        syncControl.font = .systemFont(ofSize: 11)
        syncControl.target = self
        syncControl.action = #selector(toggleSync)
        syncControl.isHidden = true
        syncControl.setContentCompressionResistancePriority(.required, for: .horizontal)

        let content = NSStackView(views: [
            syncStateDot, syncStateLabel, syncSpinner, syncBar, syncStatusLabel, syncControl, syncCheckedLabel,
        ])
        content.orientation = .horizontal
        content.spacing = 8
        content.setCustomSpacing(5, after: syncStateDot)
        content.setCustomSpacing(12, after: syncStateLabel)
        content.translatesAutoresizingMaskIntoConstraints = false

        statusBar.addSubview(separator)
        statusBar.addSubview(content)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: statusBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            content.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -12),
            content.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            syncStateDot.widthAnchor.constraint(equalToConstant: 8),
            syncStateDot.heightAnchor.constraint(equalToConstant: 8),
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
    /// A workspace-wide line (started, stopped, no local directory, a forced
    /// pass). It supersedes the per-project lines, which are about one project
    /// each and would otherwise keep covering it.
    func showSyncStatus(_ message: String, busy: Bool = false, progress: Double? = nil) {
        projectStatus.removeAll()
        lastProjectLine = nil
        engineStatus = StatusLine(
            text: message.trimmingCharacters(in: .whitespacesAndNewlines),
            busy: busy,
            progress: progress
        )
        chatterIsNewer = false
        renderStatus()
    }

    /// Paints whichever job owns the bar right now.
    private func renderStatus() {
        // An upload borrows the bar; otherwise it reports the project in front,
        // falling back to the engine's own workspace-wide line.
        let line: StatusLine
        if let upload = uploadStatus {
            line = upload
        } else if let focusedProject {
            // Only this terminal's project, or a notice about the user's own
            // action (终止, 重新同步, no local directory) — never another
            // project's line, and never engine chatter.
            line = projectStatus[focusedProject] ?? engineStatus
        } else {
            line = lastProjectLine ?? (chatterIsNewer ? engineChatter : engineStatus)
        }
        let text = line.text
        let busy = line.busy
        let progress = line.progress
        syncStatusLabel.stringValue = text
        if recentTransfers.isEmpty {
            syncStatusLabel.toolTip = text.isEmpty ? nil : "\(text)\n日志：\(SyncManager.logURL.path)"
        }
        syncStatusText = text
        isSyncing = busy
        syncFraction = progress
        refreshSyncControl()

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
        // Defensive: whatever is shown must be a single line.
        let text = message
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        guard !text.isEmpty else { return }

        // The engine prefixes its lines with the project, so a line about one
        // project belongs in that project's lane — the bar shows the project of
        // the tab in front, and a line about another one must not cover it.
        if let project = knownProjects.first(where: {
            text.hasPrefix("\($0)：") || text.hasPrefix("\($0): ")
        }) {
            let counts = parseSyncCounts(text)
            let busy = counts.map { $0.total > 0 } ?? false
            setProjectStatus(project, StatusLine(
                text: text,
                busy: busy,
                progress: counts.flatMap { $0.total > 0 ? Double($0.done) / Double($0.total) : nil }
            ))
            return
        }

        // Progress lines look like "项目: 45/820 (5%)". These come from the
        // engine's own log, so they update the engine line but leave the
        // per-project lines alone — the bar prefers the project in front.
        if let counts = parseSyncCounts(text), counts.total > 0 {
            engineChatter = StatusLine(text: text, busy: true, progress: Double(counts.done) / Double(counts.total))
            chatterIsNewer = true
            renderStatus()
            return
        }

        // A verdict line: mark the finish so it is unmistakable next to the
        // moving bar it replaces.
        let settled = text.contains("同步完成") || text.contains("无需同步") || text.contains("已是最新")
        engineChatter = StatusLine(text: settled ? "✓ \(text)" : text, busy: false)
        chatterIsNewer = true
        renderStatus()
    }

    /// Routes one structured event from the watcher. Progress drives the bar,
    /// a transfer becomes the "what just moved, how long it took" line, and a
    /// status settles the in-sync indicator.
    func handleSyncEvent(_ event: SyncEvent) {
        switch event {
        case let .progress(progress):
            if progress.phase == "done" {
                activeTransfers.removeValue(forKey: progress.project)
            } else {
                activeTransfers[progress.project] = progress
                let path = progress.path.map { " \($0)" } ?? ""
                let percent = Int(progress.percent.rounded())
                // The project goes first: a workspace syncs several of them and
                // the line is otherwise about no one in particular.
                setProjectStatus(progress.project, StatusLine(
                    text: "\(progress.project) · \(SyncEvent.phaseLabel(progress.phase))\(path) — \(progress.index)/\(progress.total) · \(percent)%",
                    busy: true,
                    progress: progress.percent / 100
                ))
            }
            refreshSyncIndicator()
        case let .transfer(transfer):
            let line = Self.describe(transfer)
            lastTransferLine = line
            recentTransfers.insert("\(Self.clockFormatter.string(from: Date()))  \(transfer.project)  \(line)", at: 0)
            if recentTransfers.count > 30 {
                recentTransfers.removeLast(recentTransfers.count - 30)
            }
            // Keep the bar moving if more of the plan is still to come.
            let inFlight = activeTransfers[transfer.project]
            setProjectStatus(transfer.project, StatusLine(
                text: "\(transfer.project) · \(line)",
                busy: inFlight != nil,
                progress: inFlight.map { $0.percent / 100 }
            ))
            refreshTransferTooltip()
        case let .status(status):
            projectSyncStatus[status.project] = status
            activeTransfers.removeValue(forKey: status.project)
            if status.applied > 0, status.inSync {
                let took = SyncFormat.duration(milliseconds: status.durationMS)
                let last = lastTransferLine.map { "  ·  最近：\($0)" } ?? ""
                setProjectStatus(status.project, StatusLine(
                    text: "✓ \(status.project)：同步了 \(status.applied) 个变更，用时 \(took)\(last)", busy: false
                ))
            } else if let error = status.error, !error.isEmpty {
                setProjectStatus(status.project, StatusLine(text: "\(status.project)：\(error)", busy: false))
            } else if var settledLine = projectStatus[status.project], settledLine.busy {
                // Settled with nothing applied: stop the spinner, keep the text.
                settledLine.busy = false
                settledLine.progress = nil
                setProjectStatus(status.project, settledLine)
            } else if engineStatus.busy, focusedProject == nil || focusedProject == status.project {
                engineStatus.busy = false
                engineStatus.progress = nil
                renderStatus()
            }
            syncCheckedLabel.stringValue = "核对于 \(Self.clockFormatter.string(from: Date())) · \(SyncFormat.duration(milliseconds: status.durationMS))"
            syncCheckedLabel.isHidden = false
            refreshSyncIndicator()
            refreshTransferTooltip()
        }
    }

    /// A file dropped on a terminal: a percentage while it goes up, then its
    /// size and how long it took, in the same bar as sync.
    func handleUploadNote(_ note: Notification) {
        guard let decoded = UploadProgressNote.decode(note) else { return }
        let file = decoded.file
        let project = decoded.project
        switch decoded.state {
        case let .running(fraction):
            let percent = Int((fraction * 100).rounded())
            showUploadStatus(
                StatusLine(text: "↑ 上传 \(file) 到 \(project) — \(percent)%", busy: true, progress: fraction),
                holding: false
            )
        case let .finished(bytes, milliseconds):
            var parts = ["↑ 上传 \(file)"]
            if bytes > 0 { parts.append(SyncFormat.bytes(bytes)) }
            parts.append(SyncFormat.duration(milliseconds: milliseconds))
            let line = parts.joined(separator: " · ")
            recentTransfers.insert("\(Self.clockFormatter.string(from: Date()))  \(project)  \(line)", at: 0)
            showUploadStatus(StatusLine(text: "✓ \(line)", busy: false), holding: true)
            refreshTransferTooltip()
        case let .failed(message):
            showUploadStatus(StatusLine(text: "上传失败：\(file)：\(message)", busy: false), holding: true)
        }
    }

    /// Keeps the sidebar and the names used to attribute engine log lines in
    /// step: a line reading "demo: 12/40" is only about a project if "demo" is
    /// one.
    private func showProjects(_ projects: [RemoteProject]) {
        knownProjects = projects.map(\.name)
        sidebar.setProjects(projects)
        // Reloading the list drops its selection; put the highlight back on
        // the project whose terminal is in front.
        sidebar.highlightProject(named: focusedProject)
    }

    private func setProjectStatus(_ project: String, _ line: StatusLine) {
        projectStatus[project] = line
        lastProjectLine = line
        renderStatus()
    }

    /// Follows the tab in front, so the bar reports that project's sync.
    private func focus(project: String?) {
        // The sidebar mirrors the tab in front, always — also when the focus
        // has not changed but the list was rebuilt underneath it.
        sidebar.highlightProject(named: project)
        guard focusedProject != project else { return }
        focusedProject = project
        renderStatus()
        refreshSyncIndicator()
    }

    /// An upload borrows the bar. `holding` means it is over: the line stays up
    /// briefly and then the engine's own state comes back, instead of leaving
    /// the bar claiming the project sync is finished.
    private func showUploadStatus(_ line: StatusLine, holding: Bool) {
        uploadHold?.cancel()
        uploadHold = nil
        uploadStatus = line
        renderStatus()
        guard holding else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.uploadStatus = nil
            self.uploadHold = nil
            self.renderStatus()
        }
        uploadHold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.uploadHoldSeconds, execute: work)
    }

    /// 终止 while a transfer is running, 重新同步 the rest of the time. Hidden
    /// until a workspace with a local directory is in front, since there is
    /// nothing to stop or restart before that.
    private func refreshSyncControl() {
        guard let workspace, let root = UserDefaults.standard.string(forKey: localRootKey(workspace)), !root.isEmpty else {
            syncControl.isHidden = true
            return
        }
        syncControl.isHidden = false
        syncControl.title = isTransferring ? "终止" : "重新同步"
    }

    /// A transfer is under way for the project in front (any project, with
    /// none in front), or the app itself started one.
    private var isTransferring: Bool {
        if engineStatus.busy { return true }
        if let focusedProject { return activeTransfers[focusedProject] != nil }
        return !activeTransfers.isEmpty
    }

    @objc private func toggleSync() {
        guard let workspace,
              let root = UserDefaults.standard.string(forKey: localRootKey(workspace)), !root.isEmpty else { return }
        if isTransferring {
            // Stopping the watcher aborts the transfer in flight; the files
            // already sent stay, and 重新同步 picks the rest up.
            syncManager?.stop()
            syncManager = nil
            activeTransfers.removeAll()
            refreshSyncIndicator()
            showSyncStatus("同步已终止——点「重新同步」继续", busy: false)
        } else {
            startSync(workspace, localRoot: URL(fileURLWithPath: root, isDirectory: true))
            showSyncStatus("正在重新同步…", busy: true)
        }
    }

    /// "↓ 下载 src/main.go · 1.2 MB · 340ms"
    static func describe(_ transfer: SyncTransfer) -> String {
        var parts = ["\(SyncEvent.phaseLabel(transfer.phase)) \(transfer.path)"]
        if transfer.bytes > 0 {
            parts.append(SyncFormat.bytes(transfer.bytes))
        }
        parts.append(SyncFormat.duration(milliseconds: transfer.durationMS))
        return parts.joined(separator: " · ")
    }

    /// Folds every project's latest verdict into the dot and its label: one
    /// project that is not in sync is enough to say so.
    private func refreshSyncIndicator() {
        // The project of the tab in front, when there is one: the bar describes
        // that terminal, and a count of every project in the workspace is about
        // none of them in particular.
        let statuses = focusedProject.map { name in projectSyncStatus.filter { $0.key == name } } ?? projectSyncStatus
        let active = focusedProject.map { name in activeTransfers.filter { $0.key == name } } ?? activeTransfers
        let state = Self.aggregateState(statuses: statuses, active: active)
        syncIndicatorText = state?.text ?? ""
        syncStateDot.isHidden = state == nil
        syncStateLabel.isHidden = state == nil
        guard let state else { return }
        syncStateDot.layer?.backgroundColor = state.color.cgColor
        syncStateLabel.stringValue = state.text
        syncStateLabel.toolTip = state.detail
        syncStateDot.toolTip = state.detail
    }

    struct SyncIndicator {
        let text: String
        let detail: String
        let color: NSColor
    }

    /// Pure so the smoke checks can pin the wording without a running engine.
    static func aggregateState(
        statuses: [String: SyncStatus],
        active: [String: SyncProgress]
    ) -> SyncIndicator? {
        if let first = active.sorted(by: { $0.key < $1.key }).first {
            let name = first.key
            let progress = first.value
            let percent = Int(progress.percent.rounded())
            return SyncIndicator(
                text: "同步中 \(percent)%",
                detail: "\(name)：\(progress.index)/\(progress.total) 项，\(SyncFormat.bytes(progress.bytes)) / \(SyncFormat.bytes(progress.totalBytes))",
                color: .systemBlue
            )
        }
        guard !statuses.isEmpty else { return nil }
        let sorted = statuses.values.sorted { $0.project < $1.project }
        if let failed = sorted.first(where: { ($0.error ?? "").isEmpty == false && ($0.conflicts ?? []).isEmpty }) {
            return SyncIndicator(text: "未同步", detail: "\(failed.project)：\(failed.error ?? "")", color: .systemRed)
        }
        if let conflicted = sorted.first(where: { ($0.conflicts ?? []).isEmpty == false }) {
            let paths = (conflicted.conflicts ?? []).prefix(5).joined(separator: "、")
            return SyncIndicator(
                text: "有冲突，已暂停",
                detail: "\(conflicted.project) 两端都改了：\(paths)",
                color: .systemOrange
            )
        }
        if sorted.allSatisfy(\.inSync) {
            let names = sorted.map(\.project).joined(separator: "、")
            return SyncIndicator(
                text: sorted.count > 1 ? "两端一致（\(sorted.count) 个项目）" : "两端一致",
                detail: "本地与服务器文件完全一致：\(names)",
                color: .systemGreen
            )
        }
        return SyncIndicator(text: "等待同步", detail: "有项目尚未完成核对", color: .systemGray)
    }

    private func refreshTransferTooltip() {
        guard !recentTransfers.isEmpty else { return }
        let log = "日志：\(SyncManager.logURL.path)"
        syncStatusLabel.toolTip = "最近同步的文件：\n" + recentTransfers.joined(separator: "\n") + "\n\n" + log
    }

    /// Clears per-workspace sync state when switching instances or stopping.
    private func resetSyncIndicator() {
        projectSyncStatus.removeAll()
        activeTransfers.removeAll()
        recentTransfers.removeAll()
        lastTransferLine = nil
        syncCheckedLabel.isHidden = true
        refreshSyncIndicator()
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
        terminalGrid.onNewShell = { [weak self] terminal in
            self?.openShell(terminal.project, in: terminal.workspace)
        }
        terminalGrid.onPaneClosed = { [weak self] terminal in
            self?.terminals.removeValue(forKey: terminal.paneKey)
        }
        sidebar.onEditProject = { [weak self] project in
            self?.editProject(project)
        }
        uploadObserver = NotificationCenter.default.addObserver(
            forName: UploadProgressNote.name,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleUploadNote(note)
        }
        sidebar.onChangeProjectLocalDir = { [weak self] project in
            self?.changeProjectLocalDir(project)
        }
        sidebar.onSyncProjectNow = { [weak self] project, policy in
            self?.syncProjectNow(project, policy: policy)
        }
        sidebar.onOpenSyncLog = {
            NSWorkspace.shared.activateFileViewerSelecting([SyncManager.logURL])
        }
        sidebar.onOpenShell = { [weak self] project in
            self?.openShell(project)
        }
        sidebar.onOpenProject = { [weak self] project in
            self?.open(project)
        }
        terminalGrid.onSelectTerminal = { [weak self] terminal in
            self?.focus(project: terminal?.project.name)
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
        startServerClock()
    }

    /// One timer drives the sidebar's server clock: it paints every second and
    /// asks the server again every five minutes. Painting locally is what keeps
    /// it to one request per resync instead of one per second; resyncing is what
    /// keeps the two machines' drift invisible at second resolution.
    ///
    /// The timer goes on the common run loop modes so the clock does not freeze
    /// while a menu is open or the window is being resized, and holds the
    /// controller weakly so it dies with the window.
    private func startServerClock() {
        syncServerClock()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickServerClock() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    deinit { clockTimer?.invalidate() }

    private func tickServerClock() {
        guard let serverClock else { return }
        sidebar.setServerClock(serverClock.text(), zone: serverClock.zoneName)
        if Date().timeIntervalSince(clockSyncedAt) >= 300 { syncServerClock() }
    }

    private func syncServerClock() {
        // Stamped before the request, not after it: a server that is down or
        // too old must not be retried once a second.
        clockSyncedAt = Date()
        Task { @MainActor in
            guard let identity = try? await client.identity() else { return }
            noteServerVersion(identity.serverVersion)
            guard let now = identity.now,
                  let clock = ServerClock(now: now, timezone: identity.timezone ?? "") else { return }
            serverClock = clock
            sidebar.setServerClock(clock.text(), zone: clock.zoneName)
        }
    }

    /// A deployed server is the signal to look for a client build: the sync
    /// engine in this app and that server are released together.
    private func noteServerVersion(_ version: String?) {
        guard let version, !version.isEmpty else { return }
        let key = "agentbox.server.version"
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(version, forKey: key)
        guard UpdateLogic.serverChanged(previous: previous, current: version) else { return }
        UpdateManager.shared.serverDidChange()
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
        resetSyncIndicator()
        sidebar.setWorkspaceID(workspace.id)
        let root = UserDefaults.standard.string(forKey: localRootKey(workspace))
        sidebar.setLocalRoot(root)
        if let root {
            startSync(workspace, localRoot: URL(fileURLWithPath: root, isDirectory: true))
        } else {
            showSyncStatus("未配置本地同步目录：点侧栏「选择目录」后开始同步")
        }
        showProjects([])
        focus(project: nil)
        projectStatus.removeAll()
        lastProjectLine = nil
        sidebar.setStatus("正在读取项目…")
        Task { @MainActor in
            do {
                let projects = try await client.projects(in: workspace)
                guard selectionGeneration == generation else { return }
                showProjects(projects)
            } catch {
                guard selectionGeneration == generation else { return }
                showProjects([])
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

    /// A new shell tab in the instance container, starting in the project
    /// directory. Unlike the AI session there is no "already open" check:
    /// every request is another independent shell.
    private func openShell(_ project: RemoteProject, in target: Workspace? = nil) {
        guard let workspace = target ?? workspace else { return }
        let key = "\(workspace.id)/\(project.name)"
        let index = (shellCounts[key] ?? 0) + 1
        shellCounts[key] = index
        let id = String(UUID().uuidString.lowercased().prefix(8))
        _ = terminalGrid.add(client: client, workspace: workspace, project: project, kind: .shell(id: id, index: index))
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
        let tools = workspace.tools
        sheet.availableAgents = tools
        sheet.defaultAgent = tools.contains(workspace.agent) ? workspace.agent : (tools.first ?? "claude")
        sheet.onCreate = { [weak self] draft in
            guard let self else { return }
            Task { @MainActor in
                do {
                    let created = try await self.client.createProject(
                        name: draft.name,
                        agent: draft.agent,
                        command: draft.command,
                        in: workspace
                    )
                    // A typed path that does not exist yet is created now, so
                    // the folder is there to open before the first file syncs.
                    if let dir = draft.localDir {
                        try? FileManager.default.createDirectory(
                            atPath: dir,
                            withIntermediateDirectories: true
                        )
                    }
                    if draft.localDir != nil || draft.policy != nil {
                        self.updateProjectSetting(for: workspace, project: created) { setting in
                            setting.localDir = draft.localDir
                            setting.policy = draft.policy
                        }
                    }
                    self.showProjects(try await self.client.projects(in: workspace))
                    // A new project has no baseline, so the chosen policy is
                    // what decides the very first sync. Sync needs a workspace
                    // directory for its baseline even when this project lives
                    // elsewhere; ask for one rather than silently not syncing.
                    if draft.localDir != nil || draft.policy != nil {
                        if self.requireLocalRoot(for: workspace, policy: draft.policy) != nil {
                            self.restartSync(workspace)
                        }
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

    /// Right-click "修改项目…": one form for the name, the local directory,
    /// the tool, the launch command and the sync mode, prefilled from the
    /// project. Only what changed is applied.
    private func editProject(_ project: RemoteProject) {
        guard let workspace, workspace.id == self.workspace?.id else { return }
        let setting = projectSettings(for: workspace)[project.id]
        let tools = workspace.tools.isEmpty ? ["claude"] : workspace.tools
        let currentAgent = project.agent.isEmpty
            ? (tools.contains(workspace.agent) ? workspace.agent : tools[0])
            : project.agent
        let currentCommand = project.command.isEmpty
            ? ProjectLaunch.defaultCommand(for: currentAgent)
            : project.command

        let sheet = NewProjectViewController()
        sheet.localRoot = UserDefaults.standard.string(forKey: localRootKey(workspace))
        sheet.availableAgents = tools
        sheet.defaultAgent = currentAgent
        sheet.prefill = .init(
            name: project.name,
            localDir: setting?.localDir,
            policy: setting?.policy,
            agent: currentAgent,
            command: currentCommand
        )
        sheet.onCreate = { [weak self] draft in
            self?.applyProjectEdit(project, in: workspace, draft: draft,
                                   currentAgent: currentAgent, currentCommand: currentCommand, setting: setting)
        }
        presentAsSheet(sheet)
    }

    private func applyProjectEdit(
        _ project: RemoteProject,
        in workspace: Workspace,
        draft: NewProjectViewController.Draft,
        currentAgent: String,
        currentCommand: String,
        setting: ProjectSyncSetting?
    ) {
        Task { @MainActor in
            // Launch settings first: they are a plain server update and are
            // keyed by project ID, so a rename afterwards keeps them.
            let agent = draft.agent ?? currentAgent
            let command = draft.command ?? ProjectLaunch.defaultCommand(for: agent)
            if agent != currentAgent || command != currentCommand {
                do {
                    _ = try await client.updateProjectLaunch(project, agent: agent, command: draft.command ?? "", in: workspace)
                } catch {
                    let failure = NSAlert()
                    failure.messageText = "修改启动命令失败"
                    failure.informativeText = error.localizedDescription
                    failure.alertStyle = .warning
                    failure.runModal()
                    return
                }
            }
            if draft.policy != setting?.policy {
                changeProjectPolicy(project, policy: draft.policy)
            }
            let oldDir = (setting?.localDir?.isEmpty == false) ? setting?.localDir : nil
            if draft.localDir != oldDir {
                if let dir = draft.localDir {
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    applyProjectLocalDir(URL(fileURLWithPath: dir, isDirectory: true), for: project, in: workspace)
                } else {
                    updateProjectSetting(for: workspace, project: project) { $0.localDir = nil }
                    restartSync(workspace)
                }
            }
            if draft.name != project.name {
                // Last: the rename stops and restarts sync around moving the
                // folders, and refreshes the list itself.
                renameProject(project, to: draft.name)
            } else {
                showProjects((try? await client.projects(in: workspace)) ?? [])
                showSyncStatus("已保存「\(project.name)」的设置")
            }
        }
    }

    /// Right-click rename: stop the sync engine, move the local folder, rename
    /// on the server (which renames the server-side directory), ask which side
    /// wins for the next bootstrap, then restart syncing.
    /// Renames a project on both sides; the name comes from the 修改项目 form.
    private func renameProject(_ project: RemoteProject, to requestedName: String) {
        guard let workspace, workspace.id == self.workspace?.id else { return }
        let newName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
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
            defer { sidebar.setStatus("") }

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
                showProjects(try await client.projects(in: workspace))
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
            defer { sidebar.setStatus("") }

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
                showProjects(try await client.projects(in: workspace))
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
        manager.onEvent = { [weak self] event in
            self?.handleSyncEvent(event)
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
        guard let root = requireLocalRoot(for: workspace, policy: policy.isEmpty ? nil : policy) else { return }
        let label = ProjectSyncSetting.policyLabel(policy)
        // An empty policy is an ordinary pass, run now: three-way merge, both
        // directions, nothing overwritten wholesale. Nothing to confirm and
        // nothing to record — the project keeps the sync mode it already has.
        if policy.isEmpty {
            runPass(project, in: workspace, root: root, policy: "", status: "正在同步「\(project.name)」…")
            return
        }
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
        runPass(
            project, in: workspace, root: root, policy: policy,
            status: "正在以\(label)全量同步「\(project.name)」…"
        )
    }

    /// Runs one pass over a single project and then puts the watcher back.
    /// An empty policy is a normal pass; "local"/"server" overwrite that way.
    private func runPass(
        _ project: RemoteProject, in workspace: Workspace, root: URL, policy: String, status: String
    ) {
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
        showSyncStatus(status, busy: true)
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

    /// Hiding the sidebar takes it out of the split view instead of just
    /// hiding it. A hidden arranged subview keeps its slot and the divider,
    /// which left a strip of window background framing the terminal; with the
    /// sidebar removed the terminal runs edge to edge.
    @objc private func toggleSidebar(_ sender: Any?) {
        guard !sidebarCollapsed else {
            sidebarCollapsed = false
            splitView.insertArrangedSubview(sidebar.view, at: 0)
            sidebar.view.isHidden = false
            splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
            splitView.adjustSubviews()
            splitView.setPosition(max(250, sidebarWidth), ofDividerAt: 0)
            view.layer?.backgroundColor = NativeTheme.content.cgColor
            return
        }

        sidebarWidth = max(250, sidebar.view.frame.width)
        sidebarCollapsed = true
        sidebar.view.isHidden = true
        splitView.removeArrangedSubview(sidebar.view)
        sidebar.view.removeFromSuperview()
        splitView.adjustSubviews()
        // Anything not covered by the terminal now reads as terminal, not as
        // a light frame around it.
        view.layer?.backgroundColor = NativeTheme.terminalBackground.cgColor
        terminalGrid.view.needsLayout = true
    }

    /// Whether the project sidebar is showing; for the smoke checks.
    var isSidebarVisible: Bool { !sidebarCollapsed && sidebar.view.superview === splitView }

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

    /// Reached from the toolbar button and from 设置… (⌘,) in the app menu,
    /// which has no target and finds this through the responder chain.
    @objc func openTerminalSettings() {
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
