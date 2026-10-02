import AppKit
import SwiftTerm

/// What a terminal tab is attached to. The agent tab is the project's single
/// Claude/Codex session; shell tabs are plain shells in the instance
/// container, as many as the user opens, each with its own tmux session.
enum TerminalKind: Equatable {
    case agent
    case shell(id: String, index: Int)
}

enum TerminalConnectionState {
    case connecting
    case connected
    case error
}

final class TerminalViewController: NSViewController, TerminalViewDelegate {
    let workspace: Workspace
    let project: RemoteProject
    let kind: TerminalKind
    let paneKey: String
    /// Dismiss the terminal to the background (the instance keeps running).
    var onClose: (() -> Void)?
    /// Connection state changed; the tab chip mirrors it on its status dot.
    var onConnectionState: ((TerminalConnectionState) -> Void)?
    /// Whether this terminal is the one showing in the tab area.
    var isActive = false

    private(set) var connectionState: TerminalConnectionState = .connecting
    private var lastSentCols = 0
    private var lastSentRows = 0

    private let client: AgentboxClient
    private let surface: TerminalSurface
    private var bridge: TerminalBridge?

    /// Keystrokes typed while a dropped or pasted file is still uploading.
    /// The file's path is inserted only once the upload finishes; sending the
    /// typing straight through would put the path in the middle of it.
    private var heldInput = Data()
    private var uploadBatches = 0
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    private let uploadBanner = NSVisualEffectView()
    private let uploadLabel = NSTextField(labelWithString: "")
    private let uploadBar = NSProgressIndicator()

    init(client: AgentboxClient, workspace: Workspace, project: RemoteProject, kind: TerminalKind = .agent) {
        self.client = client
        self.workspace = workspace
        self.project = project
        self.kind = kind
        switch kind {
        case .agent:
            self.paneKey = "\(workspace.id)/\(project.name)"
        case let .shell(id, _):
            self.paneKey = "\(workspace.id)/\(project.name)#shell-\(id)"
        }
        self.surface = TerminalSurface(
            frame: .zero,
            font: NativeTheme.terminalFont()
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NativeTheme.terminalBackground.cgColor

        surface.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surface.topAnchor.constraint(equalTo: root.topAnchor),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.addSubview(buildUploadBanner())
        NSLayoutConstraint.activate([
            uploadBanner.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            uploadBanner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            uploadBanner.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -24),
            uploadBanner.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        surface.terminalDelegate = self
        surface.onDropFiles = { [weak self] urls in
            self?.upload(urls)
        }
        surface.onRefreshDisplay = { [weak self] in
            self?.resyncSize()
        }
        applyTheme()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyTheme),
            name: TerminalThemeManager.schemeChanged, object: nil
        )
        connect()
    }

    @objc private func applyTheme() {
        let scheme = TerminalThemeManager.current
        surface.nativeBackgroundColor = TerminalThemeManager.nsColor(scheme.background)
        surface.nativeForegroundColor = TerminalThemeManager.nsColor(scheme.foreground)
        surface.installColors(scheme.ansi.map { TerminalThemeManager.termColor($0) })
        if surface.font != TerminalThemeManager.font() {
            surface.font = TerminalThemeManager.font()
        }
        surface.applyMouseMode()
        refitPTY()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(surface)
    }

    /// The tab chip's title: the project for its agent session, "终端 N" for
    /// each extra shell.
    var tabTitle: String {
        switch kind {
        case .agent:
            return project.name
        case let .shell(_, index):
            return "\(project.name) · 终端 \(index)"
        }
    }

    func closeSession() {
        cancelUploads()
        bridge?.close()
        bridge = nil
        // A shell tab is gone for good once closed; end its tmux session so
        // it does not keep running in the container. The agent session is
        // kept on purpose — reopening the project reattaches to it.
        if case let .shell(id, _) = kind {
            let client = client, workspace = workspace, project = project.name
            Task { try? await client.closeShell(tab: id, project: project, in: workspace) }
        }
    }

    func activateTerminal() {
        view.window?.makeFirstResponder(surface)
    }

