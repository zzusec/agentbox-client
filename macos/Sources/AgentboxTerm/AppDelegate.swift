import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindowController?
    private var pairingWindow: PairingWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        buildMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        UpdateManager.shared.start()
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

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu

        appMenu.addItem(
            withTitle: "关于 agentbox-client",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())

        let checkItem = NSMenuItem(
            title: "检查更新…",
            action: #selector(UpdateManager.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkItem.target = UpdateManager.shared
        appMenu.addItem(checkItem)

        let automaticItem = NSMenuItem(
            title: "自动检查并准备更新",
            action: #selector(UpdateManager.toggleAutomatic(_:)),
            keyEquivalent: ""
        )
        automaticItem.target = UpdateManager.shared
        UpdateManager.shared.applyMenuState(automaticItem)
        appMenu.addItem(automaticItem)
        appMenu.addItem(.separator())

        appMenu.addItem(
            withTitle: "退出 agentbox-client",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
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
        controller.focusCode()
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
        window.title = "agentbox-client"
        window.contentViewController = content
        window.minSize = NSSize(width: 900, height: 600)
        let controller = NSWindowController(window: window)
        mainWindow = controller
        controller.showWindow(nil)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}
