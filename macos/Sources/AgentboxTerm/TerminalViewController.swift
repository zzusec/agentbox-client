import AppKit
import SwiftTerm

final class TerminalViewController: NSViewController, TerminalViewDelegate {
    let workspace: Workspace
    let project: RemoteProject

    private let client: AgentboxClient
    private let surface: TerminalSurface
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "连接中…")
    private var bridge: TerminalBridge?

    init(client: AgentboxClient, workspace: Workspace, project: RemoteProject) {
        self.client = client
        self.workspace = workspace
        self.project = project
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

        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = NativeTheme.terminalHeader.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let iconTile = NSView()
        iconTile.wantsLayer = true
        iconTile.layer?.backgroundColor = NativeTheme.accentSoft.cgColor
        iconTile.layer?.cornerRadius = 8
        iconTile.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NativeTheme.symbol("terminal.fill", size: 14, weight: .semibold) ?? NSImage())
        icon.contentTintColor = NativeTheme.accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconTile.addSubview(icon)
        NSLayoutConstraint.activate([
            iconTile.widthAnchor.constraint(equalToConstant: 30),
            iconTile.heightAnchor.constraint(equalToConstant: 30),
            icon.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
        ])

        let name = NSTextField(labelWithString: project.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = .white
        name.lineBreakMode = .byTruncatingTail
        let path = NSTextField(labelWithString: project.path)
        path.font = .systemFont(ofSize: 10.5)
        path.textColor = NSColor(calibratedWhite: 0.68, alpha: 1)
        path.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView(views: [name, path])
        labels.orientation = .vertical
        labels.spacing = 0
        labels.alignment = .leading

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
        ])
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
        let status = NSStackView(views: [statusDot, statusLabel])
        status.orientation = .horizontal
        status.spacing = 6
        status.alignment = .centerY

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerContent = NSStackView(views: [iconTile, labels, spacer, status])
        headerContent.orientation = .horizontal
        headerContent.alignment = .centerY
        headerContent.spacing = 10
        headerContent.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        headerContent.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerContent)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 46),
            headerContent.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerContent.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerContent.topAnchor.constraint(equalTo: header.topAnchor),
            headerContent.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])

        surface.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(surface)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surface.topAnchor.constraint(equalTo: header.bottomAnchor),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        setConnection(.connecting, text: "连接中…")
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

    private func connect() {
        guard let url = client.terminalURL(workspace: workspace, project: project.name) else {
            surface.feed(text: "\r\n无法生成终端连接地址。\r\n")
            setConnection(.error, text: "地址无效")
            return
        }
        let bridge = TerminalBridge(url: url)
        self.bridge = bridge
        bridge.onData = { [weak self] data in
            self?.setConnection(.connected, text: "已连接")
            self?.surface.feed(byteArray: ArraySlice(data))
        }
        bridge.onStatus = { [weak self] status in
            guard let self else { return }
            if status == "connecting" {
                self.setConnection(.connecting, text: "连接中…")
                return
            }
            if status.hasPrefix("closed") || status.hasPrefix("send failed") {
                self.setConnection(.error, text: "连接断开")
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

    private enum ConnectionVisual {
        case connecting
        case connected
        case error
    }

    private func setConnection(_ state: ConnectionVisual, text: String) {
        statusLabel.stringValue = text
        let color: NSColor
        switch state {
        case .connecting:
            color = NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.32, alpha: 1)
        case .connected:
            color = NSColor(calibratedRed: 0.20, green: 0.83, blue: 0.60, alpha: 1)
        case .error:
            color = NSColor(calibratedRed: 0.98, green: 0.44, blue: 0.52, alpha: 1)
        }
        statusDot.layer?.backgroundColor = color.cgColor
        statusLabel.textColor = color
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
