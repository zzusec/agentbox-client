import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindowController?
    private var pairingWindow: PairingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let saved = savedConnection() {
            showMain(saved)
        } else {
            showPairing()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func savedConnection() -> SavedConnection? {
        guard let server = UserDefaults.standard.string(forKey: "agentbox.server"),
              let user = UserDefaults.standard.string(forKey: "agentbox.user"),
              URL(string: server) != nil,
              let token = KeychainStore.loadToken(user: user) else {
            return nil
        }
        return SavedConnection(server: server, user: user, token: token)
    }

    private func showPairing() {
        let controller = PairingWindowController()
        controller.onConnected = { [weak self] connection in
            self?.pairingWindow = nil
            self?.showMain(connection)
        }
        pairingWindow = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func showMain(_ connection: SavedConnection) {
        guard let server = URL(string: connection.server) else { return }
        let client = AgentboxClient(server: server, user: connection.user, token: connection.token)
        let content = MainViewController(client: client)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agentbox Term"
        window.contentViewController = content
        window.minSize = NSSize(width: 900, height: 600)
        let controller = NSWindowController(window: window)
        mainWindow = controller
        controller.showWindow(nil)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}
