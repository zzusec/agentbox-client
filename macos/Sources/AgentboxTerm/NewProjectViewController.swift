import AppKit

/// Card-style "new project" sheet matching the CLI-Manager form modal: title,
/// subtitle, a focused name field and a blue primary button. Enter creates,
/// Escape cancels.
///
/// Besides the name it carries the same two sync settings the project context
/// menu exposes: where the project lives on this Mac, and which side wins if
/// the project ever has to build a fresh sync baseline.
final class NewProjectViewController: NSViewController {
    /// What the sheet hands back. A nil localDir means the classic layout
    /// (`<local root>/<name>`); a nil policy means the workspace default.
    struct Draft {
        var name: String
        var localDir: String?
        var policy: String?
    }

    var onCreate: ((Draft) -> Void)?
    /// The workspace's local root, used to preview the default directory.
    var localRoot: String?

    private let nameField = NSTextField()
    private let dirField = NSTextField(labelWithString: "")
    private let dirHint = NSTextField(labelWithString: "")
    private let policyPopup = NSPopUpButton()
    private let errorLabel = NSTextField(labelWithString: "")
    private var resetButton: NSButton?
    /// Set only when the user picked a directory themselves.
    private(set) var customDir: String?

    private static let policies: [(String?, String)] = [
        (nil, "跟随工作空间"),
        ("server", "以服务器为准"),
        ("local", "以本地为准"),
    ]

    /// Stable handles for the smoke checks, which have no other way to tell
    /// the name field apart from the read-only directory preview.
    enum Field: String {
        case name = "agentbox.new-project.name"
        case localDir = "agentbox.new-project.local-dir"
        case policy = "agentbox.new-project.policy"
        case create = "agentbox.new-project.create"
    }

