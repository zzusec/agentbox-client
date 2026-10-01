import AppKit
import Foundation

final class AppHTTPFixture: URLProtocol {
    static let lock = NSLock()
    static var pending: [AppHTTPFixture] = []
    static let alphaID = "app-smoke-alpha-\(UUID().uuidString)"
    static let betaID = "app-smoke-beta-\(UUID().uuidString)"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        precondition(request.url?.host == "agentbox-app-fixture.invalid", "Unexpected network request")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-app-token")
        let path = request.url!.path
        if path == "/api/sessions" {
            respond([
                ["id": Self.alphaID, "name": "Alpha", "agent": "claude", "account_id": "synthetic", "account_label": "Fixture"],
                ["id": Self.betaID, "name": "Beta", "agent": "claude", "account_id": "synthetic", "account_label": "Fixture"],
            ])
        } else if path == "/api/sessions/\(Self.alphaID)/projects" {
            Self.lock.lock()
            Self.pending.append(self)
            Self.lock.unlock()
        } else if path == "/api/sessions/\(Self.betaID)/projects" {
            respond([["id": "beta-project", "name": "Beta project", "path": "/workspace/Beta project"]])
        } else {
            preconditionFailure("Unexpected API path: \(path)")
        }
    }

    override func stopLoading() {}

    func respond(_ value: Any, status: Int = 200) {
        let data = try! JSONSerialization.data(withJSONObject: value)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: data)
        client!.urlProtocolDidFinishLoading(self)
    }

    static var hasPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pending.isEmpty
    }

    static func releaseAlpha(status: Int = 200) {
        lock.lock()
        let requests = pending
        pending.removeAll()
        lock.unlock()
        for request in requests {
            if status == 200 {
                request.respond([["id": "alpha-project", "name": "Alpha project", "path": "/workspace/Alpha project"]])
            } else {
                request.respond(["error": "Synthetic stale failure"], status: status)
            }
        }
    }
}

@main
struct AppSmokeChecks {
    @MainActor
    static func views(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { views(in: $0) }
    }

    @MainActor
    static func waitFor(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        preconditionFailure(message)
    }

    @MainActor
    static func themeChecks() {
        let defaults = UserDefaults.standard
        let customKey = "agentbox.terminal.custom-scheme"
        let schemeKey = "agentbox.terminal.scheme"
        let familyKey = "agentbox.terminal.font-family"
        let mouseKey = "agentbox.terminal.mouse-mode"
        let priorCustom = defaults.string(forKey: customKey)
        let priorScheme = defaults.string(forKey: schemeKey)
        let priorFamily = defaults.string(forKey: familyKey)
        let priorMouse = defaults.string(forKey: mouseKey)
        defer {
            if let priorCustom {
                defaults.set(priorCustom, forKey: customKey)
            } else {
                defaults.removeObject(forKey: customKey)
            }
            if let priorScheme {
                defaults.set(priorScheme, forKey: schemeKey)
            } else {
                defaults.removeObject(forKey: schemeKey)
            }
            if let priorFamily {
                defaults.set(priorFamily, forKey: familyKey)
            } else {
                defaults.removeObject(forKey: familyKey)
            }
            if let priorMouse {
                defaults.set(priorMouse, forKey: mouseKey)
            } else {
                defaults.removeObject(forKey: mouseKey)
            }
        }

        // Hex normalization: 3/6 digits with optional '#', everything else nil.
        precondition(TerminalThemeManager.normalizedHex("#0C0C0C") == "#0C0C0C")
        precondition(TerminalThemeManager.normalizedHex("0c0c0c") == "#0C0C0C")
        precondition(TerminalThemeManager.normalizedHex("#aBc") == "#AABBCC")
        precondition(TerminalThemeManager.normalizedHex("abc") == "#AABBCC")
        precondition(TerminalThemeManager.normalizedHex("#ab") == nil)
        precondition(TerminalThemeManager.normalizedHex("#abcd") == nil)
        precondition(TerminalThemeManager.normalizedHex("#zzzzzz") == nil)
        precondition(TerminalThemeManager.normalizedHex("#12345") == nil)
        precondition(TerminalThemeManager.normalizedHex("") == nil)

        // Custom scheme: create from preset, round-trip through defaults,
        // mutate, and select.
        defaults.removeObject(forKey: customKey)
        defaults.set(TerminalThemeManager.schemes[0].id, forKey: schemeKey)
        // Placeholder card must carry the fixed custom id, never the preset's
        // (a duplicate id would double-match selection in the card grid).
        precondition(TerminalThemeManager.choices.last?.id == TerminalThemeManager.customSchemeID)
        let source = TerminalThemeManager.schemes[2]
        TerminalThemeManager.createCustom(from: source)
        precondition(defaults.string(forKey: schemeKey) == TerminalThemeManager.customSchemeID)
        var stored = TerminalThemeManager.customScheme
        precondition(stored?.id == TerminalThemeManager.customSchemeID)
        precondition(stored?.background == source.background)
        precondition(stored?.ansi.count == 16)
        precondition(TerminalThemeManager.current.id == TerminalThemeManager.customSchemeID)
        precondition(TerminalThemeManager.choices.last?.id == TerminalThemeManager.customSchemeID)
        TerminalThemeManager.updateCustom { $0 = $0.with(background: "#112233") }
        stored = TerminalThemeManager.customScheme
        precondition(stored?.background == "#112233")
        precondition(TerminalThemeManager.isLight(hex: "#FFFFFF"))
        precondition(!TerminalThemeManager.isLight(hex: "#000000"))

        // Font family: unknown ids fall back to the first installed family.
        precondition(TerminalThemeManager.installedFontFamilies.contains { $0.id == "menlo" })
        defaults.set("not-a-font", forKey: familyKey)
        precondition(TerminalThemeManager.fontFamily.id == "menlo")
        precondition(TerminalThemeManager.font().familyName != nil)
        defaults.set("monaco", forKey: familyKey)
        precondition(TerminalThemeManager.fontFamily.id == "monaco")

        // Mouse mode: default off, three states persist, surface applies live.
        precondition(TerminalThemeManager.mouseMode == .off)
        TerminalThemeManager.update(mouseMode: .smart)
        precondition(TerminalThemeManager.mouseMode == .smart)
        TerminalThemeManager.update(mouseMode: .on)
        precondition(TerminalThemeManager.mouseMode == .on)
        let surface = TerminalSurface(frame: NSRect(x: 0, y: 0, width: 400, height: 300), font: nil)
        precondition(surface.allowMouseReporting, "on mode must report mouse")
        TerminalThemeManager.update(mouseMode: .off)
        surface.applyMouseMode()
        precondition(!surface.allowMouseReporting, "off mode must select locally")
    }

