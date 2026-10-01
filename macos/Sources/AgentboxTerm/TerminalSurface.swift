import AppKit
import SwiftTerm

final class TerminalSurface: TerminalView {
    var onDropFiles: (([URL]) -> Void)?

    override init(frame: CGRect, font: NSFont?) {
        super.init(frame: frame, font: font)
        // Mouse reporting off by default: Claude Code and tmux enable it, and
        // it swallows drag-selection entirely (copy then grays out). Without
        // it the terminal behaves like a regular one — drag selects, the
        // wheel scrolls the local buffer, and cmd+click still opens links.
        allowMouseReporting = false
        registerForDraggedTypes([.fileURL])
        installContextMenu()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        allowMouseReporting = false
        registerForDraggedTypes([.fileURL])
        installContextMenu()
    }

    private func installContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "复制", action: Selector(("copy:")), keyEquivalent: "c")
        menu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        menu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")
        self.menu = menu
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedURLs(sender)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    private func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] ?? []
        return objects
    }
}
