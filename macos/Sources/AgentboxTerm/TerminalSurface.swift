import AppKit
import SwiftTerm

final class TerminalSurface: TerminalView {
    var onDropFiles: (([URL]) -> Void)?
    /// "刷新显示" in the context menu: re-align the remote size and redraw.
    var onRefreshDisplay: (() -> Void)?

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
        // Repaint the whole view on any change, which is what macOS does by
        // default: SwiftTerm opts out of that on Big Sur and newer so draw()
        // only gets the rows the terminal marked dirty. Everything else keeps
        // the pixels it had, and the leftovers of a wider earlier frame — a
        // full-width rule, a status block — stayed stranded on screen next to
        // the content that replaced them. Correctness over the saved drawing.
        disableFullRedrawOnAnyChanges = false
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

    /// Repaints everything when the view is resized.
    ///
    /// SwiftTerm only invalidates the rows the terminal marked dirty, and of
    /// its two resize paths only the `frame` setter also sets `needsDisplay`.
    /// Auto Layout goes through `setFrameSize`, which does not — so widening
    /// the view (hiding the sidebar, resizing the window) left the newly
    /// uncovered strip showing whatever had been drawn there before: pieces of
    /// an older frame stranded down the right-hand side, far from the text they
    /// belonged to.
    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized { needsDisplay = true }
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
        menu.addItem(.separator())
        let refresh = menu.addItem(withTitle: "刷新显示", action: #selector(refreshDisplay(_:)), keyEquivalent: "")
        refresh.target = self
        self.menu = menu
    }

    /// Escape hatch for a screen that drew short (blank bottom rows): the same
    /// re-alignment the terminal does on connect, on demand.
    @objc func refreshDisplay(_ sender: Any?) {
        onRefreshDisplay?()
    }

    // MARK: - Input method composition (CJK)

    /// What the input method is composing right now (pinyin, kana…). SwiftTerm
    /// ignores it and reports "nothing marked", so nothing appeared while
    /// typing Chinese until a word was committed. It is drawn here, locally,
    /// at the caret — never sent to the remote end. An earlier attempt sent the
    /// composition to the shell and erased it with backspaces, which leaked
    /// half-typed input into programs and was removed (f67c82d).
    private var markedText = NSAttributedString()
    private lazy var markedLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.drawsBackground = true
        label.isBordered = false
        label.isHidden = true
        label.lineBreakMode = .byClipping
        label.cell?.usesSingleLineMode = true
        addSubview(label)
        return label
    }()

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            markedText = attributed
        } else if let plain = string as? String {
            markedText = NSAttributedString(string: plain)
        } else {
            markedText = NSAttributedString()
        }
        showMarkedText()
    }

    override func unmarkText() {
        markedText = NSAttributedString()
        showMarkedText()
    }

    override func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    override func markedRange() -> NSRange {
        markedText.length > 0
            ? NSRange(location: 0, length: markedText.length)
            : NSRange(location: NSNotFound, length: 0)
    }

    override func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .backgroundColor]
    }

    /// The input method commits: drop the preview first, then send the text.
    /// Some input methods commit an attributed string, which SwiftTerm's
    /// insertText (NSString only) would silently drop.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = NSAttributedString()
        showMarkedText()
        if let attributed = string as? NSAttributedString {
            super.insertText(attributed.string as NSString, replacementRange: replacementRange)
        } else {
            super.insertText(string, replacementRange: replacementRange)
        }
    }

    /// Lays the composition over the cells at the caret, in the terminal's
    /// own font and colours, underlined the way macOS marks composing text.
    private func showMarkedText() {
        guard markedText.length > 0 else {
            markedLabel.isHidden = true
            markedLabel.stringValue = ""
            return
        }
        let text = NSMutableAttributedString(string: markedText.string, attributes: [
            .font: font,
            .foregroundColor: nativeForegroundColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: nativeForegroundColor,
        ])
        markedLabel.attributedStringValue = text
        markedLabel.backgroundColor = nativeBackgroundColor
        let caret = caretFrame
        let width = ceil(text.size().width) + 2
        let maxWidth = max(caret.width, bounds.width - caret.minX)
        markedLabel.frame = NSRect(
            x: caret.minX,
            y: caret.minY,
            width: min(width, maxWidth),
            height: max(caret.height, ceil(text.size().height))
        )
        // SwiftTerm puts its caret view back on top whenever the cursor comes
        // back into view, and the caret is a filled block over the very cell
        // the composition starts at — raise the composition above it, or the
        // first character being typed sits under the block.
        addSubview(markedLabel, positioned: .above, relativeTo: nil)
        markedLabel.isHidden = false
    }

    /// Keeps the candidate window just below the composition rather than at a
    /// stale caret position.
    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let anchor = markedText.length > 0 && !markedLabel.isHidden ? markedLabel.frame : caretFrame
        guard let window else { return .zero }
        return window.convertToScreen(convert(anchor, to: nil))
    }

    /// ⌘C copies the selection, handled here rather than left to the Edit menu.
    ///
    /// The menu route only works when the terminal is the first responder and
    /// SwiftTerm's own menu validation agrees; when either said otherwise the
    /// key did nothing at all and a visible selection could not be copied. The
    /// view knows whether it has a selection, so it answers for itself and
    /// leaves every other key equivalent alone.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "c",
              selectionActive,
              let text = getSelection(), !text.isEmpty else {
            return super.performKeyEquivalent(with: event)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    /// ⌘V with files or an image on the clipboard uploads them, the same as
    /// dropping them: files copied in Finder arrive as file URLs, a screenshot
    /// copied with ⌃⇧⌘4 arrives as image data with no text. Anything with text
    /// pastes as text, as before.
    override func paste(_ sender: Any) {
        let board = NSPasteboard.general
        let files = board.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if !files.isEmpty {
            onDropFiles?(files)
            return
        }
        if board.string(forType: .string) == nil, let image = Self.pastedImageFile(board) {
            onDropFiles?([image])
            return
        }
        super.paste(sender)
    }

    /// Writes clipboard image data to a temporary PNG so it can be uploaded
    /// like any dropped file.
    static func pastedImageFile(_ board: NSPasteboard) -> URL? {
        var png = board.data(forType: .png)
        if png == nil, let tiff = board.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            png = rep.representation(using: .png, properties: [:])
        }
        guard let png else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pasted-\(formatter.string(from: Date())).png")
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
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