    @MainActor
    static func check() async throws {
        themeChecks()
        precondition(URLProtocol.registerClass(AppHTTPFixture.self))
        let client = AgentboxClient(server: URL(string: "https://agentbox-app-fixture.invalid")!, user: "synthetic-app-user", token: "synthetic-app-token")
        let controller = MainViewController(client: client)
        let window = NSWindow(contentViewController: controller)
        window.title = "Agentbox App regression — synthetic data"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        controller.installToolbar(in: window)
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.center()
        window.makeKeyAndOrderFront(nil)
        let sidebar = controller.children.compactMap { $0 as? SidebarViewController }.first!
        let table = views(in: sidebar.view).compactMap { $0 as? NSTableView }.first!
        let picker = views(in: sidebar.view).compactMap { $0 as? NSPopUpButton }.first!
        try await waitFor("Initial workspace request missing") { AppHTTPFixture.hasPending }
        precondition(picker.numberOfItems == 2)
        let workspaces = try await client.workspaces()
        let alpha = workspaces.first { $0.id == AppHTTPFixture.alphaID }!
        let beta = workspaces.first { $0.id == AppHTTPFixture.betaID }!
        picker.selectItem(at: 1)
        sidebar.onSelectWorkspace?(beta)
        try await waitFor("Beta projects missing") { table.numberOfRows == 1 }
        AppHTTPFixture.releaseAlpha()
        try await Task.sleep(nanoseconds: 150_000_000)
        let cell = sidebar.tableView(table, viewFor: table.tableColumns.first, row: 0)!
        precondition(views(in: cell).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Beta project" }, "Stale Alpha response replaced Beta projects")

        picker.selectItem(at: 0)
        sidebar.onSelectWorkspace?(alpha)
        precondition(table.numberOfRows == 0, "Previous workspace projects remained clickable while loading")
        try await waitFor("Second Alpha request missing") { AppHTTPFixture.hasPending }
        picker.selectItem(at: 1)
        sidebar.onSelectWorkspace?(beta)
        try await waitFor("Beta reload missing") { table.numberOfRows == 1 }
        AppHTTPFixture.releaseAlpha(status: 409)
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(table.numberOfRows == 1, "Stale failure cleared current workspace projects")
        precondition(!views(in: sidebar.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Synthetic stale failure") })

        let components = URLComponents(url: client.terminalURL(workspace: beta, project: "中文 + API")!, resolvingAgainstBaseURL: false)!
        precondition(components.scheme == "wss")
        precondition(components.queryItems!.contains(URLQueryItem(name: "project", value: "中文 + API")))
        precondition(components.queryItems!.contains(URLQueryItem(name: "mode", value: "agent")))

        for width in [720, 1280] {
            window.setContentSize(NSSize(width: width, height: 820))
            controller.view.layoutSubtreeIfNeeded()
            precondition(sidebar.view.frame.width >= 249.5 && sidebar.view.frame.width <= 340.5)
        }
        let toolbarItem = window.toolbar!.items.first!
        precondition(NSApp.sendAction(toolbarItem.action!, to: toolbarItem.target, from: toolbarItem))
        precondition(sidebar.view.isHidden)
        precondition(NSApp.sendAction(toolbarItem.action!, to: toolbarItem.target, from: toolbarItem))
        precondition(!sidebar.view.isHidden)
        let choose = views(in: sidebar.view).compactMap { $0 as? NSButton }.first { $0.title == "选择目录" }!
        precondition(choose.acceptsFirstMouse(for: nil))
        choose.performClick(nil)
        try await waitFor("Directory chooser was not presented as a sheet") { window.attachedSheet != nil }
        (window.attachedSheet as! NSOpenPanel).cancel(nil)
        try await waitFor("Directory chooser did not close") { window.attachedSheet == nil }
        precondition(UserDefaults.standard.object(forKey: "agentbox.local-root.\(beta.id)") == nil, "Cancel changed local directory preferences")
        if let output = ProcessInfo.processInfo.environment["AGENTBOX_APP_SMOKE_IMAGE"] {
            controller.view.layoutSubtreeIfNeeded()
            let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds)!
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
        }
        print("PASS: theme/scheme/font/mouse settings, native workspace loading, stale responses/errors, loading isolation, terminal URLs, sidebar resizing/toggle and directory cancellation")
        if ProcessInfo.processInfo.environment["AGENTBOX_APP_SMOKE_KEEP_OPEN"] == "1" {
            try await Task.sleep(nanoseconds: 120_000_000_000)
        }
        window.close()
    }

    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try await check()
                application.terminate(nil)
            } catch {
                fputs("App smoke failed: \(error)\n", stderr)
                exit(1)
            }
        }
        application.run()
    }
}
