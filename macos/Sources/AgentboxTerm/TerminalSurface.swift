import AppKit
import SwiftTerm

final class TerminalSurface: TerminalView {
    var onDropFiles: (([URL]) -> Void)?

    /// While a selection gesture with Shift/Option held is in flight, mouse
    /// reporting to the TUI is suppressed: Claude Code and tmux enable mouse
    /// reporting, which would otherwise swallow drag-selection entirely.
    /// SwiftTerm's mouse handlers are not open, so the bypass is done with a
    /// local event monitor that flips allowMouseReporting before the events
    /// reach the view.
    private var selectionGestureBypass = false
    private var savedAllowMouseReporting = true
    private var eventMonitor: Any?

    override init(frame: CGRect, font: NSFont?) {
        super.init(frame: frame, font: font)
        registerForDraggedTypes([.fileURL])
        installContextMenu()
        installMouseBypass()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        installContextMenu()
        installMouseBypass()
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    private func installContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "复制", action: Selector(("copy:")), keyEquivalent: "c")
        menu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        menu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")
        self.menu = menu
    }

    private func installMouseBypass() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            switch event.type {
            case .leftMouseDown:
                if !event.modifierFlags.intersection([.shift, .option]).isEmpty {
                    selectionGestureBypass = true
                    savedAllowMouseReporting = allowMouseReporting
                    allowMouseReporting = false
                }
            case .leftMouseDragged:
                if selectionGestureBypass {
                    allowMouseReporting = false
                }
            case .leftMouseUp:
                if selectionGestureBypass {
                    allowMouseReporting = savedAllowMouseReporting
                    selectionGestureBypass = false
                }
            default:
                break
            }
            return event
        }
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
