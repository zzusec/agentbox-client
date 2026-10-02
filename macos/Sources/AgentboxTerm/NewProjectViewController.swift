import AppKit

/// Card-style "new project" sheet matching the CLI-Manager form modal: title,
/// subtitle, a focused name field and a blue primary button. Enter creates,
/// Escape cancels.
///
/// Besides the name it carries where the project lives on this Mac (typed,
/// pasted or picked), which tool its terminal starts and with what command,
/// and which side wins if the project ever has to build a fresh sync baseline.
final class NewProjectViewController: NSViewController {
    /// What the sheet hands back. A nil localDir means the classic layout
    /// (`<local root>/<name>`); a nil policy means the workspace default; a
    /// nil agent follows the instance default and a nil command means the
    /// default command for the chosen tool.
    struct Draft {
        var name: String
        var localDir: String?
        var policy: String?
        var agent: String?
        var command: String?
    }

    var onCreate: ((Draft) -> Void)?
    /// The workspace's local root, used to preview the default directory.
    var localRoot: String?
    /// Tools the instance has accounts for, in display order, and the one it
    /// starts by default. Set before the view loads.
    var availableAgents: [String] = ["claude"]
    var defaultAgent: String = "claude"

    private let nameField = NSTextField()
    private let dirField = NSTextField()
    private let dirHint = NSTextField(labelWithString: "")
    private let agentPopup = NSPopUpButton()
    private let commandField = NSTextField()
    private let commandHint = NSTextField(labelWithString: "")
    private let policyPopup = NSPopUpButton()
    private let errorLabel = NSTextField(labelWithString: "")
    private var resetButton: NSButton?
    /// Set only when the user typed or picked a directory themselves.
    private(set) var customDir: String?
    /// The command the field showed as "the default" last time, so switching
    /// tools replaces an untouched default but never a typed command.
    private var shownDefaultCommand = ""

    private static let policies: [(String?, String)] = [
        (nil, ProjectSyncSetting.policyLabel(nil)),
        ("server", ProjectSyncSetting.policyLabel("server")),
        ("local", ProjectSyncSetting.policyLabel("local")),
    ]

    /// Stable handles for the smoke checks, which have no other way to tell
    /// the fields apart.
    enum Field: String {
        case name = "agentbox.new-project.name"
        case localDir = "agentbox.new-project.local-dir"
        case agent = "agentbox.new-project.agent"
        case command = "agentbox.new-project.command"
        case policy = "agentbox.new-project.policy"
        case create = "agentbox.new-project.create"
    }

