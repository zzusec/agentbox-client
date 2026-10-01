import AppKit
import SwiftTerm

/// One terminal color scheme: the surface background/foreground, the cursor
/// color and the 16 ANSI colors. Modeled after CLI-Manager's preset cards.
/// Codable so the user-defined scheme persists as JSON in defaults.
struct TerminalScheme: Identifiable, Codable {
    let id: String
    let name: String
    let detail: String
    let background: String
    let foreground: String
    let cursor: String
    let ansi: [String]

    var isLight: Bool {
        TerminalThemeManager.isLight(hex: background)
    }

    func with(
        id newID: String? = nil,
        name newName: String? = nil,
        detail newDetail: String? = nil,
        background newBackground: String? = nil,
        foreground newForeground: String? = nil,
        cursor newCursor: String? = nil,
        ansi newAnsi: [String]? = nil
    ) -> TerminalScheme {
        TerminalScheme(
            id: newID ?? id, name: newName ?? name, detail: newDetail ?? detail,
            background: newBackground ?? background, foreground: newForeground ?? foreground,
            cursor: newCursor ?? cursor, ansi: newAnsi ?? ansi
        )
    }
}

/// A monospaced font family offered in the terminal settings. `candidates`
/// are font names tried in order (family and PostScript names), first resolvable
/// one wins; families absent from this Mac are hidden from the picker.
struct TerminalFontFamily: Identifiable {
    let id: String
    let displayName: String
    let candidates: [String]

    var resolvedName: String? {
        candidates.first { NSFont(name: $0, size: 13) != nil }
    }
}

/// How mouse events are handed to the TUI application:
/// - off: never report; drag always selects locally (copy works, default).
/// - on: always report when the app asked for mouse (vim/tmux clicks work).
/// - smart: report like `on`, but holding ⇧ makes the gesture select locally.
enum TerminalMouseMode: String {
    case off, on, smart

    var label: String {
        switch self {
        case .off: return "关闭"
        case .on: return "开启"
        case .smart: return "⇧ 拖选"
        }
    }
}

enum TerminalThemeManager {
    /// Posted after any terminal setting changed (scheme, custom scheme,
    /// font family, font size, mouse mode) so open terminals re-apply live.
    static let schemeChanged = Notification.Name("agentbox.terminal.scheme-changed")
    private static let schemeKey = "agentbox.terminal.scheme"
    private static let fontSizeKey = "agentbox.terminal.font-size"
    private static let fontFamilyKey = "agentbox.terminal.font-family"
    private static let mouseModeKey = "agentbox.terminal.mouse-mode"
    private static let customSchemeKey = "agentbox.terminal.custom-scheme"

    static let customSchemeID = "custom"

    static let schemes: [TerminalScheme] = [
        TerminalScheme(
            id: "classic-black", name: "经典黑", detail: "极简黑底，长时间盯屏不累",
            background: "#0C0C0C", foreground: "#CCCCCC", cursor: "#CCCCCC",
            ansi: ["#161616", "#F0625D", "#71BE61", "#E5B567", "#5B9BD5", "#C678DD", "#56B6C2", "#E0E0E0",
                   "#4A4A4A", "#FF7B72", "#8BD87B", "#F5D08A", "#7FB3E8", "#D6A6E8", "#7BD1D6", "#FFFFFF"]
        ),
        TerminalScheme(
            id: "one-dark", name: "深海蓝", detail: "One Dark 气质，蓝紫点缀",
            background: "#282C34", foreground: "#ABB2BF", cursor: "#61AFEF",
            ansi: ["#282C34", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF",
                   "#5C6370", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#FFFFFF"]
        ),
        TerminalScheme(
            id: "dracula", name: "德古拉", detail: "高饱和紫粉，流行配色",
            background: "#282A36", foreground: "#F8F8F2", cursor: "#FF79C6",
            ansi: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
                   "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"]
        ),
        TerminalScheme(
            id: "solarized-dark", name: "日光深", detail: "Solarized 深色，护眼经典",
            background: "#002B36", foreground: "#93A1A1", cursor: "#93A1A1",
            ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
                   "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]
        ),
        TerminalScheme(
            id: "paper-light", name: "纸白", detail: "GitHub Light，浅色下写码清爽",
            background: "#FFFFFF", foreground: "#24292F", cursor: "#0969DA",
            ansi: ["#24292E", "#D73A49", "#28A745", "#DBAB09", "#0366D6", "#A626A4", "#0997B3", "#6A737D",
                   "#959DA5", "#CB2431", "#22863A", "#B08800", "#005CC5", "#8250DF", "#3192AA", "#D1D5DA"]
        ),
        TerminalScheme(
            id: "warm-paper", name: "暖米纸", detail: "暖米白纸感，低对比阅读友好",
            background: "#F5EFE3", foreground: "#43382A", cursor: "#B4560E",
            ansi: ["#4A4238", "#C75646", "#51A14E", "#C4A036", "#5E86C6", "#9A5FA8", "#5FA8A0", "#EAE3D2",
                   "#6B6255", "#E06A5A", "#63B663", "#D9B65C", "#7BA1D6", "#B085C9", "#6FB8B0", "#FFFDF8"]
        ),
    ]

