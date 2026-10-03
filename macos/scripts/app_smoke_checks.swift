import AppKit
import Foundation
import WebKit

final class AppHTTPFixture: URLProtocol {
    static let lock = NSLock()
    static var pending: [AppHTTPFixture] = []
    static let alphaID = "app-smoke-alpha-\(UUID().uuidString)"
    static let betaID = "app-smoke-beta-\(UUID().uuidString)"
    /// What the fixture's server claims its clock and timezone are.
    static let serverZone = "Asia/Shanghai"
    static let serverSkew: TimeInterval = 3 * 3600

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        precondition(request.url?.host == "agentbox-app-fixture.invalid", "Unexpected network request")
        let path = request.url!.path
        // Terminal sockets carry the token in the query, not in a header, and
        // no fixture can complete a WebSocket upgrade: the tab-strip check only
        // needs the tabs to render, so a refusal is enough.
        if path.hasSuffix("/term") {
            respond(["error": "no terminal in the fixture"], status: 503)
            return
        }
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-app-token")
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
        } else if path == "/api/me" {
            // The sidebar clock reads the server's time, so the fixture answers
            // with an instant deliberately hours away from the runner's: a label
            // showing this Mac's clock instead would no longer match.
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(identifier: Self.serverZone)!
            formatter.formatOptions = [.withInternetDateTime]
            respond([
                "user": "synthetic-app-user",
                "role": "user",
                "timezone": Self.serverZone,
                "now": formatter.string(from: Date().addingTimeInterval(Self.serverSkew)),
            ])
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
    static func waitFor(_ message: String, seconds: Double = 5, _ condition: () -> Bool) async throws {
        for _ in 0..<Int(seconds * 50) {
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
        // Start from a clean slate (a real user's preferences — or leftovers
        // from an aborted earlier run, since precondition traps skip defer) —
        // then restore whatever was there.
        defaults.removeObject(forKey: customKey)
        defaults.removeObject(forKey: schemeKey)
        defaults.removeObject(forKey: familyKey)
        defaults.removeObject(forKey: mouseKey)
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

        // Default scheme: the Apple Terminal "Clear Dark" palette extracted
        // from this Mac's terminal profile. Guard the exact values, since a
        // typo here would silently change what every user sees.
        precondition(TerminalThemeManager.defaultSchemeID == "clear-dark")
        precondition(TerminalThemeManager.current.id == TerminalThemeManager.defaultSchemeID)
        let preset = TerminalThemeManager.schemes.first { $0.id == TerminalThemeManager.defaultSchemeID }!
        precondition(preset.background == "#191D27")
        precondition(preset.foreground == "#E0E0E0")
        precondition(preset.cursor == "#E0E0E0")
        precondition(
            preset.ansi == ["#35424C", "#B45648", "#6CAA71", "#C4AC62",
                            "#6D96B4", "#BD7BCD", "#7CCBCD", "#DEE5EB",
                            "#465C6D", "#DF6C5A", "#79BE7E", "#E5C872",
                            "#67B5ED", "#D389E5", "#84DDE0", "#E5EFF5"],
            "Clear Dark palette drifted: \(preset.ansi)"
        )
        precondition(!preset.isLight, "Clear Dark is a dark scheme")
        // Every preset must carry a full, well-formed 16-slot palette.
        for scheme in TerminalThemeManager.schemes {
            precondition(scheme.ansi.count == 16, "\(scheme.id) has \(scheme.ansi.count) ANSI slots")
            precondition(
                ([scheme.background, scheme.foreground, scheme.cursor] + scheme.ansi)
                    .allSatisfy { TerminalThemeManager.normalizedHex($0) != nil },
                "\(scheme.id) has a malformed colour"
            )
        }

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

        // Font family: the default is Monaco, and an unknown stored id falls
        // back to it rather than to whatever is listed first.
        let installed = TerminalThemeManager.installedFontFamilies
        precondition(
            installed.contains { $0.id == TerminalThemeManager.defaultFontFamilyID },
            "the default family must be installed on this machine"
        )
        precondition(TerminalThemeManager.defaultFontFamilyID == "monaco")
        defaults.set("not-a-font", forKey: familyKey)
        precondition(TerminalThemeManager.fontFamily.id == TerminalThemeManager.defaultFontFamilyID)
        precondition(TerminalThemeManager.font().familyName != nil)
        defaults.set("monaco", forKey: familyKey)
        precondition(TerminalThemeManager.fontFamily.id == "monaco")

        // Mouse mode: default off, two states persist, surface applies live.
        precondition(TerminalThemeManager.mouseMode == .off)
        // The old third mode is read as 开启, which now does what it did.
        defaults.set(TerminalMouseMode.legacySmart, forKey: "agentbox.terminal.mouse-mode")
        precondition(TerminalThemeManager.mouseMode == .on, "a stored 智能 must read as 开启")
        TerminalThemeManager.update(mouseMode: .on)
        precondition(TerminalThemeManager.mouseMode == .on)
        precondition(TerminalThemeManager.webTerminalSettings()["mouse"] as? String == "on",
                     "the page must be told the mouse mode")
        TerminalThemeManager.update(mouseMode: .off)
        precondition(TerminalThemeManager.webTerminalSettings()["mouse"] as? String == "off")
    }

    /// Drives the settings sheet wiring: card selection creates/selects the
    /// custom scheme and reveals the editor, hex fields commit through the
    /// delegate path, the font popup and mouse segment update the manager.
    @MainActor
    static func settingsSheetChecks() {
        let defaults = UserDefaults.standard
        let keys = [
            "agentbox.terminal.scheme",
            "agentbox.terminal.custom-scheme",
            "agentbox.terminal.font-family",
            "agentbox.terminal.mouse-mode",
        ]
        let prior = keys.map { defaults.string(forKey: $0) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        defer {
            for (key, value) in zip(keys, prior) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let controller = TerminalSettingsViewController()
        controller.loadViewIfNeeded()
        let all = views(in: controller.view)
        let cards = all.compactMap { $0 as? SchemeCardView }
        precondition(cards.count == 8, "expected 7 presets + 1 custom card")
        precondition(cards.last!.scheme.id == TerminalThemeManager.customSchemeID)
        let editor = all.compactMap { $0 as? CustomSchemeEditorView }.first!
        precondition(editor.isHidden, "editor must stay hidden while a preset is selected")

        // Clicking the custom card creates the scheme from the current preset.
        cards.last!.onSelect?()
        precondition(TerminalThemeManager.customScheme != nil, "custom card click must create the scheme")
        precondition(TerminalThemeManager.current.id == TerminalThemeManager.customSchemeID)
        precondition(!editor.isHidden, "editor must appear once the custom scheme is selected")

        // Hex field commits through the live-editing delegate path.
        let fields = all.compactMap { $0 as? NSTextField }.filter { $0.placeholderString == "#RRGGBB" }
        precondition(fields.count == 19, "expected background/foreground/cursor + 16 ANSI fields, got \(fields.count)")
        let backgroundField = fields.first { $0.tag == 0 }!
        backgroundField.stringValue = "00ff00"
        editor.controlTextDidChange(Notification(name: NSTextField.textDidChangeNotification, object: backgroundField))
        precondition(TerminalThemeManager.customScheme?.background == "#00FF00")

        // Selecting a preset hides the editor again.
        cards.first!.onSelect?()
        precondition(TerminalThemeManager.current.id != TerminalThemeManager.customSchemeID)
        precondition(editor.isHidden)
        cards.last!.onSelect?()

        // Mouse segment drives TerminalThemeManager.mouseMode.
        let segments = all.compactMap { $0 as? NSSegmentedControl }
        let mouseSegment = segments.first {
            $0.segmentCount == 2 && $0.label(forSegment: 1) == "开启"
        }
        precondition(mouseSegment != nil, "mouse mode segment missing")
        mouseSegment!.selectedSegment = 1
        precondition(NSApp.sendAction(mouseSegment!.action!, to: mouseSegment!.target, from: mouseSegment!))
        precondition(TerminalThemeManager.mouseMode == .on)

        // Font popup drives the font family choice. Two popups live in the
        // sheet (the editor's "copy preset" one included), so tell them apart
        // by the family ids they carry.
        let popup = all.compactMap { $0 as? NSPopUpButton }.first {
            $0.itemArray.contains { ($0.representedObject as? String) == "menlo" }
        }!
        precondition(popup.itemArray.count == TerminalThemeManager.installedFontFamilies.count)
        let monaco = popup.itemArray.firstIndex {
            ($0.representedObject as? String) == "monaco"
        }
        if let monaco {
            popup.selectItem(at: monaco)
            precondition(NSApp.sendAction(popup.action!, to: popup.target, from: popup))
            precondition(TerminalThemeManager.fontFamily.id == "monaco")
        }

        if let output = ProcessInfo.processInfo.environment["AGENTBOX_APP_SMOKE_SETTINGS_IMAGE"] {
            controller.view.layoutSubtreeIfNeeded()
            let scroll = all.compactMap { $0 as? NSScrollView }.first!
            let document = scroll.documentView!
            document.layoutSubtreeIfNeeded()
            let bitmap = document.bitmapImageRepForCachingDisplay(in: document.bounds)!
            document.cacheDisplay(in: document.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
        }
    }

    /// Launch command, typed local directory, sync events and the status bar:
    /// the parts of the window that report what sync is doing.
    @MainActor
    static func launchAndSyncEventChecks() {
        // Older servers send no launch fields; current ones do.
        let legacy = try! JSONDecoder().decode(
            RemoteProject.self,
            from: Data(#"{"id":"p","name":"n","path":"/w/n"}"#.utf8)
        )
        precondition(legacy.command.isEmpty && legacy.agent.isEmpty && !legacy.customCommand)
        let current = try! JSONDecoder().decode(
            RemoteProject.self,
            from: Data(#"{"id":"p","name":"n","path":"/w/n","agent":"codex","command":"codex --yolo","default_command":"codex --yolo","custom_command":false}"#.utf8)
        )
        precondition(current.agent == "codex" && current.command == "codex --yolo")
        precondition(ProjectLaunch.defaultCommand(for: "claude") == "claude --dangerously-skip-permissions")
        precondition(ProjectLaunch.defaultCommand(for: "codex") == "codex --yolo")

        // New-project sheet on an instance that carries both tools.
        let sheet = NewProjectViewController()
        sheet.localRoot = "/tmp/agentbox-root"
        sheet.availableAgents = ["claude", "codex"]
        sheet.defaultAgent = "claude"
        sheet.loadViewIfNeeded()
        let all = views(in: sheet.view)
        func field(_ id: NewProjectViewController.Field) -> NSView? {
            all.first { $0.identifier?.rawValue == id.rawValue }
        }
        guard let nameField = field(.name) as? NSTextField,
              let dirField = field(.localDir) as? NSTextField,
              let agentPopup = field(.agent) as? NSPopUpButton,
              let commandField = field(.command) as? NSTextField else {
            preconditionFailure("new-project sheet is missing name, directory, tool or command")
        }
        func changed(_ field: NSTextField) {
            sheet.controlTextDidChange(Notification(name: NSTextField.textDidChangeNotification, object: field))
        }
        func pick(_ index: Int) {
            agentPopup.selectItem(at: index)
            _ = agentPopup.target?.perform(agentPopup.action, with: agentPopup)
        }
        precondition(dirField.isEditable, "the local directory must accept typing")
        precondition(agentPopup.isEnabled && agentPopup.numberOfItems == 2)
        precondition(commandField.stringValue == "claude --dangerously-skip-permissions")

        nameField.stringValue = "demo"
        changed(nameField)
        precondition(dirField.stringValue == "/tmp/agentbox-root/demo")
        // Switching tools swaps an untouched default …
        pick(1)
        precondition(commandField.stringValue == "codex --yolo", "got \(commandField.stringValue)")
        var draft = sheet.makeDraft()!
        precondition(draft.agent == "codex" && draft.command == nil, "a default command is not an override")
        // … but never a command the user typed.
        commandField.stringValue = "codex --yolo --search"
        pick(0)
        precondition(commandField.stringValue == "codex --yolo --search", "a typed command must survive a tool switch")
        draft = sheet.makeDraft()!
        precondition(draft.agent == "claude" && draft.command == "codex --yolo --search")

        // A typed directory expands ~ and becomes the override; typing the
        // default back clears it; a relative path is refused.
        dirField.stringValue = "~/code/demo"
        changed(dirField)
        precondition(sheet.customDir == NSHomeDirectory() + "/code/demo", "got \(String(describing: sheet.customDir))")
        dirField.stringValue = "/tmp/agentbox-root/demo"
        changed(dirField)
        precondition(sheet.customDir == nil, "typing the default must clear the override")
        dirField.stringValue = "relative/dir"
        changed(dirField)
        precondition(sheet.makeDraft() == nil, "a relative directory must be refused")

        // The watcher's JSON lines decode; anything else is ignored.
        let lines = [
            #"{"type":"progress","project":"demo","phase":"download","path":"big.bin","index":1,"total":2,"bytes":512,"total_bytes":1024,"percent":50}"#,
            #"{"type":"transfer","project":"demo","phase":"download","path":"big.bin","bytes":1024,"duration_ms":340}"#,
            #"{"type":"status","project":"demo","in_sync":true,"applied":2,"duration_ms":420,"at":"2026-10-02T04:00:00Z"}"#,
            #"{"type":"log","message":"ignored"}"#,
        ]
        let events = lines.compactMap { SyncEvent.decode(Data($0.utf8)) }
        precondition(events.count == 3, "expected three events, got \(events.count)")

        let client = AgentboxClient(server: URL(string: "https://agentbox-events.invalid")!, user: "u", token: "t")
        let controller = MainViewController(client: client)
        controller.loadViewIfNeeded()
        controller.handleSyncEvent(events[0])
        precondition(controller.isSyncing && controller.syncFraction == 0.5, "progress must drive the bar")
        precondition(controller.syncStatusText.contains("big.bin") && controller.syncStatusText.contains("50%"))
        controller.handleSyncEvent(events[1])
        precondition(controller.syncStatusText.contains("big.bin") && controller.syncStatusText.contains("340ms"),
                     "a transfer must say what moved and how long it took: \(controller.syncStatusText)")
        controller.handleSyncEvent(events[2])
        precondition(!controller.isSyncing, "a status settles the bar")
        precondition(controller.syncStatusText.hasPrefix("✓ demo：同步了 2 个变更"), "got \(controller.syncStatusText)")
        precondition(controller.recentTransfers.count == 1)

        func status(_ project: String, inSync: Bool, conflicts: [String]? = nil, error: String? = nil) -> SyncStatus {
            SyncStatus(project: project, inSync: inSync, applied: 0, conflicts: conflicts, error: error,
                       durationMS: 10, at: "2026-10-02T04:00:00Z")
        }
        let agree = MainViewController.aggregateState(statuses: ["a": status("a", inSync: true)], active: [:])
        precondition(agree?.text == "两端一致")
        let two = MainViewController.aggregateState(
            statuses: ["a": status("a", inSync: true), "b": status("b", inSync: true)], active: [:]
        )
        precondition(two?.text == "两端一致（2 个项目）")
        let conflict = MainViewController.aggregateState(
            statuses: ["a": status("a", inSync: true), "b": status("b", inSync: false, conflicts: ["x.go"], error: "冲突")],
            active: [:]
        )
        precondition(conflict?.text == "有冲突，已暂停")
        let failed = MainViewController.aggregateState(
            statuses: ["a": status("a", inSync: false, error: "疑似误删，已暂停同步")], active: [:]
        )
        precondition(failed?.text == "未同步")
        precondition(MainViewController.aggregateState(statuses: [:], active: [:]) == nil)

        // A dropped file's upload reports a percentage, then size and time.
        func note(_ state: UploadProgressNote.State) -> Notification {
            Notification(name: UploadProgressNote.name, object: nil,
                         userInfo: ["file": "a.zip", "project": "demo", "state": state])
        }
        controller.handleUploadNote(note(.running(fraction: 0.25)))
        precondition(controller.isSyncing && controller.syncFraction == 0.25 && controller.syncStatusText.contains("25%"))
        controller.handleUploadNote(note(.finished(bytes: 2048, milliseconds: 1500)))
        precondition(!controller.isSyncing && controller.syncStatusText.contains("1.5s"), "got \(controller.syncStatusText)")

        // Hiding the sidebar removes it from the split view, so no strip of
        // window background is left framing the terminal; showing restores it.
        precondition(controller.isSidebarVisible)
        _ = controller.perform(NSSelectorFromString("toggleSidebar:"), with: nil)
        precondition(!controller.isSidebarVisible, "the sidebar must leave the split view when hidden")
        precondition(
            views(in: controller.view).compactMap { $0 as? NSSplitView }.first?.arrangedSubviews.count == 1,
            "only the terminal may remain in the split view"
        )
        _ = controller.perform(NSSelectorFromString("toggleSidebar:"), with: nil)
        precondition(controller.isSidebarVisible, "showing the sidebar must put it back")

        // Shell tabs: their own mode, tab ID and title; the agent tab is unchanged.
        let shellWorkspace = try! JSONDecoder().decode(
            Workspace.self,
            from: Data(#"{"id":"w","name":"w","agent":"claude","account_id":"a","account_label":"l"}"#.utf8)
        )
        let shellURL = URLComponents(
            url: client.terminalURL(workspace: shellWorkspace, project: "demo", kind: .shell(id: "ab12", index: 2))!,
            resolvingAgainstBaseURL: false
        )!
        precondition(shellURL.queryItems!.contains(URLQueryItem(name: "mode", value: "shell")))
        precondition(shellURL.queryItems!.contains(URLQueryItem(name: "tab", value: "ab12")))
        precondition(shellURL.queryItems!.contains(URLQueryItem(name: "project", value: "demo")))
        let shellTab = TerminalViewController(
            client: client, workspace: shellWorkspace,
            project: RemoteProject(id: "p", name: "demo", path: "/w/demo"),
            kind: .shell(id: "ab12", index: 2)
        )
        precondition(shellTab.tabTitle == "demo · 终端 2")
        precondition(shellTab.paneKey != "w/demo", "a shell tab must not take the agent tab's key")
        tabStripChecks(client: client, workspace: shellWorkspace)
        appMenuChecks()
        serverVersionTriggerChecks()
        // Uploads report progress as text in the banner; a progress bar over
        // the terminal was one more thing covering the output.
        let uploadTab = TerminalViewController(
            client: client, workspace: shellWorkspace,
            project: RemoteProject(id: "p-upload", name: "demo", path: "/w/demo")
        )
        uploadTab.loadViewIfNeeded()
        precondition(views(in: uploadTab.view).compactMap { $0 as? NSProgressIndicator }.isEmpty,
                     "the terminal must not carry an upload progress bar")

        // Right-click offers a new shell and the AI session; double-click opens.
        let menuSidebar = SidebarViewController()
        menuSidebar.loadViewIfNeeded()
        let menu = NSMenu()
        menuSidebar.populate(menu, with: RemoteProject(id: "p", name: "demo", path: "/w/demo"))
        let titles = menu.items.map(\.title)
        precondition(titles.contains("打开终端") && titles.contains("打开 AI 会话"), "menu: \(titles)")
        let projectTable = views(in: menuSidebar.view).compactMap { $0 as? NSTableView }.first!
        precondition(projectTable.doubleAction != nil, "double-clicking a project must open it")

        // ⌘V with an image and no text becomes a PNG file to upload.
        let board = NSPasteboard(name: NSPasteboard.Name("agentbox.smoke.paste"))
        board.clearContents()
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        board.writeObjects([image])
        guard let pasted = WebTerminalView.pastedImageFile(board) else {
            preconditionFailure("an image on the clipboard must become a file")
        }
        precondition(pasted.pathExtension == "png" && FileManager.default.fileExists(atPath: pasted.path))
        try? FileManager.default.removeItem(at: pasted)

        // A tab offers reconnecting and a new shell; double-click reconnects.
        let chip = TerminalTabChip(title: "demo", path: "/w/demo", state: .error)
        var chipReconnected = false, chipNewShell = false, chipDoubled = false
        chip.onReconnect = { chipReconnected = true }
        chip.onNewShell = { chipNewShell = true }
        chip.onDoubleClick = { chipDoubled = true }
        let rightClick = NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        guard let chipMenu = chip.menu(for: rightClick) else { preconditionFailure("a tab must have a menu") }
        precondition(chipMenu.items.map(\.title).starts(with: ["重新连接", "新开终端"]), "tab menu: \(chipMenu.items.map(\.title))")
        for item in chipMenu.items.prefix(2) {
            precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
        }
        precondition(chipReconnected && chipNewShell)
        chip.mouseDown(with: NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 2, pressure: 1
        )!)
        precondition(chipDoubled, "double-clicking a tab must reach its handler")
        precondition(chip.toolTip?.contains("双击") == true, "a disconnected tab must say how to reconnect")

        // Double-clicking the title bar zooms; a click in the content does not count.
        let blank = NSViewController()
        blank.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let window = MainWindow(contentViewController: blank)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 800, height: 500))
        func click(_ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: NSPoint(x: 400, y: y), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 2, pressure: 1
            )!
        }
        precondition(window.isTitleBarClick(click(window.frame.height - 6)), "the title bar strip must count")
        precondition(!window.isTitleBarClick(click(100)), "the content area must not count")
    }

    /// Per-project sync settings: the store keeps directory and policy keyed
    /// by project ID, the new-project sheet exposes all three fields, and the
    /// sidebar's right-click menu reaches the same two actions.
    @MainActor
    static func projectSettingsChecks() async throws {
        let suite = "agentbox.smoke.project-sync"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // Store round-trip, keyed by project ID so a rename keeps it.
        precondition(ProjectSyncStore.settings(for: "w1", defaults: defaults).isEmpty)
        ProjectSyncStore.update("w1", projectID: "p1", defaults: defaults) { $0.localDir = "/tmp/one" }
        ProjectSyncStore.update("w1", projectID: "p2", defaults: defaults) { $0.policy = "server" }
        var settings = ProjectSyncStore.settings(for: "w1", defaults: defaults)
        precondition(settings["p1"]?.localDir == "/tmp/one")
        precondition(settings["p1"]?.policy == nil, "a directory-only override must not invent a policy")
        precondition(settings["p2"]?.policy == "server")
        precondition(settings["p2"]?.localDir == nil, "a policy-only override must not invent a directory")
        precondition(ProjectSyncStore.settings(for: "w2", defaults: defaults).isEmpty, "workspaces must not share overrides")

        // Clearing every field drops the entry, so "follow the workspace"
        // stays the default state instead of an explicit empty override.
        ProjectSyncStore.update("w1", projectID: "p1", defaults: defaults) { $0.localDir = nil }
        settings = ProjectSyncStore.settings(for: "w1", defaults: defaults)
        precondition(settings["p1"] == nil, "an emptied override must disappear")
        precondition(settings.count == 1)
        ProjectSyncStore.remove("w1", projectID: "p2", defaults: defaults)
        precondition(ProjectSyncStore.settings(for: "w1", defaults: defaults).isEmpty)

        precondition(ProjectSyncSetting.policyLabel(nil) == "双向同步（默认）")
        precondition(ProjectSyncSetting.policyLabel("server") == "从服务器下载到本地")
        precondition(ProjectSyncSetting.policyLabel("local") == "从本地上传到服务器")

        // New-project sheet: name, local workspace, sync mode.
        let sheet = NewProjectViewController()
        sheet.localRoot = "/tmp/agentbox-root"
        sheet.loadViewIfNeeded()
        let all = views(in: sheet.view)
        func field(_ id: NewProjectViewController.Field) -> NSView? {
            all.first { $0.identifier?.rawValue == id.rawValue }
        }
        guard let nameField = field(.name) as? NSTextField,
              let dirField = field(.localDir) as? NSTextField,
              let policyPopup = field(.policy) as? NSPopUpButton,
              let createButton = field(.create) as? NSButton else {
            preconditionFailure("new-project sheet is missing name, local workspace, sync mode or create")
        }
        precondition(
            policyPopup.itemArray.map(\.title) == ["双向同步（默认）", "从服务器下载到本地", "从本地上传到服务器"],
            "unexpected sync modes: \(policyPopup.itemArray.map(\.title))"
        )

        func retype(_ value: String) {
            nameField.stringValue = value
            sheet.controlTextDidChange(
                Notification(name: NSTextField.textDidChangeNotification, object: nameField)
            )
        }

        // The default directory tracks the name until a directory is picked.
        retype("demo")
        precondition(
            dirField.stringValue == "/tmp/agentbox-root/demo",
            "default directory must follow the name, got \(dirField.stringValue)"
        )
        sheet.setCustomDir("/tmp/elsewhere/demo")
        precondition(dirField.stringValue == "/tmp/elsewhere/demo")
        retype("renamed")
        precondition(dirField.stringValue == "/tmp/elsewhere/demo", "a picked directory must stop tracking the name")
        sheet.setCustomDir(nil)
        precondition(dirField.stringValue == "/tmp/agentbox-root/renamed", "clearing the pick must restore the default")

        policyPopup.selectItem(at: 2)
        // The button only wires to createClicked; invoking it here would call
        // dismiss on a sheet that was never presented, which blocks.
        precondition(
            NSStringFromSelector(createButton.action!) == "createClicked",
            "create button must run createClicked, got \(NSStringFromSelector(createButton.action!))"
        )
        let created = sheet.makeDraft()
        precondition(created != nil, "the sheet must hand a draft back")
        precondition(created!.name == "renamed")
        precondition(created!.localDir == nil, "no pick means the classic layout, not an empty override")
        precondition(created!.policy == "local")

        // An invalid name is refused inline instead of producing a draft.
        retype("bad/name")
        precondition(sheet.makeDraft() == nil, "a name containing / must be rejected")
        retype(".hidden")
        precondition(sheet.makeDraft() == nil, "a leading dot must be rejected")
        retype("renamed")
        sheet.setCustomDir("/tmp/elsewhere/renamed")
        let withDir = sheet.makeDraft()
        precondition(withDir?.localDir == "/tmp/elsewhere/renamed")

        // Right-click menu on an existing project.
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let project = RemoteProject(id: "p1", name: "demo", path: "/workspace/demo")
        var edited: RemoteProject?
        var syncedNow: (project: RemoteProject, policy: String)?
        sidebar.onEditProject = { edited = $0 }
        sidebar.onSyncProjectNow = { syncedNow = (project: $0, policy: $1) }

        let menu = NSMenu()
        sidebar.populate(menu, with: project)
        let titles = menu.items.map(\.title)
        // Name, directory, tool, command and sync mode live in one form now.
        precondition(titles.contains("修改项目…"), "menu must offer editing the project: \(titles)")
        for gone in ["修改项目名称…", "修改启动命令…", "修改同步方式", "修改本地工作空间…"] {
            precondition(!titles.contains(gone), "\(gone) folded into 修改项目… must stay absent: \(titles)")
        }
        precondition(titles.contains("立即同步"), "menu must keep 立即同步: \(titles)")
        precondition(titles.contains("打开同步日志"), "menu must offer the sync log: \(titles)")
        // The log is the only durable record of what a pass did.
        precondition(
            SyncManager.logURL.path.hasSuffix("/Library/Logs/agentbox-client/sync.log"),
            "unexpected sync log path: \(SyncManager.logURL.path)"
        )

        // Menu actions are handed over after the menu closes: modal UI started
        // inside a live tracking loop comes up behind the open menu.
        let editItem = menu.items.first { $0.title == "修改项目…" }!
        precondition(NSApp.sendAction(editItem.action!, to: editItem.target, from: editItem))
        precondition(edited == nil, "the edit must not open inside menu tracking")
        try await drainMainQueue()
        precondition(edited?.id == "p1", "a deferred menu action must still land")

        guard let syncMenu = menu.items.first(where: { $0.title == "立即同步" })?.submenu else {
            preconditionFailure("立即同步 must offer a submenu")
        }
        let passes = syncMenu.items.filter { !$0.isSeparatorItem }
        guard passes.count == 3 else {
            preconditionFailure("立即同步 must offer a plain pass and both overwriting ones")
        }
        let both = passes[0], fromServer = passes[1], fromLocal = passes[2]
        // The plain pass comes first and carries no policy: it overwrites
        // nothing, which is what "sync now" means with 双向同步 on.
        precondition(NSApp.sendAction(both.action!, to: both.target, from: both))
        try await drainMainQueue()
        precondition(syncedNow?.project.id == "p1" && syncedNow?.policy == "", "a plain pass forces neither side")
        precondition(NSApp.sendAction(fromServer.action!, to: fromServer.target, from: fromServer))
        try await drainMainQueue()
        precondition(syncedNow?.project.id == "p1" && syncedNow?.policy == "server")
        precondition(NSApp.sendAction(fromLocal.action!, to: fromLocal.target, from: fromLocal))
        try await drainMainQueue()
        precondition(syncedNow?.policy == "local")

        // 修改项目… reuses the new-project form, prefilled from the project.
        let editSheet = NewProjectViewController()
        editSheet.localRoot = "/tmp/agentbox-root"
        editSheet.availableAgents = ["claude", "codex"]
        editSheet.defaultAgent = "codex"
        editSheet.prefill = .init(name: "demo", localDir: "/tmp/elsewhere/demo", policy: "server",
                                  agent: "codex", command: "codex --yolo --search")
        editSheet.loadViewIfNeeded()
        let editViews = views(in: editSheet.view)
        func editField(_ id: NewProjectViewController.Field) -> NSView? {
            editViews.first { $0.identifier?.rawValue == id.rawValue }
        }
        precondition((editField(.name) as? NSTextField)?.stringValue == "demo")
        precondition((editField(.localDir) as? NSTextField)?.stringValue == "/tmp/elsewhere/demo")
        precondition((editField(.command) as? NSTextField)?.stringValue == "codex --yolo --search")
        precondition((editField(.policy) as? NSPopUpButton)?.indexOfSelectedItem == 1, "policy server is the second mode")
        precondition((editField(.create) as? NSButton)?.title == "保存")
        let editDraft = editSheet.makeDraft()!
        precondition(editDraft.agent == "codex" && editDraft.command == "codex --yolo --search"
                     && editDraft.policy == "server" && editDraft.localDir == "/tmp/elsewhere/demo")
    }

    /// Lets queued main-queue work run so a deferred menu action lands.
    ///
    /// This has to suspend, not spin: the check itself is already running on
    /// the main queue, which is serial, so no other block can start until this
    /// one returns. `Task.sleep` returns control to the queue; a nested
    /// `RunLoop.run` would just sit there and never see the block.
    @MainActor
    static func drainMainQueue() async {
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    /// A redeployed server makes the client look for its own update — but only
    /// on a change, and never by comparing the two version lines.
    /// The terminal is xterm.js in a web view. This drives it end to end: the
    /// page comes up and reports a size, output reaches it, typing comes back
    /// out, a selection copies, and the native parts are wired — the context
    /// menu replaces WebKit's, and 刷新显示 reaches its handler.
    @MainActor
    static func webTerminalChecks() async throws {
        let terminal = WebTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        var sizes: [(Int, Int)] = []
        terminal.onResize = { sizes.append(($0, $1)) }
        var refreshed = false
        terminal.onRefreshDisplay = { refreshed = true }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = terminal
        window.makeKeyAndOrderFront(nil)

        // WebKit is slow to start on a fresh runner.
        try await waitFor("the terminal page never came up", seconds: 30) { terminal.isReady }
        try await waitFor("the page never reported a size", seconds: 10) { terminal.cols > 0 && terminal.rows > 0 }
        precondition(sizes.last.map { $0 == (terminal.cols, terminal.rows) } ?? false,
                     "the size must reach onResize as well")
        // One place decides the size now: widening the view gives more
        // columns, reported once.
        let before = terminal.cols
        window.setContentSize(NSSize(width: 960, height: 400))
        try await waitFor("widening must add columns", seconds: 10) { terminal.cols > before }

        // Output, then a selection copied the way ⌘C does it.
        terminal.write(text: "copy me")
        try await Task.sleep(nanoseconds: 300_000_000)
        terminal.selectAllText()
        NSPasteboard.general.clearContents()
        terminal.copySelection()
        try await waitFor("the selection must reach the clipboard", seconds: 10) {
            NSPasteboard.general.string(forType: .string)?.contains("copy me") == true
        }

        // The context menu is the terminal's, not WebKit's.
        let menu = NSMenu()
        terminal.buildContextMenu(into: menu)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        precondition(titles == ["复制", "粘贴", "全选", "刷新显示"], "context menu: \(titles)")
        let refresh = menu.items.first { $0.title == "刷新显示" }!
        precondition(NSApp.sendAction(refresh.action!, to: refresh.target, from: refresh))
        precondition(refreshed, "刷新显示 must reach its handler")
        window.close()
    }

    @MainActor
    static func serverVersionTriggerChecks() {
        precondition(!UpdateLogic.serverChanged(previous: nil, current: "v0.1.7-custom24"),
                     "the first sighting says nothing about being behind")
        precondition(!UpdateLogic.serverChanged(previous: "", current: "v0.1.7-custom24"))
        precondition(!UpdateLogic.serverChanged(previous: "v0.1.7-custom24", current: "v0.1.7-custom24"),
                     "the same server is not a reason to check")
        precondition(!UpdateLogic.serverChanged(previous: "v0.1.7-custom24", current: ""),
                     "an older server that reports nothing must not trigger anything")
        precondition(UpdateLogic.serverChanged(previous: "v0.1.7-custom24", current: "v0.1.7-custom25"))
        // A downgrade counts too: the client that matches it may also be older.
        precondition(UpdateLogic.serverChanged(previous: "v0.1.7-custom25", current: "v0.1.7-custom24"))
    }

    /// The app menu: the version reads straight off it, and 设置… reaches the
    /// window's controller through the responder chain (no target of its own).
    @MainActor
    static func appMenuChecks() {
        let appMenu = AppDelegate.makeMainMenu().items.first!.submenu!
        precondition(appMenu.items.first!.title.hasPrefix("版本 "),
                     "the version belongs in the menu, not only behind 关于")
        precondition(appMenu.items.first!.action == nil, "the version line is a label, not a command")
        precondition(!appMenu.items.contains { $0.title.hasPrefix("关于") },
                     "关于 is gone: the version line replaced it")
        guard let settings = appMenu.items.first(where: { $0.title == "设置…" }), let action = settings.action else {
            preconditionFailure("the app menu must offer 设置…")
        }
        precondition(settings.keyEquivalent == ",", "设置… keeps the usual ⌘, shortcut")
        precondition(settings.target == nil, "设置… must travel the responder chain")
        precondition(MainViewController.instancesRespond(to: action), "nothing implements the 设置… action")
    }

    /// Tabs pack to the left. The bar spans the window, and NSStackView's
    /// default gravity-area layout was free to leave a gap and park the newest
    /// tab at the far right; a second tab must start right after the first.
    @MainActor
    static func tabStripChecks(client: AgentboxClient, workspace: Workspace) {
        let grid = TerminalGridViewController()
        let window = NSWindow(contentViewController: grid)
        window.setContentSize(NSSize(width: 1200, height: 600))
        let project = RemoteProject(id: "p-tabs", name: "demo", path: "/w/demo")
        _ = grid.add(client: client, workspace: workspace, project: project)
        _ = grid.add(client: client, workspace: workspace, project: project, kind: .shell(id: "tab2", index: 1))
        grid.view.layoutSubtreeIfNeeded()
        let chips = views(in: grid.view).compactMap { $0 as? TerminalTabChip }
        precondition(chips.count == 2, "expected two tabs, got \(chips.count)")
        let frames = chips
            .map { $0.convert($0.bounds, to: grid.view) }
            .sorted { $0.minX < $1.minX }
        precondition(frames[0].minX < 40, "the first tab must start at the left edge of the bar")
        let gap = frames[1].minX - frames[0].maxX
        precondition(gap < 12, "a new tab must sit beside the previous one, not at the far right (gap \(gap))")
        window.close()
    }

    @MainActor
    static func check() async throws {
        themeChecks()
        settingsSheetChecks()
        try await projectSettingsChecks()
        launchAndSyncEventChecks()
        try await webTerminalChecks()
        precondition(URLProtocol.registerClass(AppHTTPFixture.self))
        let client = AgentboxClient(server: URL(string: "https://agentbox-app-fixture.invalid")!, user: "synthetic-app-user", token: "synthetic-app-token")
        let controller = MainViewController(client: client)
        // The bottom bar is the only place sync progress is visible, so the
        // spinner has to follow a "done/total" line and stop on a result.
        controller.showSyncStatus("正在同步…", busy: true)
        precondition(controller.isSyncing, "an explicit busy status must spin")
        precondition(controller.syncStatusText == "正在同步…")
        controller.handleSyncOutput("demo: 25/100")
        precondition(controller.isSyncing, "a done/total line is progress and must keep spinning")
        precondition(controller.syncStatusText == "demo: 25/100")
        controller.handleSyncOutput("demo: applied 12 changes")
        precondition(!controller.isSyncing, "a result line must stop the spinner")
        precondition(controller.syncStatusText == "demo: applied 12 changes")
        controller.handleSyncOutput("   ")
        precondition(controller.syncStatusText == "demo: applied 12 changes", "blank output must be ignored")
        // An upload borrows the bar and then hands it back: a drop in one tab
        // must not leave the project's own sync looking stopped.
        MainViewController.uploadHoldSeconds = 0.05
        controller.showSyncStatus("demo: 40/100", busy: true, progress: 0.4)
        func uploadNote(_ state: UploadProgressNote.State) -> Notification {
            Notification(
                name: UploadProgressNote.name,
                object: nil,
                userInfo: ["file": "a.png", "project": "demo", "state": state]
            )
        }
        controller.handleUploadNote(uploadNote(.running(fraction: 0.5)))
        precondition(controller.syncStatusText.contains("上传 a.png"), "an upload must show while it runs")
        controller.handleUploadNote(uploadNote(.finished(bytes: 10, milliseconds: 20)))
        precondition(controller.syncStatusText.contains("✓"), "a finished upload is shown briefly")
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(controller.syncStatusText == "demo: 40/100" && controller.isSyncing,
                     "the bar must go back to the sync engine's own line, still busy")
        MainViewController.uploadHoldSeconds = 3

        controller.showSyncStatus("", busy: false)
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

        // The bar follows the project in front. Two projects sync at once; the
        // line must be the focused one's, not whichever event arrived last.
        func progressEvent(_ project: String, _ index: Int) -> SyncEvent {
            let json = """
            {"type":"progress","project":"\(project)","phase":"upload","path":"a.txt","index":\(index),"total":10,"bytes":1,"total_bytes":10,"percent":\(index * 10)}
            """
            return SyncEvent.decode(Data(json.utf8))!
        }
        let grid = controller.children.compactMap { $0 as? TerminalGridViewController }.first!
        let focusedTab = grid.add(
            client: client, workspace: beta,
            project: RemoteProject(id: "p-focus", name: "focused", path: "/w/focused")
        )
        precondition(focusedTab.project.name == "focused")
        // The sidebar follows the tab in front: Beta's tab highlights Beta's
        // row, and bringing another tab forward moves the highlight — quietly,
        // because a hand-picked row opens that project's AI session, and that
        // would have pulled Beta's tab straight back to the front.
        let betaTab = grid.add(
            client: client, workspace: beta,
            project: RemoteProject(id: "beta-project", name: "Beta project", path: "/workspace/Beta project")
        )
        precondition(table.selectedRow == 0, "the row of the tab in front must be highlighted")
        grid.select(focusedTab)
        precondition(table.selectedRow == -1, "a project missing from the list leaves no row highlighted")
        grid.select(betaTab)
        precondition(table.selectedRow == 0, "switching tabs must move the highlight back")
        grid.select(focusedTab)
        grid.remove(betaTab)
        controller.handleSyncEvent(progressEvent("focused", 3))
        controller.handleSyncEvent(progressEvent("other", 7))
        precondition(controller.syncStatusText.hasPrefix("focused ·"),
                     "the bar must stay on the project in front: \(controller.syncStatusText)")
        // The indicator speaks for the project in front only: two projects in
        // sync read as that one's state, not as a count of the workspace.
        func statusEvent(_ project: String) -> SyncEvent {
            SyncEvent.decode(Data(#"{"type":"status","project":"\#(project)","in_sync":true,"applied":0,"duration_ms":10,"at":"2026-10-03T00:00:00Z"}"#.utf8))!
        }
        controller.handleSyncEvent(statusEvent("focused"))
        controller.handleSyncEvent(statusEvent("other"))
        precondition(controller.syncIndicatorText == "两端一致",
                     "the indicator must describe the focused project only: \(controller.syncIndicatorText)")
        // Engine chatter that names no project stays out of a focused bar.
        controller.handleSyncOutput("同步引擎：正在核对工作区")
        precondition(controller.syncStatusText.hasPrefix("focused ·"),
                     "workspace chatter must not take a focused bar: \(controller.syncStatusText)")

        // An engine log line naming another project goes to that project's
        // lane, not over the focused one — and a chunk that still carries a
        // newline is reduced to its last line, since the bar is one line high
        // and a second one is drawn on top of the first.
        controller.handleSyncOutput("Beta project: 3/10\nBeta project: 4/10")
        precondition(controller.syncStatusText.hasPrefix("focused ·"),
                     "another project's log line must not take the bar: \(controller.syncStatusText)")
        precondition(!controller.syncStatusText.contains("\n"), "the bar shows a single line")

        // With nothing in front, the newest line shows — and it is the one that
        // log line produced, which is what proves it was filed under its own
        // project instead of the workspace-wide line.
        grid.remove(focusedTab)
        precondition(controller.syncStatusText == "Beta project: 4/10",
                     "a project's log line must be kept per project: \(controller.syncStatusText)")
        controller.handleSyncEvent(progressEvent("other", 8))
        precondition(controller.syncStatusText.hasPrefix("other ·"),
                     "with no tab in front the newest line shows: \(controller.syncStatusText)")

        // The sidebar's server clock: it must show the server's time (the
        // fixture's, three hours from the runner's), and a passing status
        // message must not wipe it — it had no line of its own before, so the
        // next project reload always overwrote it.
        try await waitFor("Sidebar server clock missing") {
            views(in: sidebar.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("服务器时间 ") }
        }
        let clockLabel = views(in: sidebar.view).compactMap { $0 as? NSTextField }
            .first { $0.stringValue.hasPrefix("服务器时间 ") }!
        let serverFormatter = DateFormatter()
        serverFormatter.locale = Locale(identifier: "en_US_POSIX")
        serverFormatter.timeZone = TimeZone(identifier: AppHTTPFixture.serverZone)!
        // Date and time: the server is usually on another date than the Mac,
        // which is the point of showing its clock at all.
        serverFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        // A minute can roll over between the client's sync and this check, so
        // the neighbouring minutes count as a match too.
        let expectedClock = [-60.0, 0, 60].map {
            serverFormatter.string(from: Date().addingTimeInterval(AppHTTPFixture.serverSkew + $0))
        }
        precondition(expectedClock.contains { clockLabel.stringValue.contains($0) },
                     "sidebar clock \(clockLabel.stringValue) is not the server's \(expectedClock[1])")
        sidebar.setStatus("正在读取项目…")
        precondition(clockLabel.stringValue.hasPrefix("服务器时间 "), "a status message wiped the server clock")

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
        precondition(sidebar.view.superview == nil, "a hidden sidebar must leave the split view, not keep a strip")
        precondition(NSApp.sendAction(toolbarItem.action!, to: toolbarItem.target, from: toolbarItem))
        precondition(!sidebar.view.isHidden)
        precondition(controller.isSidebarVisible)
        precondition(!views(in: sidebar.view).compactMap { $0 as? NSButton }.contains { $0.title == "选择目录" }, "removed workspace sync panel must stay absent")
        if let output = ProcessInfo.processInfo.environment["AGENTBOX_APP_SMOKE_IMAGE"] {
            controller.view.layoutSubtreeIfNeeded()
            let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds)!
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
        }
        print("PASS: theme/scheme/font/mouse settings, settings sheet wiring, per-project sync settings and project menu, native workspace loading, stale responses/errors, loading isolation, terminal URLs, the xterm.js terminal (size, output, copy, menu), the sidebar following the tab in front, sidebar resizing/toggle, the sidebar's server clock, left-packed terminal tabs, a bar-free upload banner, the app menu's version and 设置… entry, the server-version update trigger, and removed sync panel")
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
