import AppKit
import Foundation
import SwiftTerm

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

/// Records bytes SwiftTerm wants to send upstream, so tests can assert
/// whether mouse events were actually forwarded to the (pretend) TUI app.
final class MouseDelegateStub: NSObject, TerminalViewDelegate {
    var received: [Data] = []

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        received.append(Data(data))
    }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// A window that hands mouse events straight to the view under the cursor.
///
/// The smoke binary is not a bundled app, so it never becomes active and
/// `NSWindow.sendEvent` eats every synthetic click as "the click that
/// activates an inactive window" — the terminal would never see a thing.
/// Only that activation swallow is bypassed here; the app-level event
/// monitor (the code under test) runs earlier, when the event is dequeued.
final class MousePassthroughWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            let point = contentView?.convert(event.locationInWindow, from: nil) ?? .zero
            if let target = contentView?.hitTest(point) {
                switch event.type {
                case .leftMouseDown: target.mouseDown(with: event)
                case .leftMouseDragged: target.mouseDragged(with: event)
                default: target.mouseUp(with: event)
                }
                return
            }
        default:
            break
        }
        super.sendEvent(event)
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
            $0.label(forSegment: 2) == "⇧ 拖选"
        }
        precondition(mouseSegment != nil, "mouse mode segment missing")
        mouseSegment!.selectedSegment = 2
        precondition(NSApp.sendAction(mouseSegment!.action!, to: mouseSegment!.target, from: mouseSegment!))
        precondition(TerminalThemeManager.mouseMode == .smart)

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

    /// Posts synthetic mouse events through the app event queue (the same
    /// path the local monitor hooks) and asserts what reaches the TUI app:
    /// on forwards clicks, off never does, and smart forwards everything
    /// except shift-held gestures which select locally and recover after.
    @MainActor
    static func mouseEventsChecks() async throws {
        let defaults = UserDefaults.standard
        let mouseKey = "agentbox.terminal.mouse-mode"
        let prior = defaults.string(forKey: mouseKey)
        defer {
            if let prior {
                defaults.set(prior, forKey: mouseKey)
            } else {
                defaults.removeObject(forKey: mouseKey)
            }
        }

        let stub = MouseDelegateStub()
        let surface = TerminalSurface(frame: NSRect(x: 0, y: 0, width: 400, height: 300), font: NativeTheme.terminalFont())
        surface.terminalDelegate = stub
        let window = MousePassthroughWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        surface.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            surface.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            surface.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        surface.feed(text: "\u{1B}[?1000h\u{1B}[?1006h") // button-press tracking, SGR encoding

        func post(_ type: NSEvent.EventType, shift: Bool) {
            let event = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 60, y: 150),
                modifierFlags: shift ? .shift : [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0
            )!
            NSApp.postEvent(event, atStart: false)
        }
        func settle() async throws {
            try await Task.sleep(nanoseconds: 80_000_000)
        }

        // "on": clicks are forwarded to the TUI app.
        TerminalThemeManager.update(mouseMode: .on)
        surface.applyMouseMode()
        post(.leftMouseDown, shift: false)
        try await settle()
        precondition(stub.received.contains { $0.prefix(3) == Data("\u{1B}[<".utf8) }, "on mode must forward the click")
        post(.leftMouseUp, shift: false)
        try await settle()

        // "smart" + shift: the whole gesture stays local, then recovers.
        TerminalThemeManager.update(mouseMode: .smart)
        surface.applyMouseMode()
        let before = stub.received.count
        post(.leftMouseDown, shift: true)
        try await settle()
        precondition(!surface.allowMouseReporting, "shift-drag must disable reporting for the gesture")
        precondition(stub.received.count == before, "shift-drag must not reach the TUI app")
        post(.leftMouseDragged, shift: true)
        try await settle()
        precondition(stub.received.count == before)
        post(.leftMouseUp, shift: true)
        try await settle()
        precondition(surface.allowMouseReporting, "reporting must recover after the gesture")
        precondition(stub.received.count == before, "the suppressed release must not leak either")

        // "smart" without shift: forwarded like "on".
        post(.leftMouseDown, shift: false)
        try await settle()
        precondition(stub.received.count > before, "smart mode must forward plain clicks")
        post(.leftMouseUp, shift: false)
        try await settle()

        // "off": nothing is ever forwarded.
        TerminalThemeManager.update(mouseMode: .off)
        surface.applyMouseMode()
        let before2 = stub.received.count
        post(.leftMouseDown, shift: false)
        try await settle()
        precondition(stub.received.count == before2, "off mode must never forward mouse events")
        window.close()
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

        precondition(ProjectSyncSetting.policyLabel(nil) == "跟随工作空间")
        precondition(ProjectSyncSetting.policyLabel("server") == "以服务器为准")
        precondition(ProjectSyncSetting.policyLabel("local") == "以本地为准")

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
            policyPopup.itemArray.map(\.title) == ["跟随工作空间", "以服务器为准", "以本地为准"],
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
        var renamed: RemoteProject?
        var changedDir: RemoteProject?
        var changedPolicy: (project: RemoteProject, policy: String?)?
        var syncedNow: (project: RemoteProject, policy: String)?
        sidebar.onRenameProject = { renamed = $0 }
        sidebar.onChangeProjectLocalDir = { changedDir = $0 }
        sidebar.onChangeProjectPolicy = { changedPolicy = (project: $0, policy: $1) }
        sidebar.onSyncProjectNow = { syncedNow = (project: $0, policy: $1) }
        sidebar.projectPolicyForDisplay = { _ in "server" }

        let menu = NSMenu()
        sidebar.populate(menu, with: project)
        let titles = menu.items.map(\.title)
        precondition(titles.contains("修改项目名称…"), "menu must offer renaming: \(titles)")
        precondition(titles.contains("修改本地工作空间…"), "menu must offer the local workspace: \(titles)")
        precondition(titles.contains("修改同步方式"), "menu must offer the sync mode: \(titles)")
        precondition(titles.contains("打开同步日志"), "menu must offer the sync log: \(titles)")
        // The log is the only durable record of what a pass did.
        precondition(
            SyncManager.logURL.path.hasSuffix("/Library/Logs/agentbox-client/sync.log"),
            "unexpected sync log path: \(SyncManager.logURL.path)"
        )

        guard let policyItem = menu.items.first(where: { $0.title == "修改同步方式" }),
              let policyMenu = policyItem.submenu else {
            preconditionFailure("修改同步方式 must be a submenu")
        }
        // The sync modes are view-backed rows: a native item can only carry one
        // click target, and these need two (pick the side, and sync now).
        let rows = policyMenu.items.compactMap { $0.view as? SyncPolicyMenuRow }
        precondition(rows.count == 3, "expected three sync modes, got \(rows.count)")
        precondition(
            rows.map(\.title) == ["跟随工作空间", "以服务器为准", "以本地为准"],
            "unexpected sync modes: \(rows.map(\.title))"
        )
        precondition(
            rows.filter(\.isChecked).map(\.title) == ["以服务器为准"],
            "the project's current policy must be the checked row"
        )
        precondition(
            rows.filter(\.hasSyncNow).map(\.title) == ["以服务器为准", "以本地为准"],
            "only the two real modes may offer 立即同步"
        )

        let renameItem = menu.items.first { $0.title == "修改项目名称…" }!
        if let output = ProcessInfo.processInfo.environment["AGENTBOX_APP_SMOKE_MENU_IMAGE"] {
            let size = SyncPolicyMenuRow.rowSize
            let canvas = NSImage(size: NSSize(width: size.width, height: size.height * CGFloat(rows.count)))
            canvas.lockFocus()
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: canvas.size).fill()
            for (index, row) in rows.enumerated() {
                row.frame = NSRect(origin: .zero, size: size)
                row.layoutSubtreeIfNeeded()
                let rowBitmap = row.bitmapImageRepForCachingDisplay(in: row.bounds)!
                row.cacheDisplay(in: row.bounds, to: rowBitmap)
                rowBitmap.draw(in: NSRect(
                    x: 0,
                    y: size.height * CGFloat(rows.count - 1 - index),
                    width: size.width,
                    height: size.height
                ))
            }
            canvas.unlockFocus()
            let rep = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
        }
        precondition(NSApp.sendAction(renameItem.action!, to: renameItem.target, from: renameItem))
        try await drainMainQueue()
        precondition(renamed?.id == "p1", "a deferred menu action must still land")
        let dirItem = menu.items.first { $0.title == "修改本地工作空间…" }!
        precondition(NSApp.sendAction(dirItem.action!, to: dirItem.target, from: dirItem))
        try await drainMainQueue()
        precondition(changedDir?.id == "p1")

        // Tapping the row only picks the side...
        rows[2].select()
        // ...and it must be handed over *after* the menu closes: modal UI
        // started inside a live tracking loop comes up behind the open menu
        // and never sees the clicks meant for it.
        precondition(changedPolicy == nil, "the row must not run its action inside menu tracking")
        try await drainMainQueue()
        let picked = changedPolicy
        precondition(picked != nil && picked!.project.id == "p1" && picked!.policy == "local")
        precondition(syncedNow == nil, "picking a side must not sync on its own")
        // ...while the ⟳ reports an immediate overwrite for that side.
        rows[1].performSyncNow()
        precondition(syncedNow == nil, "the ⟳ must not run inside menu tracking either")
        try await drainMainQueue()
        let forced = syncedNow
        precondition(forced != nil && forced!.project.id == "p1" && forced!.policy == "server")
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

    @MainActor
    static func check() async throws {
        themeChecks()
        settingsSheetChecks()
        try await projectSettingsChecks()
        try await mouseEventsChecks()
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
        print("PASS: theme/scheme/font/mouse settings, settings sheet wiring, per-project sync settings and project menu, synthetic mouse gesture path, native workspace loading, stale responses/errors, loading isolation, terminal URLs, sidebar resizing/toggle and directory cancellation")
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