    /// Re-fit the PTY and terminal grid to the current visible size. Needed
    /// after a tab returns to the hierarchy: while backgrounded the view
    /// receives no layout events, so the grid keeps the old column count and
    /// SwiftTerm leaves the uncovered strip unpainted (stale pixels show).
    func refitPTY() {
        view.layoutSubtreeIfNeeded()
        let terminal = surface.getTerminal()
        guard terminal.cols != lastSentCols || terminal.rows != lastSentRows else { return }
        sendSize(cols: terminal.cols, rows: terminal.rows)
    }

    private func sendSize(cols: Int, rows: Int) {
        lastSentCols = cols
        lastSentRows = rows
        bridge?.resize(cols: cols, rows: rows)
    }

    /// Re-aligns the remote terminal with what this view actually shows.
    ///
    /// The bottom rows of a TUI (Claude Code's status line) sometimes stayed
    /// blank until the window was dragged: the tmux window ended up smaller
    /// than the view, and tmux paints a smaller window into the top of a
    /// larger client and leaves the rest empty. Re-sending an identical size
    /// changes nothing — tmux and the program only reflow on a real change —
    /// so this sends one row less and then the true size, which is exactly
    /// what dragging the window did.
    func resyncSize() {
        view.layoutSubtreeIfNeeded()
        let terminal = surface.getTerminal()
        let cols = terminal.cols, rows = terminal.rows
        guard cols > 0, rows > 1, bridge != nil else { return }
        bridge?.resize(cols: cols, rows: rows - 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.sendSize(cols: cols, rows: rows)
        }
    }

