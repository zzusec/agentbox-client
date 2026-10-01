import AppKit

/// Card-style "new project" sheet matching the CLI-Manager form modal: title,
/// subtitle, a focused name field and a blue primary button. Enter creates,
/// Escape cancels.
final class NewProjectViewController: NSViewController {
    var onCreate: ((String) -> Void)?

    private let nameField = NSTextField()
    private let errorLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView()
        root.frame = NSRect(x: 0, y: 0, width: 440, height: 210)
        root.wantsLayer = true
        root.layer?.backgroundColor = NativeTheme.content.cgColor

        let title = NSTextField(labelWithString: "新建项目")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = NativeTheme.primaryText
        let subtitle = NSTextField(labelWithString: "项目会在服务器工作区下创建，并同步到本地同步目录。")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = NativeTheme.secondaryText

        let nameLabel = NSTextField(labelWithString: "名称")
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = NativeTheme.primaryText
        nameField.placeholderString = "项目名称"
        nameField.font = .systemFont(ofSize: 13)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.target = self
        nameField.action = #selector(createClicked)

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

        let buttons = NSStackView(views: [cancelButton, createButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [title, subtitle, nameLabel, nameField, errorLabel, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setCustomSpacing(14, after: subtitle)
        content.setCustomSpacing(18, after: errorLabel)
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            nameField.heightAnchor.constraint(equalToConstant: 30),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        view = root
        preferredContentSize = NSSize(width: 440, height: 224)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    @objc private func cancelClicked() {
        dismiss(self)
    }

    @objc private func createClicked() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorLabel.stringValue = "请输入项目名称"
            errorLabel.isHidden = false
            return
        }
        guard !name.contains("/"), !name.hasPrefix(".") else {
            errorLabel.stringValue = "名称不能包含 / 或以 . 开头"
            errorLabel.isHidden = false
            return
        }
        dismiss(self)
        onCreate?(name)
    }
}
