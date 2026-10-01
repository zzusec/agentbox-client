import AppKit
import SwiftTerm

enum TerminalConnectionState {
    case connecting
    case connected
    case error
}

final class TerminalViewController: NSViewController, TerminalViewDelegate {
    let workspace: Workspace
    let project: RemoteProject
    let paneKey: String
    /// Dismiss the terminal to the background (the instance keeps running).
    var onClose: (() -> Void)?
    /// Connection state changed; the tab chip mirrors it on its status dot.
    var onConnectionState: ((TerminalConnectionState) -> Void)?
    /// Whether this terminal is the one showing in the tab area.
    var isActive = false

    private(set) var connectionState: TerminalConnectionState = .connecting

    private let client: AgentboxClient
    private let surface: TerminalSurface
    private var bridge: TerminalBridge?

    init(client: AgentboxClient, workspace: Workspace, project: RemoteProject) {
        self.client = client
        self.workspace = workspace
        self.project = project
        self.paneKey = "\(workspace.id)/\(project.name)"
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
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        surface.terminalDelegate = self
        surface.onDropFiles = { [weak self] urls in
            self?.upload(urls)
        }
        connect()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(surface)
    }

    func closeSession() {
        bridge?.close()
        bridge = nil
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
        bridge?.resize(cols: terminal.cols, rows: terminal.rows)
    }

    private func connect() {
        guard let url = client.terminalURL(workspace: workspace, project: project.name) else {
            surface.feed(text: "\r\n无法生成终端连接地址。\r\n")
            setConnection(.error)
            return
        }
        let bridge = TerminalBridge(url: url)
        self.bridge = bridge
        bridge.onData = { [weak self] data in
            self?.setConnection(.connected)
            self?.surface.feed(byteArray: ArraySlice(data))
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
            bridge.resize(cols: terminal.cols, rows: terminal.rows)
            self.surface.window?.makeFirstResponder(self.surface)
        }
    }

    private func setConnection(_ state: TerminalConnectionState) {
        connectionState = state
        onConnectionState?(state)
    }

    private func upload(_ urls: [URL]) {
        Task { @MainActor in
            var serverPaths: [String] = []
            for url in urls {
                do {
                    if let remote = try await client.upload(file: url, workspace: workspace, project: project.name) {
                        serverPaths.append(remote)
                    }
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "上传失败"
                    alert.informativeText = "\(url.lastPathComponent)：\(error.localizedDescription)"
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
            guard !serverPaths.isEmpty else { return }
            let text = serverPaths.map(shellQuote).joined(separator: " ")
            let terminal = surface.getTerminal()
            if terminal.bracketedPasteMode {
                surface.send(txt: "\u{001B}[200~\(text)\u{001B}[201~")
            } else {
                surface.send(txt: text)
            }
            surface.window?.makeFirstResponder(surface)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        bridge?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        guard isActive else { return }
        view.window?.title = "\(project.name) · \(title)"
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
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
