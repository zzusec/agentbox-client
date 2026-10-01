import AppKit
import SwiftTerm

/// One terminal color scheme: the surface background/foreground, the cursor
/// color and the 16 ANSI colors. Modeled after CLI-Manager's preset cards.
struct TerminalScheme: Identifiable {
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
}

enum TerminalThemeManager {
    static let schemeChanged = Notification.Name("agentbox.terminal.scheme-changed")
    private static let schemeKey = "agentbox.terminal.scheme"
    private static let fontSizeKey = "agentbox.terminal.font-size"

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

    static var current: TerminalScheme {
        let id = UserDefaults.standard.string(forKey: schemeKey)
        return schemes.first { $0.id == id } ?? schemes[0]
    }

    static var fontSize: CGFloat {
        let stored = UserDefaults.standard.double(forKey: fontSizeKey)
        return stored > 0 ? CGFloat(stored) : 13
    }

    static func select(_ id: String) {
        UserDefaults.standard.set(id, forKey: schemeKey)
        NotificationCenter.default.post(name: schemeChanged, object: nil)
    }

    static func update(fontSize: CGFloat) {
        UserDefaults.standard.set(Double(fontSize), forKey: fontSizeKey)
        NotificationCenter.default.post(name: schemeChanged, object: nil)
    }

    static func font() -> NSFont {
        NativeTheme.terminalFont(size: fontSize)
    }

    static func nsColor(_ hex: String) -> NSColor {
        var value: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
        return NSColor(
            calibratedRed: CGFloat((value & 0xFF0000) >> 16) / 255,
            green: CGFloat((value & 0x00FF00) >> 8) / 255,
            blue: CGFloat(value & 0x0000FF) / 255,
            alpha: 1
        )
    }

    static func termColor(_ hex: String) -> SwiftTerm.Color {
        var value: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
        let red = UInt16((value & 0xFF0000) >> 16)
        let green = UInt16((value & 0x00FF00) >> 8)
        let blue = UInt16(value & 0x0000FF)
        return SwiftTerm.Color(red: red * 257, green: green * 257, blue: blue * 257)
    }

    static func isLight(hex: String) -> Bool {
        var value: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
        let red = (value & 0xFF0000) >> 16
        let green = (value & 0x00FF00) >> 8
        let blue = value & 0x0000FF
        return (0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)) > 140
    }
}
