import AppKit
import SwiftTerm

final class TerminalViewController: NSViewController, TerminalViewDelegate {
    let workspace: Workspace
    let project: RemoteProject
    let paneKey: String
    /// Dismiss the pane to the background (the instance keeps running).
    var onClose: (() -> Void)?
    /// The pane header was used as a drop target for another pane's key.
    var onReorder: ((String, String) -> Void)?

    private let client: AgentboxClient
    private let surface: TerminalSurface
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "连接中…")
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

        let header = PaneHeader()
        header.paneKey = paneKey
        header.onDropPane = { [weak self] draggedKey in
            guard let self else { return }
            self.onReorder?(draggedKey, self.paneKey)
        }
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

        let closeButton = NSButton()
        closeButton.isBordered = false
        closeButton.image = NativeTheme.symbol("xmark", size: 12, weight: .semibold)
        closeButton.contentTintColor = NSColor(calibratedWhite: 0.62, alpha: 1)
        closeButton.toolTip = "收起终端（实例继续运行）"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
        ])
        header.closeButton = closeButton

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerContent = NSStackView(views: [iconTile, labels, spacer, status, closeButton])
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

    func activateTerminal() {
        view.window?.makeFirstResponder(surface)
    }

    @objc private func closeClicked() {
        onClose?()
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

/// Terminal pane header. Doubles as the drag handle for pane reordering: the
/// whole header is one hit target (labels don't steal events), while the close
/// button stays clickable. Drop target for another pane's key.
final class PaneHeader: NSView, NSDraggingSource {
    static let paneType = NSPasteboard.PasteboardType("io.agentbox.term.pane")

    var paneKey = ""
    var onDropPane: ((String) -> Void)?
    weak var closeButton: NSButton?

    private var mouseDownLocation: NSPoint = .zero
    private var dragging = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let closeButton {
            let buttonPoint = closeButton.convert(local, from: self)
            if closeButton.bounds.contains(buttonPoint) {
                return closeButton
            }
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard abs(location.x - mouseDownLocation.x) > 4 || abs(location.y - mouseDownLocation.y) > 4 else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: PaneWriter(key: paneKey))
        item.setDraggingFrame(bounds, contents: cachedHeaderImage())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    private func cachedHeaderImage() -> NSImage? {
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: representation)
        guard let cgImage = representation.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: bounds.size)
    }

    private func setDropHighlight(_ active: Bool) {
        layer?.borderWidth = active ? 2 : 0
        layer?.borderColor = NativeTheme.accent.cgColor
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor draggingContext: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.data(forType: Self.paneType) != nil else { return [] }
        setDropHighlight(true)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropHighlight(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDropHighlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlight(false)
        guard let key = sender.draggingPasteboard.string(forType: Self.paneType), key != paneKey else { return false }
        onDropPane?(key)
        return true
    }
}

private final class PaneWriter: NSObject, NSPasteboardWriting {
    let key: String

    init(key: String) {
        self.key = key
        super.init()
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [PaneHeader.paneType]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == PaneHeader.paneType ? key : nil
    }
}
