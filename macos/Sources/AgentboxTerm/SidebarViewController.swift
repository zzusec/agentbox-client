import AppKit

final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelectWorkspace: ((Workspace) -> Void)?
    var onSelectProject: ((FileEntry) -> Void)?
    var onChooseLocalRoot: (() -> Void)?

    private let workspacePicker = NSPopUpButton()
    private let table = NSTableView()
    private let localRoot = NSTextField(labelWithString: "尚未选择同步目录")
    private let chooseRootButton = NSButton(title: "选择同步目录", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "正在连接…")
    private var workspaces: [Workspace] = []
    private var projects: [FileEntry] = []

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let workspaceLabel = NSTextField(labelWithString: "工作空间")
        workspaceLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        workspaceLabel.textColor = .secondaryLabelColor

        workspacePicker.target = self
        workspacePicker.action = #selector(workspaceChanged)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project"))
        column.title = "项目"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.dataSource = self
        table.delegate = self
        table.style = .sourceList

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 3

        localRoot.font = .systemFont(ofSize: 11)
        localRoot.textColor = .secondaryLabelColor
        localRoot.lineBreakMode = .byTruncatingMiddle
        localRoot.maximumNumberOfLines = 2

        chooseRootButton.target = self
        chooseRootButton.action = #selector(chooseLocalRoot)
        chooseRootButton.bezelStyle = .rounded

        let stack = NSStackView(views: [
            workspaceLabel,
            workspacePicker,
            scroll,
            localRoot,
            chooseRootButton,
            status,
        ])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        view = root
    }

    func setWorkspaces(_ workspaces: [Workspace]) {
        self.workspaces = workspaces
        workspacePicker.removeAllItems()
        workspacePicker.addItems(withTitles: workspaces.map { "\($0.name) · \($0.accountLabel)" })
        status.stringValue = workspaces.isEmpty ? "没有可用工作空间" : ""
        if !workspaces.isEmpty {
            workspacePicker.selectItem(at: 0)
            onSelectWorkspace?(workspaces[0])
        }
    }

    func setProjects(_ projects: [FileEntry]) {
        self.projects = projects
        table.reloadData()
        status.stringValue = projects.isEmpty ? "这个工作空间还没有项目" : ""
    }

    func setStatus(_ value: String) {
        status.stringValue = value
    }

    func setLocalRoot(_ path: String?) {
        localRoot.stringValue = path ?? "尚未选择同步目录"
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        projects.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ProjectCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
            ?? NSTableCellView()
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.identifier = identifier
        cell.textField?.stringValue = projects[row].name
        cell.textField?.font = .systemFont(ofSize: 13)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < projects.count else { return }
        onSelectProject?(projects[row])
    }

    @objc private func workspaceChanged() {
        let index = workspacePicker.indexOfSelectedItem
        guard index >= 0, index < workspaces.count else { return }
        table.deselectAll(nil)
        onSelectWorkspace?(workspaces[index])
    }

    @objc private func chooseLocalRoot() {
        onChooseLocalRoot?()
    }
}