    private func connect() {
        guard let url = client.terminalURL(workspace: workspace, project: project.name, kind: kind) else {
            surface.feed(text: "\r\n无法生成终端连接地址。\r\n")
            setConnection(.error)
            return
        }
        let bridge = TerminalBridge(url: url)
        self.bridge = bridge
        // The size sent right after connecting can land before tmux is
        // attached; once the first output arrives the session is live, so
        // that is when the size is re-aligned (once per connection).
        var aligned = false
        bridge.onData = { [weak self, weak bridge] data in
            guard let self else { return }
            self.setConnection(.connected)
            self.surface.feed(byteArray: ArraySlice(data))
            if !aligned, let bridge, bridge === self.bridge {
                aligned = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.resyncSize()
                }
            }
        }
        bridge.onStatus = { [weak self] status in
            guard let self else { return }
            if status == "connecting" {
                self.setConnection(.connecting)
                return
            }
            if status.hasPrefix("closed") || status.hasPrefix("send failed") {
                self.setConnection(.error)
                self.surface.feed(text: "\r\n\u{001B}[31m\(status)\u{001B}[0m\r\n")
            }
        }
        bridge.connect()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let terminal = self.surface.getTerminal()
            self.sendSize(cols: terminal.cols, rows: terminal.rows)
            self.surface.window?.makeFirstResponder(self.surface)
        }
    }

    private func setConnection(_ state: TerminalConnectionState) {
        connectionState = state
        onConnectionState?(state)
    }

    /// A floating strip over the top of the terminal while files upload: what
    /// is going up, how far along it is, and a way to give up.
    private func buildUploadBanner() -> NSView {
        uploadBanner.material = .hudWindow
        uploadBanner.blendingMode = .withinWindow
        uploadBanner.state = .active
        uploadBanner.wantsLayer = true
        uploadBanner.layer?.cornerRadius = 8
        uploadBanner.isHidden = true
        uploadBanner.translatesAutoresizingMaskIntoConstraints = false

        uploadLabel.font = .systemFont(ofSize: 12, weight: .medium)
        uploadLabel.textColor = .labelColor
        uploadLabel.lineBreakMode = .byTruncatingMiddle
        uploadLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        uploadBar.style = .bar
        uploadBar.controlSize = .small
        uploadBar.minValue = 0
        uploadBar.maxValue = 1
        uploadBar.isIndeterminate = false
        let hint = NSTextField(labelWithString: "继续输入的内容会在路径插入后接上")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelUploads))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small

        let text = NSStackView(views: [uploadLabel, uploadBar, hint])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        let row = NSStackView(views: [text, cancel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        uploadBanner.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: uploadBanner.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: uploadBanner.trailingAnchor),
            row.topAnchor.constraint(equalTo: uploadBanner.topAnchor),
            row.bottomAnchor.constraint(equalTo: uploadBanner.bottomAnchor),
            uploadBar.widthAnchor.constraint(equalTo: text.widthAnchor),
        ])
        return uploadBanner
    }

    private func showUpload(file: String, index: Int, count: Int, fraction: Double) {
        let position = count > 1 ? "（\(index)/\(count)）" : ""
        uploadLabel.stringValue = "正在上传 \(file)\(position) — \(Int((fraction * 100).rounded()))%"
        uploadBar.doubleValue = fraction
        uploadBanner.isHidden = false
    }

    @objc private func cancelUploads() {
        uploadTasks.values.forEach { $0.cancel() }
    }

    /// Uploads dropped or pasted files, then types their server paths.
    ///
    /// Input is held for the whole batch: the path goes where the drop
    /// happened, and whatever was typed meanwhile follows it in order.
    private func upload(_ urls: [URL]) {
        let id = UUID()
        uploadBatches += 1
        showUpload(file: urls.first?.lastPathComponent ?? "", index: 1, count: urls.count, fraction: 0)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var serverPaths: [String] = []
            for (offset, url) in urls.enumerated() {
                if Task.isCancelled { break }
                let file = url.lastPathComponent
                let projectName = project.name
                let started = Date()
                // Progress hops to the main queue asynchronously and can land
                // after the upload returned; it must not reopen a finished bar.
                let settled = UploadSettled()
                showUpload(file: file, index: offset + 1, count: urls.count, fraction: 0)
                UploadProgressNote.post(file: file, project: projectName, state: .running(fraction: 0))
                do {
                    let remote = try await client.upload(
                        file: url,
                        workspace: workspace,
                        project: projectName,
                        onProgress: { [weak self] fraction in
                            DispatchQueue.main.async {
                                guard !settled.value else { return }
                                self?.showUpload(file: file, index: offset + 1, count: urls.count, fraction: fraction)
                                UploadProgressNote.post(file: file, project: projectName, state: .running(fraction: fraction))
                            }
                        }
                    )
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    let elapsed = Int64(Date().timeIntervalSince(started) * 1000)
                    settled.value = true
                    UploadProgressNote.post(
                        file: file, project: projectName,
                        state: .finished(bytes: size, milliseconds: elapsed)
                    )
                    if let remote {
                        serverPaths.append(remote)
                    }
                } catch {
                    settled.value = true
                    let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled
                    UploadProgressNote.post(
                        file: file, project: projectName,
                        state: .failed(message: cancelled ? "已取消" : error.localizedDescription)
                    )
                    if cancelled { break }
                    let alert = NSAlert()
                    alert.messageText = "上传失败"
                    alert.informativeText = "\(file)：\(error.localizedDescription)"
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
            finishUpload(id: id, serverPaths: serverPaths)
        }
        uploadTasks[id] = task
    }

    /// Types the uploaded paths, then releases whatever was typed meanwhile —
    /// in that order, which is the whole point of holding it.
    private func finishUpload(id: UUID, serverPaths: [String]) {
        uploadTasks.removeValue(forKey: id)
        if !serverPaths.isEmpty {
            let text = serverPaths.map(shellQuote).joined(separator: " ")
            let terminal = surface.getTerminal()
            if terminal.bracketedPasteMode {
                bridge?.send(data: Data("\u{001B}[200~\(text)\u{001B}[201~".utf8))
            } else {
                bridge?.send(data: Data(text.utf8))
            }
        }
        uploadBatches = max(0, uploadBatches - 1)
        if uploadBatches == 0 {
            uploadBanner.isHidden = true
            if !heldInput.isEmpty {
                bridge?.send(data: heldInput)
                heldInput.removeAll()
            }
        }
        surface.window?.makeFirstResponder(surface)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        sendSize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        guard isActive else { return }
        view.window?.title = "\(tabTitle) · \(title)"
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if uploadBatches > 0 {
            heldInput.append(contentsOf: data)
            return
        }
        bridge?.send(data: Data(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    func bell(source: TerminalView) {
        NSSound.beep()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Main-queue-only flag shared between an upload and its progress callbacks.
private final class UploadSettled {
    var value = false
}
