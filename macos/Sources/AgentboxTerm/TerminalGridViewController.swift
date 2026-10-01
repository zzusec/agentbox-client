import AppKit

final class TerminalGridViewController: NSViewController {
    /// A pane was dismissed to the background; the owner must forget it so the
    /// project can be reopened from the sidebar.
    var onPaneClosed: ((TerminalViewController) -> Void)?

    private let grid = NSGridView(numberOfColumns: 1, rows: 0)
    private let emptyState = NSStackView()
    private var terminals: [TerminalViewController] = []

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NativeTheme.terminalBackground.cgColor

        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 1
        grid.columnSpacing = 1
        grid.xPlacement = .fill
        grid.yPlacement = .fill

        let icon = NSImageView(image: NativeTheme.symbol("rectangle.grid.2x2", size: 30, weight: .regular) ?? NSImage())
        icon.contentTintColor = NativeTheme.secondaryText
        let title = NSTextField(labelWithString: "选择一个项目开始")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = NSColor(calibratedWhite: 0.86, alpha: 1)
        let detail = NSTextField(labelWithString: "多个终端会自动按网格排列，拖动标题栏可调整位置；点 × 收起后实例继续运行。")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = NSColor(calibratedWhite: 0.62, alpha: 1)
        emptyState.setViews([icon, title, detail], in: .top)
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(grid)
        root.addSubview(emptyState)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            grid.topAnchor.constraint(equalTo: root.topAnchor),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
        updateEmptyState()
    }

    func contains(workspaceID: String, projectName: String) -> TerminalViewController? {
        terminals.first {
            $0.workspace.id == workspaceID && $0.project.name == projectName
        }
    }

    func add(client: AgentboxClient, workspace: Workspace, project: RemoteProject) -> TerminalViewController {
        let terminal = TerminalViewController(client: client, workspace: workspace, project: project)
        terminal.onClose = { [weak self, weak terminal] in
            guard let self, let terminal else { return }
            self.remove(terminal)
        }
        terminal.onReorder = { [weak self] draggedKey, targetKey in
            self?.reorder(draggedKey: draggedKey, ontoKey: targetKey)
        }
        addChild(terminal)
        terminals.append(terminal)
        rebuildGrid()
        return terminal
    }

    /// Dismiss a pane to the background: drop the local connection, keep the
    /// server-side session running (tmux survives disconnects by contract).
    func remove(_ terminal: TerminalViewController) {
        let window = terminal.view.window
        let firstResponder = window?.firstResponder as? NSView
        let wasFocused = firstResponder?.isDescendant(of: terminal.view) == true
        terminal.closeSession()
        terminals.removeAll { $0 === terminal }
        terminal.removeFromParent()
        rebuildGrid()
        if wasFocused {
            terminals.first?.activateTerminal()
        }
        onPaneClosed?(terminal)
    }

    /// Drop target semantics: the dragged pane takes the target's slot and the
    /// target (and everything between) shifts over.
    func reorder(draggedKey: String, ontoKey: String) {
        guard draggedKey != ontoKey,
              let draggedIndex = terminals.firstIndex(where: { $0.paneKey == draggedKey }),
              terminals.contains(where: { $0.paneKey == ontoKey })
        else { return }
        let dragged = terminals.remove(at: draggedIndex)
        let insertIndex = terminals.firstIndex(where: { $0.paneKey == ontoKey }) ?? 0
        terminals.insert(dragged, at: insertIndex)
        rebuildGrid()
    }

    private func rebuildGrid() {
        while grid.numberOfRows > 0 {
            grid.removeRow(at: 0)
        }
        guard !terminals.isEmpty else {
            updateEmptyState()
            return
        }

        let rows = makeRows(terminals)
        for row in rows {
            grid.addRow(with: row.map(\.view))
        }
        updateEmptyState()
    }

    private func updateEmptyState() {
        emptyState.isHidden = !terminals.isEmpty
        grid.isHidden = terminals.isEmpty
    }

    private func makeRows(_ terminals: [TerminalViewController]) -> [[TerminalViewController]] {
        let count = terminals.count
        if count == 1 {
            return [[terminals[0]]]
        }

        if !count.isMultiple(of: 2) {
            let leftCount = (count + 1) / 2
            let left = Array(terminals.prefix(leftCount))
            let right = Array(terminals.suffix(count - leftCount))
            return (0..<leftCount).map { index in
                var row = [left[index]]
                if index < right.count {
                    row.append(right[index])
                }
                return row
            }
        }

        let columns = Int(ceil(sqrt(Double(count))))
        return stride(from: 0, to: count, by: columns).map {
            Array(terminals[$0..<min($0 + columns, count)])
        }
    }
}
