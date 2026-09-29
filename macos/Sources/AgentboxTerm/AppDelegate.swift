import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindowController?
    private var mainContent: MainViewController?
    private var pairingWindow: PairingWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard claimPrimaryInstance() else {
            NSApp.terminate(nil)
            return
        }
        buildMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        loadApplicationIcon()
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
        mainContent = content
        let window = NSWindow(contentViewController: content)
        window.title = "agentbox-client"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isRestorable = false
        window.setFrameAutosaveName("")
        window.backgroundColor = NativeTheme.content
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.resizeIncrements = NSSize(width: 1, height: 1)
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        window.collectionBehavior.insert(.fullScreenPrimary)
        content.installToolbar(in: window)
        let controller = NSWindowController(window: window)
        mainWindow = controller
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        window.setContentSize(
            NSSize(
                width: min(1280, visibleFrame.width - 80),
                height: min(820, visibleFrame.height - 80)
            )
        )
        window.center()
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func loadApplicationIcon() {
        if let image = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = image
            return
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }

    private func claimPrimaryInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != currentPID }) {
            existing.activate(options: [.activateAllWindows])
            return false
        }
        return true
    }
}
