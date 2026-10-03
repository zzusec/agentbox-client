import AppKit
import WebKit

/// The terminal's screen: xterm.js running in a web view.
///
/// It replaces SwiftTerm. In one day that engine's macOS view needed nine local
/// patches — two formulas for the column count, a scrollbar strip nothing
/// repainted, a selection thrown away by every chunk of output, a wheel that
/// never reached the program — and each fix only uncovered the next. xterm.js
/// is what the web console already runs against the same socket protocol, so
/// one engine now draws a session in both clients and a fix lands once.
///
/// Only drawing moved. The socket, reconnects, heartbeats and the upload hold
/// stay in Swift (TerminalBridge, TerminalViewController); this view turns
/// bytes into pixels and keystrokes into bytes, and owns what has to be native:
/// file drops, pasting files and images, the clipboard and the context menu.
final class WebTerminalView: NSView, WKNavigationDelegate {
    /// Bytes the user typed (or a program's mouse report) for the remote end.
    var onInput: ((Data) -> Void)?
    /// The grid changed size; the remote terminal must follow.
    var onResize: ((Int, Int) -> Void)?
    var onTitle: ((String) -> Void)?
    var onDropFiles: (([URL]) -> Void)?
    /// "刷新显示" in the context menu.
    var onRefreshDisplay: (() -> Void)?

    /// The grid as the page last reported it; 0 until the page is up.
    private(set) var cols = 0
    private(set) var rows = 0
    private(set) var isReady = false

    private let webView: TerminalWebView
    /// Scripts issued before the page finished loading, run in order once it has.
    private var pendingScripts: [String] = []
    /// Output is gathered for one turn of the run loop and sent as one script:
    /// a busy program writes in many small pieces, and a JavaScript call per
    /// piece would be the bottleneck.
    private var pendingOutput = Data()
    private var flushScheduled = false

    /// Where the page and its scripts live. A built app carries them in its
    /// Resources; the smoke checks, which are not a bundle, point here instead.
    static var assetsDirectory: URL? {
        if let override = ProcessInfo.processInfo.environment["AGENTBOX_TERMINAL_ASSETS"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return Bundle.main.resourceURL?.appendingPathComponent("terminal", isDirectory: true)
    }

    override init(frame: NSRect) {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        configuration.userContentController = controller
        webView = TerminalWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        // A weak proxy: the content controller retains its handlers, and the
        // view retains the web view, which retains the controller.
        controller.add(WeakMessageHandler(self), name: "term")
        webView.host = self
        webView.navigationDelegate = self
        // No white flash before the page paints its own background.
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        load()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func load() {
        guard let directory = Self.assetsDirectory else { return }
        let page = directory.appendingPathComponent("terminal.html")
        webView.loadFileURL(page, allowingReadAccessTo: directory)
    }

    // MARK: Output

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        pendingOutput.append(data)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flushOutput() }
    }

    func write(text: String) {
        write(Data(text.utf8))
    }

    private func flushOutput() {
        flushScheduled = false
        guard !pendingOutput.isEmpty else { return }
        let chunk = pendingOutput
        pendingOutput = Data()
        run("window.agentboxTerm.write('\(chunk.base64EncodedString())')")
    }

    // MARK: Commands