    override func loadView() {
        let root = NSView()
        root.frame = NSRect(x: 0, y: 0, width: 480, height: 500)
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

        let dirLabel = fieldLabel("本地目录")
        dirField.identifier = NSUserInterfaceItemIdentifier(Field.localDir.rawValue)
        dirField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        dirField.textColor = NativeTheme.primaryText
        dirField.placeholderString = "填写名称后自动生成，也可以直接输入或粘贴路径"
        dirField.lineBreakMode = .byTruncatingMiddle
        dirField.usesSingleLineMode = true
        dirField.cell?.wraps = false
        dirField.cell?.isScrollable = true
        dirField.delegate = self
        dirField.translatesAutoresizingMaskIntoConstraints = false
        let chooseButton = NSButton(title: "选择…", target: self, action: #selector(chooseDirClicked))
        chooseButton.bezelStyle = .rounded
        let reset = NSButton(title: "默认", target: self, action: #selector(resetDirClicked))
        reset.bezelStyle = .rounded
        reset.toolTip = "改回工作空间目录下的同名文件夹"
        resetButton = reset
        let dirRow = NSStackView(views: [dirField, chooseButton, reset])
        dirRow.orientation = .horizontal
        dirRow.spacing = 8
        dirRow.translatesAutoresizingMaskIntoConstraints = false

        dirHint.font = .systemFont(ofSize: 10)
        dirHint.textColor = NativeTheme.secondaryText
        dirHint.lineBreakMode = .byTruncatingMiddle

        let agentLabel = fieldLabel("开发工具")
        agentPopup.identifier = NSUserInterfaceItemIdentifier(Field.agent.rawValue)
        let agents = availableAgents.isEmpty ? [defaultAgent] : availableAgents
        for agent in agents {
            agentPopup.addItem(withTitle: ProjectLaunch.label(for: agent))
            agentPopup.lastItem?.representedObject = agent
        }
        if let index = agents.firstIndex(of: defaultAgent) {
            agentPopup.selectItem(at: index)
        }
        agentPopup.isEnabled = agents.count > 1
        agentPopup.toolTip = agents.count > 1
            ? "项目终端启动哪个工具"
            : "实例只绑定了 \(ProjectLaunch.label(for: agents[0])) 账号"
        agentPopup.target = self
        agentPopup.action = #selector(agentChanged)

        let commandLabel = fieldLabel("启动命令")
        commandField.identifier = NSUserInterfaceItemIdentifier(Field.command.rawValue)
        commandField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        commandField.usesSingleLineMode = true
        commandField.cell?.wraps = false
        commandField.cell?.isScrollable = true
        commandField.delegate = self
        commandField.translatesAutoresizingMaskIntoConstraints = false
        commandHint.font = .systemFont(ofSize: 10)
        commandHint.textColor = NativeTheme.secondaryText
        commandHint.lineBreakMode = .byWordWrapping
        commandHint.maximumNumberOfLines = 2
        commandHint.preferredMaxLayoutWidth = 420

        let policyLabel = fieldLabel("同步方式")
        policyPopup.identifier = NSUserInterfaceItemIdentifier(Field.policy.rawValue)
        policyPopup.addItem(withTitle: ProjectSyncSetting.policyLabel(nil))
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
        policyHint.preferredMaxLayoutWidth = 420

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
            agentLabel, agentPopup,
            commandLabel, commandField, commandHint,
            policyLabel, policyPopup, policyHint,
            errorLabel, buttons,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setCustomSpacing(14, after: subtitle)
        content.setCustomSpacing(16, after: nameField)
        content.setCustomSpacing(16, after: dirHint)
        content.setCustomSpacing(16, after: agentPopup)
        content.setCustomSpacing(16, after: commandHint)
        content.setCustomSpacing(18, after: errorLabel)
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            nameField.heightAnchor.constraint(equalToConstant: 30),
            nameField.widthAnchor.constraint(equalTo: content.widthAnchor),
            dirRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            dirField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            commandField.heightAnchor.constraint(equalToConstant: 26),
            commandField.widthAnchor.constraint(equalTo: content.widthAnchor),
            commandHint.widthAnchor.constraint(equalTo: content.widthAnchor),
            policyHint.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        view = root
        preferredContentSize = NSSize(width: 480, height: 520)
        refreshDirectory()
        refreshCommand()
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

    /// `<local root>/<name>`, or nil while either is missing.
    private var automaticDir: String? {
        guard let root = localRoot, !root.isEmpty, !trimmedName.isEmpty else { return nil }
        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(trimmedName)
            .standardizedFileURL.path
    }

    /// Shows the effective directory: the user's own, or the classic
    /// `<local root>/<name>` that tracks whatever is typed in the name field.
    private func refreshDirectory() {
        if let customDir {
            dirField.stringValue = customDir
        } else {
            dirField.stringValue = automaticDir ?? ""
        }
        refreshDirectoryHint()
    }

    private func refreshDirectoryHint() {
        if customDir != nil {
            dirHint.stringValue = "已指定独立目录；不再跟随工作空间目录。目录不存在时会自动创建。"
        } else if automaticDir == nil {
            dirHint.stringValue = localRoot?.isEmpty == false
                ? "留空则同步到工作空间目录下的同名文件夹。"
                : "还没有选择工作空间目录：可以在这里直接输入本项目的本地路径。"
        } else {
            dirHint.stringValue = "默认同步到工作空间目录下的同名文件夹；可直接修改。"
        }
        resetButton?.isEnabled = customDir != nil
    }

    /// Points the sheet at a directory, or back at the workspace default.
    func setCustomDir(_ path: String?) {
        customDir = path
        refreshDirectory()
    }

    /// Typing in the directory field. An empty field, or one that matches the
    /// automatic default again, is the same as no override.
    private func directoryEdited() {
        let typed = Self.normalizedPath(dirField.stringValue)
        if typed == nil || typed == automaticDir {
            customDir = nil
        } else {
            customDir = typed
        }
        refreshDirectoryHint()
    }

    /// Trims and expands `~`. Relative paths are kept as typed so makeDraft
    /// can reject them with a message instead of guessing a base.
    static func normalizedPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return expanded }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    var selectedAgent: String {
        (agentPopup.selectedItem?.representedObject as? String) ?? defaultAgent
    }

    /// Shows the selected tool's default command unless the user has typed
    /// their own, which a tool switch must never throw away.
    private func refreshCommand() {
        let fresh = ProjectLaunch.defaultCommand(for: selectedAgent)
        let current = commandField.stringValue.trimmingCharacters(in: .whitespaces)
        if current.isEmpty || current == shownDefaultCommand {
            commandField.stringValue = fresh
        }
        shownDefaultCommand = fresh
        commandField.placeholderString = fresh
        commandHint.stringValue = "默认：\(fresh)。可以改成任意命令（例如加参数）；清空则恢复默认。"
    }

    @objc private func agentChanged() {
        refreshCommand()
    }

    @objc private func chooseDirClicked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "使用此目录"
        panel.message = "选择项目在本机的同步目录"
        if let current = customDir ?? automaticDir {
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
        if let customDir, !customDir.hasPrefix("/") {
            showError("本地目录需要是完整路径，例如 ~/code/\(name) 或 /Users/…")
            return nil
        }
        let command = commandField.stringValue.trimmingCharacters(in: .whitespaces)
        if command.rangeOfCharacter(from: .newlines) != nil
            || command.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            showError("启动命令不能包含换行或控制字符")
            return nil
        }
        var draft = Draft(name: name, localDir: customDir, policy: nil)
        let index = policyPopup.indexOfSelectedItem
        if index > 0, index < Self.policies.count {
            draft.policy = Self.policies[index].0
        }
        let agent = selectedAgent
        if agent != defaultAgent || availableAgents.count > 1 {
            draft.agent = agent
        }
        if !command.isEmpty, command != ProjectLaunch.defaultCommand(for: agent) {
            draft.command = command
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
    /// The name keeps the previewed default directory in step; the directory
    /// field records a typed override as soon as it differs from the default.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === nameField {
            refreshDirectory()
        } else if field === dirField {
            directoryEdited()
        }
        errorLabel.isHidden = true
    }
}