    /// ANSI slot names (0–15) used as tooltips in the custom scheme editor.
    static let ansiSlotNames = [
        "黑", "红", "绿", "黄", "蓝", "品红", "青", "白",
        "亮黑", "亮红", "亮绿", "亮黄", "亮蓝", "亮品红", "亮青", "亮白",
    ]

    // MARK: Scheme selection

    /// Preset schemes plus the custom card. When no custom scheme has been
    /// created yet, a placeholder derived from the current preset fills the
    /// card so the grid always shows the "自定义" entry (fixed "custom" id —
    /// never the preset's id, or the grid would hold the id twice).
    static var choices: [TerminalScheme] {
        let custom = customScheme
        let placeholder = custom ?? current.with(
            id: customSchemeID,
            name: "自定义",
            detail: "点击基于当前配色创建专属配色"
        )
        return schemes + [placeholder]
    }

    static var current: TerminalScheme {
        let id = UserDefaults.standard.string(forKey: schemeKey)
        if id == customSchemeID, let custom = customScheme {
            return custom
        }
        return schemes.first { $0.id == id } ?? schemes[0]
    }

    static func select(_ id: String) {
        UserDefaults.standard.set(id, forKey: schemeKey)
        NotificationCenter.default.post(name: schemeChanged, object: nil)
    }

    // MARK: Custom scheme

    static var customScheme: TerminalScheme? {
        guard let json = UserDefaults.standard.string(forKey: customSchemeKey) else { return nil }
        let data = Data(json.utf8)
        let scheme = try? JSONDecoder().decode(TerminalScheme.self, from: data)
        return scheme?.with(name: "自定义", detail: "专属配色，随时修改")
    }

    /// Creates the custom scheme from an existing one and selects it.
    static func createCustom(from source: TerminalScheme) {
        let custom = source.with(id: customSchemeID, name: "自定义", detail: "专属配色，随时修改")
        storeCustom(custom)
        select(customSchemeID)
    }

    /// Mutates the stored custom scheme in place and notifies observers.
    static func updateCustom(_ mutate: (inout TerminalScheme) -> Void) {
        guard var custom = customScheme else { return }
        mutate(&custom)
        storeCustom(custom)
        if UserDefaults.standard.string(forKey: schemeKey) == customSchemeID {
            NotificationCenter.default.post(name: schemeChanged, object: nil)
        }
    }