    /// Font, colours and mouse handling. Columns follow from the font, so the
    /// page refits and reports a new size if they changed.
    func configure(_ settings: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: settings),
              let json = String(data: data, encoding: .utf8) else { return }
        run("window.agentboxTerm.configure(\(json))")
    }

    func refit() {
        run("window.agentboxTerm.refit()")
    }

    func focusTerminal() {
        window?.makeFirstResponder(webView)
        run("window.agentboxTerm.focus()")
    }

    /// Text as if the user pasted it: xterm.js wraps it in bracketed paste
    /// when the program asked for that.
    func paste(_ text: String) {
        run("window.agentboxTerm.paste(\(Self.jsString(text)))")
    }

    /// Whether the program asked for bracketed paste, read from the page.
    func bracketedPasteMode(_ completion: @escaping (Bool) -> Void) {
        guard isReady else { return completion(false) }
        webView.evaluateJavaScript("window.agentboxTerm.bracketedPaste()") { result, _ in
            completion((result as? Bool) ?? false)
        }
    }

    @objc func copySelection() {
        guard isReady else { return }
        webView.evaluateJavaScript("window.agentboxTerm.selection()") { result, _ in
            guard let text = result as? String, !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// ⌘V: files copied in Finder arrive as file URLs, a screenshot copied
    /// with ⌃⇧⌘4 as image data with no text — both upload, the same as a drop.
    /// Anything with text pastes as text.
    @objc func pasteFromClipboard() {
        let board = NSPasteboard.general
        let files = board.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if !files.isEmpty {
            onDropFiles?(files)
            return
        }
        if let text = board.string(forType: .string) {
            paste(text)
            return
        }
        if let image = Self.pastedImageFile(board) {
            onDropFiles?([image])
        }
    }

    @objc func selectAllText() {
        run("window.agentboxTerm.selectAll()")
    }

    @objc func refreshDisplay() {
        onRefreshDisplay?()
    }

    /// Writes clipboard image data (PNG, or TIFF converted to PNG) to a
    /// temporary file so it can be uploaded like a dropped one.
    static func pastedImageFile(_ board: NSPasteboard) -> URL? {
        var png = board.data(forType: .png)
        if png == nil, let tiff = board.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            png = rep.representation(using: .png, properties: [:])
        }
        guard let png else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pasted-\(formatter.string(from: Date())).png")
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// The terminal's own right-click menu, in place of the web view's
    /// (Reload, Inspect Element and the like mean nothing here).
    func buildContextMenu(into menu: NSMenu) {
        menu.removeAllItems()
        let items: [(String, Selector)] = [
            ("复制", #selector(copySelection)),
            ("粘贴", #selector(pasteFromClipboard)),
            ("全选", #selector(selectAllText)),
        ]
        for (title, action) in items {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "刷新显示", action: #selector(refreshDisplay), keyEquivalent: "").target = self
    }

    // MARK: Page

    private func run(_ script: String) {
        guard isReady else {
            pendingScripts.append(script)
            return
        }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            noteSize(message)
            let scripts = pendingScripts
            pendingScripts.removeAll()
            scripts.forEach { webView.evaluateJavaScript($0, completionHandler: nil) }
        case "input":
            if let text = message["data"] as? String { onInput?(Data(text.utf8)) }
        case "binary":
            if let encoded = message["data"] as? String, let data = Data(base64Encoded: encoded) {
                onInput?(data)
            }
        case "resize":
            noteSize(message)
        case "title":
            if let title = message["title"] as? String { onTitle?(title) }
        case "bell":
            NSSound.beep()
        case "link":
            // Only web links leave the app; a program printing file:// or a
            // custom scheme must not get to open things on this Mac.
            if let raw = message["uri"] as? String, let url = URL(string: raw),
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        case "clipboard":
            if let text = message["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        default:
            break
        }
    }

    private func noteSize(_ message: [String: Any]) {
        guard let cols = message["cols"] as? Int, let rows = message["rows"] as? Int,
              cols > 0, rows > 0, cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        onResize?(cols, rows)
    }

    /// Never navigate away from the terminal page (a link inside it, a drop
    /// WebKit got to first): links go through the page's own handler.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.isFileURL == true ? .allow : .cancel
    }

    private static func jsString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        // ["…"] -> "…": JSON string escaping is valid JavaScript.
        return String(array.dropFirst().dropLast())
    }
}

/// The web view itself, for what has to be handled natively.
final class TerminalWebView: WKWebView {
    weak var host: WebTerminalView?

    override init(frame: NSRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// ⌘C, ⌘V and ⌘A are the terminal's, before the Edit menu sees them: copy
    /// takes xterm.js's selection, paste may be an upload, and select-all means
    /// the scrollback rather than the page.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let host,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "c": host.copySelection()
        case "v": host.pasteFromClipboard()
        case "a": host.selectAllText()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        host?.buildContextMenu(into: menu)
        super.willOpenMenu(menu, with: event)
    }

    // Dropped files upload; WebKit must never get them (it would navigate to
    // the file and replace the terminal).
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(sender)
        guard !urls.isEmpty else { return false }
        host?.onDropFiles?(urls)
        return true
    }

    private static func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }
}

/// Holds the terminal view weakly for WebKit, which retains message handlers.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WebTerminalView?

    init(_ target: WebTerminalView) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message.body)
    }
}
