import AppKit

/// The main window.
///
/// Its title bar is transparent and shared with a unified toolbar, and
/// double-clicking it did nothing: AppKit runs the title-bar double-click
/// action only for clicks that reach its own title bar view, and the toolbar
/// layered across the title bar takes them first. The window performs the
/// action itself instead, honouring the user's "double-click a window's title
/// bar to …" preference in System Settings.
final class MainWindow: NSWindow {
    /// Set when a double-click was handled here, so the matching mouse-up is
    /// not delivered to a view that never saw its mouse-down.
    private var swallowMouseUp = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown where event.clickCount == 2 && isTitleBarClick(event):
            swallowMouseUp = true
            performTitleBarDoubleClick()
            return
        case .leftMouseUp where swallowMouseUp:
            swallowMouseUp = false
            return
        default:
            super.sendEvent(event)
        }
    }

    /// True for a click in the strip above the content that did not land on
    /// a control — the traffic lights and toolbar buttons keep their own
    /// double-click behaviour.
    func isTitleBarClick(_ event: NSEvent) -> Bool {
        let point = event.locationInWindow
        guard point.y >= contentLayoutRect.maxY, point.y <= frame.height else { return false }
        guard let frameView = contentView?.superview else { return true }
        var view = frameView.hitTest(point)
        while let current = view, current !== frameView {
            if let field = current as? NSTextField {
                // The window title is a label; only an editable field counts.
                if field.isEditable { return false }
            } else if current is NSControl {
                return false
            }
            view = current.superview
        }
        return true
    }

    /// What System Settings › Desktop & Dock › "Double-click a window's title
    /// bar to" asks for. "Fill" (the macOS 15 default) and "Maximize" both
    /// zoom; the window delegate makes zoom fill the visible screen.
    func performTitleBarDoubleClick() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            performMiniaturize(nil)
        case "None":
            break
        default:
            performZoom(nil)
        }
    }
}
