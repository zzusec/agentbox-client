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
                // release reaches the app); re-read the mode instead of
                // hardcoding true, in case it changed mid-gesture.
                DispatchQueue.main.async { self.applyMouseMode() }
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

    // MARK: - NSTextInputClient (marked-text support for CJK input methods)

    /// SwiftTerm's base implementation leaves `setMarkedText`/`unmarkText` empty
    /// and always returns `false` for `hasMarkedText`.  This breaks most CJK
    /// input methods: the composition window never appears, and the IME can
    /// re-submit previously-comitted text when the user backspaces to an empty
    /// line because it thinks the earlier composition was never torn down.
    ///
    /// The minimal fix below keeps a local `markedTextBuffer`, sends backspace
    /// to erase the old buffer, then sends the new buffer.  When `unmarkText`
    /// is called we erase the buffer so that the following `insertText` lands
    /// the final characters cleanly.
    private var markedTextBuffer: String = ""

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let newText: String
        if let s = string as? NSString {
            newText = s as String
        } else if let attr = string as? NSAttributedString {
            newText = attr.string
        } else {
            newText = ""
        }

        // Erase old marked text.
        for _ in 0..<markedTextBuffer.count {
            send([0x7f])
        }

        // Insert new marked text (if any).
        if !newText.isEmpty {
            send(txt: newText)
        }

        markedTextBuffer = newText
    }

    override func unmarkText() {
        for _ in 0..<markedTextBuffer.count {
            send([0x7f])
        }
        markedTextBuffer = ""
    }

    override func hasMarkedText() -> Bool {
        return !markedTextBuffer.isEmpty
    }

    override func markedRange() -> NSRange {
        guard !markedTextBuffer.isEmpty else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedTextBuffer.utf16.count)
    }
}