    private static func storeCustom(_ scheme: TerminalScheme) {
        guard let data = try? JSONEncoder().encode(scheme),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: customSchemeKey)
    }

    // MARK: Font

    static let fontFamilies: [TerminalFontFamily] = [
        TerminalFontFamily(id: "menlo", displayName: "Menlo（默认）", candidates: ["Menlo-Regular", "Menlo"]),
        TerminalFontFamily(id: "sf-mono", displayName: "SF Mono", candidates: ["SFNSMono-Regular", "SF Mono", "SFNSMono"]),
        TerminalFontFamily(id: "monaco", displayName: "Monaco", candidates: ["Monaco"]),
        TerminalFontFamily(id: "courier-new", displayName: "Courier New", candidates: ["Courier New", "CourierNewPSMT"]),
        TerminalFontFamily(id: "andale-mono", displayName: "Andale Mono", candidates: ["Andale Mono"]),
        TerminalFontFamily(id: "jetbrains-mono", displayName: "JetBrains Mono", candidates: ["JetBrains Mono", "JetBrainsMono-Regular"]),
        TerminalFontFamily(id: "fira-code", displayName: "Fira Code", candidates: ["Fira Code", "FiraCode-Regular"]),
        TerminalFontFamily(id: "fira-mono", displayName: "Fira Mono", candidates: ["Fira Mono", "FiraMono-Regular"]),
        TerminalFontFamily(id: "hack", displayName: "Hack", candidates: ["Hack", "Hack-Regular"]),
        TerminalFontFamily(id: "source-code-pro", displayName: "Source Code Pro", candidates: ["Source Code Pro", "SourceCodePro-Regular"]),
        TerminalFontFamily(id: "ibm-plex-mono", displayName: "IBM Plex Mono", candidates: ["IBM Plex Mono", "IBMPlexMono-Regular"]),
        TerminalFontFamily(id: "cascadia-code", displayName: "Cascadia Code", candidates: ["Cascadia Code", "CascadiaCode-Regular"]),
        TerminalFontFamily(id: "victor-mono", displayName: "Victor Mono", candidates: ["Victor Mono", "VictorMono-Regular"]),
        TerminalFontFamily(id: "iosevka", displayName: "Iosevka", candidates: ["Iosevka", "Iosevka-Regular"]),
        TerminalFontFamily(id: "roboto-mono", displayName: "Roboto Mono", candidates: ["Roboto Mono", "RobotoMono-Regular"]),
        TerminalFontFamily(id: "inconsolata", displayName: "Inconsolata", candidates: ["Inconsolata", "Inconsolata-Regular"]),
        TerminalFontFamily(id: "ubuntu-mono", displayName: "Ubuntu Mono", candidates: ["Ubuntu Mono", "UbuntuMono-Regular"]),
    ]

    /// Families actually present on this machine, in the curated order.
    static var installedFontFamilies: [TerminalFontFamily] {
        fontFamilies.filter { $0.resolvedName != nil }
    }

    static var fontFamilyID: String {
        UserDefaults.standard.string(forKey: fontFamilyKey) ?? "menlo"
    }

    static var fontFamily: TerminalFontFamily {
        let id = fontFamilyID
        return installedFontFamilies.first { $0.id == id } ?? installedFontFamilies[0]
    }

    static var fontSize: CGFloat {
        let stored = UserDefaults.standard.double(forKey: fontSizeKey)
        return stored > 0 ? CGFloat(stored) : 13
    }

    static func selectFontFamily(_ id: String) {
        UserDefaults.standard.set(id, forKey: fontFamilyKey)
        NotificationCenter.default.post(name: schemeChanged, object: nil)
    }

    static func update(fontSize: CGFloat) {
        UserDefaults.standard.set(Double(fontSize), forKey: fontSizeKey)
        NotificationCenter.default.post(name: schemeChanged, object: nil)
    }

    /// The terminal font: the chosen family with the CJK fallback cascade.
    static func font() -> NSFont {
        NativeTheme.terminalFont(size: fontSize, postScriptName: fontFamily.resolvedName)
    }

    // MARK: Mouse reporting

    static var mouseMode: TerminalMouseMode {
        TerminalMouseMode(rawValue: UserDefaults.standard.string(forKey: mouseModeKey) ?? "") ?? .off
    }

    static func update(mouseMode: TerminalMouseMode) {
        UserDefaults.standard.set(mouseMode.rawValue, forKey: mouseModeKey)
        NotificationCenter.default.post(name: schemeChanged, object: nil)
    }

    // MARK: Color helpers

    static func nsColor(_ hex: String) -> NSColor {
        let value = hexValue(hex)
        return NSColor(
            calibratedRed: CGFloat((value & 0xFF0000) >> 16) / 255,
            green: CGFloat((value & 0x00FF00) >> 8) / 255,
            blue: CGFloat(value & 0x0000FF) / 255,
            alpha: 1
        )
    }

    static func termColor(_ hex: String) -> SwiftTerm.Color {
        let value = hexValue(hex)
        return SwiftTerm.Color(
            red: UInt16((value & 0xFF0000) >> 16) * 257,
            green: UInt16((value & 0x00FF00) >> 8) * 257,
            blue: UInt16(value & 0x0000FF) * 257
        )
    }

    /// Normalizes free-form input to `#RRGGBB`: accepts an optional `#` and
    /// 3- or 6-digit hex. Returns nil for anything else — callers must treat
    /// nil as "keep the previous color", not as black.
    static func normalizedHex(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        guard text.count == 3 || text.count == 6 else { return nil }
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + text.uppercased()
    }

    private static func hexValue(_ hex: String) -> UInt64 {
        var value: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
        return value
    }

    static func isLight(hex: String) -> Bool {
        let value = hexValue(hex)
        let red = (value & 0xFF0000) >> 16
        let green = (value & 0x00FF00) >> 8
        let blue = value & 0x0000FF
        return (0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)) > 140
    }
}
