import AppKit
import SwiftTerm

final class TerminalSurface: TerminalView {
    var onDropFiles: (([URL]) -> Void)?

    private var mouseMonitor: Any?
    /// True while a ⇧-drag selection gesture is in flight (smart mode): mouse
    /// events are withheld from the TUI app for the whole gesture.
    private var mouseGestureBypassed = false

    override init(frame: CGRect, font: NSFont?) {
        super.init(frame: frame, font: font)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        applyMouseMode()
        registerForDraggedTypes([.fileURL])
        installContextMenu()
    }

    /// Applies the three-state mouse reporting preference: "off" never reports
    /// (drag always selects locally — the default so copy keeps working), "on"
    /// always reports when the app asked for mouse, "smart" reports but the
    /// event monitor below falls back to selection while ⇧ is held.
    func applyMouseMode() {
        allowMouseReporting = TerminalThemeManager.mouseMode != .off
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMouseMonitor()
        } else {
            removeMouseMonitor()
        }
    }

    /// SwiftTerm's mouseDown/Dragged/Up are not open for override, so the ⇧
    /// bypass hooks one level above: a local event monitor flips
    /// `allowMouseReporting` before the event reaches SwiftTerm. The flag
    /// stays set until mouseUp so the entire drag selects instead of reporting.
    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            guard TerminalThemeManager.mouseMode == .smart else { return event }
            if event.type == .leftMouseDown {
                self.mouseGestureBypassed = event.modifierFlags.contains(.shift)
            }
            let suppress = self.mouseGestureBypassed
            self.allowMouseReporting = !suppress
            if event.type == .leftMouseUp, suppress {
                // The up event was dispatched with reporting off (no stray
                // release reaches the app); restore for the next gesture.
                DispatchQueue.main.async { self.allowMouseReporting = true }
                self.mouseGestureBypassed = false
            }
            return event
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
    }

    deinit {
        removeMouseMonitor()
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
