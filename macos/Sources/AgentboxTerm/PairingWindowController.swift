import AppKit

final class PairingWindowController: NSWindowController {
    var onConnected: ((SavedConnection) -> Void)?

    private let codeView = NSTextView()
    private let status = NSTextField(labelWithString: "在 agentbox 网页生成客户端配对码，然后粘贴到这里。")
    private let pasteButton = NSButton(title: "从剪贴板粘贴", target: nil, action: nil)
    private let connectButton = NSButton(title: "连接", target: nil, action: nil)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "连接 agentbox-client"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        super.init(window: window)

        let root = NSVisualEffectView()
        root.material = .underWindowBackground
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState
        window.contentView = root

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 76),
            icon.heightAnchor.constraint(equalToConstant: 76),
        ])

        let title = NSTextField(labelWithString: "连接 agentbox-client")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        title.textColor = NativeTheme.primaryText
        title.alignment = .center
        let subtitle = NSTextField(labelWithString: "粘贴网页生成的配对码，连接你的 agentbox 实例。。")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = NativeTheme.secondaryText
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2

        let codeTitle = NSTextField(labelWithString: "配对码")
        codeTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        codeTitle.textColor = NativeTheme.secondaryText

        codeView.isRichText = false
        codeView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        codeView.textColor = NativeTheme.primaryText
        codeView.backgroundColor = .clear
        codeView.drawsBackground = false
        codeView.isEditable = true
        codeView.isSelectable = true
        codeView.isAutomaticQuoteSubstitutionEnabled = false
        codeView.isAutomaticDashSubstitutionEnabled = false
        codeView.textContainerInset = NSSize(width: 12, height: 10)
        codeView.string = ""

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = codeView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.backgroundColor = NativeTheme.cardHover.cgColor
        scroll.layer?.borderColor = NativeTheme.border.cgColor
        scroll.layer?.borderWidth = 1
        scroll.heightAnchor.constraint(equalToConstant: 112).isActive = true

        let paste = NSButton(title: "从剪贴板粘贴", target: self, action: #selector(pasteFromClipboard))
        paste.image = NativeTheme.symbol("doc.on.clipboard", size: 13, weight: .medium)
        paste.imagePosition = .imageLeading
        paste.bezelStyle = .rounded
        paste.controlSize = .large

        let codeActions = NSStackView(views: [NSView(), paste])
        codeActions.orientation = .horizontal

        let codeStack = NSStackView(views: [codeTitle, scroll, codeActions])
        codeStack.orientation = .vertical
        codeStack.spacing = 8
        codeStack.alignment = .leading
        codeStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        codeStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: codeStack.widthAnchor, constant: -32).isActive = true
        codeActions.widthAnchor.constraint(equalTo: codeStack.widthAnchor, constant: -32).isActive = true

        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 14
        card.borderWidth = 1
        card.borderColor = NativeTheme.border
        card.fillColor = NativeTheme.card
        card.contentView = codeStack

        status.font = .systemFont(ofSize: 12)
        status.textColor = NativeTheme.secondaryText
        status.maximumNumberOfLines = 3
        status.lineBreakMode = .byWordWrapping
        status.alignment = .center

        connectButton.target = self
        connectButton.action = #selector(connect)
        connectButton.keyEquivalent = "\r"
        connectButton.bezelStyle = .rounded
        connectButton.controlSize = .large
        connectButton.bezelColor = NativeTheme.accent
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        connectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 148).isActive = true

        let stack = NSStackView(views: [icon, title, subtitle, card, status, connectButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(18, after: subtitle)
        stack.setCustomSpacing(16, after: card)
        stack.edgeInsets = NSEdgeInsets(top: 42, left: 36, bottom: 30, right: 36)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -72),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func focusCode() {
        window?.makeFirstResponder(codeView)
    }

    @objc private func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        let value = pasteboard.string(forType: .string)
            ?? (pasteboard.readObjects(forClasses: [NSString.self], options: nil)?.first as? String)
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status.stringValue = "剪贴板里没有可粘贴的文本。"
            status.textColor = .systemRed
            return
        }
        codeView.string = value
        status.stringValue = "已从剪贴板粘贴，点击“连接”继续。"
        status.textColor = NativeTheme.accent
        focusCode()
    }

    @objc private func connect() {
        let code = codeView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            status.stringValue = "请先粘贴配对码。"
            status.textColor = .systemRed
            focusCode()
            return
        }
        connectButton.isEnabled = false
        status.stringValue = "正在配对…"
        status.textColor = NativeTheme.secondaryText
        Task { @MainActor in
            do {
                let connection = try await AgentboxClient.redeem(code)
                onConnected?(connection)
                close()
            } catch {
                status.stringValue = error.localizedDescription
                status.textColor = .systemRed
                connectButton.isEnabled = true
            }
        }
    }
}