    override func loadView() {
        let root = NSView()
        root.frame = NSRect(x: 0, y: 0, width: 460, height: 330)
        root.wantsLayer = true
        root.layer?.backgroundColor = NativeTheme.content.cgColor

        let title = NSTextField(labelWithString: "新建项目")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = NativeTheme.primaryText
        let subtitle = NSTextField(labelWithString: "项目会在服务器工作区下创建，并同步到本地目录。")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = NativeTheme.secondaryText

        let nameLabel = fieldLabel("名称")
        nameField.placeholderString = "项目名称"
        nameField.identifier = NSUserInterfaceItemIdentifier(Field.name.rawValue)
        nameField.font = .systemFont(ofSize: 13)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(createClicked)

        let dirLabel = fieldLabel("本地工作空间")
        dirField.identifier = NSUserInterfaceItemIdentifier(Field.localDir.rawValue)
        dirField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dirField.textColor = NativeTheme.primaryText
        dirField.lineBreakMode = .byTruncatingMiddle
        dirField.translatesAutoresizingMaskIntoConstraints = false
        let chooseButton = NSButton(title: "选择…", target: self, action: #selector(chooseDirClicked))
        chooseButton.bezelStyle = .rounded
        let reset = NSButton(title: "默认", target: self, action: #selector(resetDirClicked))
        reset.bezelStyle = .rounded
        resetButton = reset
        let dirRow = NSStackView(views: [dirField, chooseButton, reset])
        dirRow.orientation = .horizontal
        dirRow.spacing = 8
        dirRow.translatesAutoresizingMaskIntoConstraints = false

        dirHint.font = .systemFont(ofSize: 10)
        dirHint.textColor = NativeTheme.secondaryText
        dirHint.lineBreakMode = .byTruncatingMiddle

        let policyLabel = fieldLabel("同步方式")
        policyPopup.identifier = NSUserInterfaceItemIdentifier(Field.policy.rawValue)
        policyPopup.addItem(withTitle: "跟随工作空间")
        policyPopup.itemArray.first?.toolTip = "使用工作空间当前的同步方式"
        for (_, label) in Self.policies.dropFirst() {
            policyPopup.addItem(withTitle: label)
        }
        policyPopup.toolTip = "项目首次建立同步基线时以哪边为准"

        let policyHint = NSTextField(
            labelWithString: "只在项目首次建立同步基线时生效：两边都有内容时，所选一侧覆盖另一侧。之后按三路合并，冲突会暂停同步。"
        )
        policyHint.font = .systemFont(ofSize: 10)
        policyHint.textColor = NativeTheme.secondaryText
        policyHint.lineBreakMode = .byWordWrapping
        policyHint.maximumNumberOfLines = 3
        policyHint.preferredMaxLayoutWidth = 400

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let createButton = NSButton(title: "新增", target: self, action: #selector(createClicked))
        createButton.bezelStyle = .rounded
        createButton.bezelColor = NativeTheme.accent
        createButton.keyEquivalent = "\r"
        createButton.identifier = NSUserInterfaceItemIdentifier(Field.create.rawValue)

        let buttons = NSStackView(views: [cancelButton, createButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [
            title, subtitle,
            nameLabel, nameField,
            dirLabel, dirRow, dirHint,
            policyLabel, policyPopup, policyHint,
            errorLabel, buttons,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setCustomSpacing(14, after: subtitle)
        content.setCustomSpacing(16, after: nameField)
        content.setCustomSpacing(16, after: dirHint)
        content.setCustomSpacing(18, after: errorLabel)
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            nameField.heightAnchor.constraint(equalToConstant: 30),
            nameField.widthAnchor.constraint(equalTo: content.widthAnchor),
            dirField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            policyHint.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        view = root
        preferredContentSize = NSSize(width: 460, height: 344)
        refreshDirectory()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NativeTheme.primaryText
        return label
    }

    private var trimmedName: String {
        nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shows the effective directory: the user's pick, or the classic
    /// `<local root>/<name>` that tracks whatever is typed in the name field.
    private func refreshDirectory() {
        let automatic: String? = {
            guard let root = localRoot, !root.isEmpty, !trimmedName.isEmpty else { return nil }
            return URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(trimmedName)
                .standardizedFileURL.path
        }()
        if let customDir {
            dirField.stringValue = customDir
            dirHint.stringValue = "已指定独立目录；不再跟随工作空间目录。"
        } else {
            dirField.stringValue = automatic ?? "（填写名称后自动生成）"
            dirHint.stringValue = automatic == nil
                ? "留空则同步到工作空间目录下的同名文件夹。"
                : "默认同步到工作空间目录下的同名文件夹。"
        }
        resetButton?.isEnabled = customDir != nil
    }

    /// Points the sheet at a directory, or back at the workspace default.
    func setCustomDir(_ path: String?) {
        customDir = path
        refreshDirectory()
    }

    @objc private func chooseDirClicked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "使用此目录"
        panel.message = "选择项目在本机的同步目录"
        if let current = customDir ?? (dirField.stringValue.isEmpty ? nil : dirField.stringValue) {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.setCustomDir(url.standardizedFileURL.path)
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    @objc private func resetDirClicked() {
        setCustomDir(nil)
    }

    @objc private func cancelClicked() {
        dismiss(self)
    }

    /// Validates the form and returns what should be created, or nil after
    /// showing an inline error. Split out of the button action so the assembly
    /// can be exercised without presenting a sheet — `dismiss` only makes
    /// sense once the sheet is on screen.
    func makeDraft() -> Draft? {
        let name = trimmedName
        guard !name.isEmpty else {
            showError("请输入项目名称")
            return nil
        }
        guard !name.contains("/"), !name.hasPrefix(".") else {
            showError("名称不能包含 / 或以 . 开头")
            return nil
        }
        var draft = Draft(name: name, localDir: customDir, policy: nil)
        let index = policyPopup.indexOfSelectedItem
        if index > 0, index < Self.policies.count {
            draft.policy = Self.policies[index].0
        }
        return draft
    }

    @objc private func createClicked() {
        guard let draft = makeDraft() else { return }
        dismiss(self)
        onCreate?(draft)
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }
}

extension NewProjectViewController: NSTextFieldDelegate {
    /// Keeps the previewed default directory in step with the typed name.
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === nameField else { return }
        refreshDirectory()
    }
}
