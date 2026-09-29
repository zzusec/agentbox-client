import AppKit

final class PairingWindowController: NSWindowController {
    var onConnected: ((SavedConnection) -> Void)?

    private let codeView = NSTextView()
    private let status = NSTextField(labelWithString: "在 agentbox 网页生成客户端配对码，然后粘贴到这里。")
    private let pasteButton = NSButton(title: "从剪贴板粘贴", target: nil, action: nil)
    private let connectButton = NSButton(title: "连接", target: nil, action: nil)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "连接 Agentbox"
        super.init(window: window)

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        status.translatesAutoresizingMaskIntoConstraints = false
        status.maximumNumberOfLines = 3
        status.lineBreakMode = .byWordWrapping

        codeView.isRichText = false
        codeView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        codeView.isEditable = true
        codeView.isSelectable = true
        codeView.isAutomaticQuoteSubstitutionEnabled = false
        codeView.isAutomaticDashSubstitutionEnabled = false
        codeView.string = ""
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = codeView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        pasteButton.target = self
        pasteButton.action = #selector(pasteFromClipboard)
        pasteButton.bezelStyle = .rounded
        pasteButton.translatesAutoresizingMaskIntoConstraints = false

        connectButton.target = self
        connectButton.action = #selector(connect)
        connectButton.keyEquivalent = "\r"
        connectButton.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(status)
        root.addSubview(scroll)
        let actions = NSStackView(views: [pasteButton, connectButton])
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.setHuggingPriority(.defaultHigh, for: .horizontal)
        root.addSubview(actions)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            status.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            actions.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            actions.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func focusCode() {
        window?.makeFirstResponder(codeView)
    }

    @objc private func pasteFromClipboard() {
        guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty else {
            status.stringValue = "剪贴板里没有可粘贴的文本。"
            return
        }
        codeView.string = value
        status.stringValue = "已从剪贴板粘贴，点击“连接”继续。"
        focusCode()
    }

    @objc private func connect() {
        let code = codeView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            status.stringValue = "请先粘贴配对码。"
            return
        }
        connectButton.isEnabled = false
        status.stringValue = "正在配对…"
        Task { @MainActor in
            do {
                let connection = try await AgentboxClient.redeem(code)
                onConnected?(connection)
                close()
            } catch {
                status.stringValue = error.localizedDescription
                connectButton.isEnabled = true
            }
        }
    }
}
