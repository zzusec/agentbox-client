import AppKit
import SwiftTerm

final class TerminalViewController: NSViewController, TerminalViewDelegate {
    let workspace: Workspace
    let project: RemoteProject

    private let client: AgentboxClient
    private let surface: TerminalSurface
    private var bridge: TerminalBridge?

    init(client: AgentboxClient, workspace: Workspace, project: RemoteProject) {
        self.client = client
        self.workspace = workspace
        self.project = project
        self.surface = TerminalSurface(
            frame: .zero,
            font: NSFont(name: "Menlo", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = surface
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

    private func connect() {
        guard let url = client.terminalURL(workspace: workspace, project: project.name) else {
            surface.feed(text: "\r\n无法生成终端连接地址。\r\n")
            return
        }
        let bridge = TerminalBridge(url: url)
        self.bridge = bridge
        bridge.onData = { [weak self] data in
            self?.surface.feed(byteArray: ArraySlice(data))
        }
        bridge.onStatus = { [weak self] status in
            if status.hasPrefix("closed") || status.hasPrefix("send failed") {
                self?.surface.feed(text: "\r\n\u{001B}[31m\(status)\u{001B}[0m\r\n")
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
