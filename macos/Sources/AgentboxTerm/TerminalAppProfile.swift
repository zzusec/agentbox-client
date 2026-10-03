import AppKit

/// The look of Apple's Terminal.app, read from its default profile.
///
/// "Match Terminal" used to mean colours copied into this source once, from
/// one profile on one Mac, with a font and size guessed separately — so it
/// drifted as soon as the profile changed, and never matched the size at all.
/// This reads the profile Terminal.app opens new windows with, every time: its
/// font and size, background, text, cursor and selection colours, the sixteen
/// ANSI colours, cursor shape and line spacing. Anything the profile leaves
/// unset falls back to Terminal.app's own defaults.
struct TerminalAppProfile {
    let name: String
    /// The font's PostScript name and size as the profile stores them.
    let fontName: String?
    let fontSize: Double?
    let background: String
    let foreground: String
    let cursor: String
    let selection: String?
    let ansi: [String]
    /// "block", "underline" or "bar", as xterm.js names them.
    let cursorStyle: String?
    let cursorBlink: Bool?
    let lineSpacing: Double?

    /// The profile Terminal.app uses for new windows, or nil when its
    /// preferences cannot be read (never run, or a sandboxed reader).
    static func load(from defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.Terminal")) -> TerminalAppProfile? {
        // The smoke checks pin the app's own defaults; whatever the runner's
        // Terminal.app happens to be set to must not leak into them.
        guard ProcessInfo.processInfo.environment["AGENTBOX_IGNORE_TERMINAL_APP"] == nil,
              let defaults,
              let name = defaults.string(forKey: "Default Window Settings"),
              let all = defaults.dictionary(forKey: "Window Settings"),
              let settings = all[name] as? [String: Any] else { return nil }
        return parse(settings, name: name)
    }

    static func parse(_ settings: [String: Any], name: String) -> TerminalAppProfile {
        func color(_ key: String) -> String? {
            guard let data = settings[key] as? Data,
                  let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else { return nil }
            return hex(color)
        }
        let font = (settings["Font"] as? Data).flatMap(archivedFont)
        let ansi = zip(ansiKeys, basicANSI).map { key, fallback in color(key) ?? fallback }
        let cursorStyle: String? = (settings["CursorType"] as? Int).map {
            switch $0 {
            case 1: return "underline"
            case 2: return "bar"
            default: return "block"
            }
        }
        return TerminalAppProfile(
            name: name,
            fontName: font?.name,
            fontSize: font?.size,
            background: color("BackgroundColor") ?? "#FFFFFF",
            foreground: color("TextColor") ?? "#000000",
            cursor: color("CursorColor") ?? "#929292",
            selection: color("SelectionColor"),
            ansi: ansi,
            cursorStyle: cursorStyle,
            cursorBlink: settings["CursorBlink"] as? Bool,
            lineSpacing: (settings["LineSpacing"] as? Double).flatMap { $0 > 0 ? $0 : nil }
        )
    }

    /// The font for CSS. Terminal.app's default face, SF Mono Terminal, ships
    /// inside Terminal.app and no other app can load it by name — asking for it
    /// would silently fall back to something else. It is SF Mono, which WebKit
    /// offers to everyone as ui-monospace, so that is what the SF Mono family
    /// maps to; any other face is used by its family name if this Mac has it.
    var cssFontFamily: String? {
        guard let fontName else { return nil }
        if fontName.replacingOccurrences(of: " ", with: "").lowercased().hasPrefix("sfmono") {
            return "ui-monospace"
        }
        guard let family = NSFont(name: fontName, size: 12)?.familyName else { return nil }
        return "\"\(family)\""
    }

    /// The font's name and size straight from the archive, without loading the
    /// font: a face this process cannot load still says what it is, where
    /// unarchiving an NSFont would quietly substitute another one.
    static func archivedFont(_ data: Data) -> (name: String, size: Double)? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else { return nil }
        for case let object as [String: Any] in objects {
            guard let size = (object["NSSize"] as? NSNumber)?.doubleValue,
                  let reference = object["NSName"],
                  let index = archiveIndex(reference), index < objects.count,
                  let name = objects[index] as? String else { continue }
            return (name, size)
        }
        return nil
    }

    /// The index a keyed archive's UID points at. CFKeyedArchiverUID has no
    /// public accessor; its description is stable ("{value = 23}").
    private static func archiveIndex(_ reference: Any) -> Int? {
        let text = String(describing: reference)
        guard let range = text.range(of: "value = ") else { return nil }
        return Int(text[range.upperBound...].prefix { $0.isNumber })
    }

    /// The colours as a scheme the rest of the app already knows how to use.
    var scheme: TerminalScheme {
        TerminalScheme(
            id: TerminalThemeManager.terminalAppSchemeID,
            name: "系统终端",
            detail: "跟随 Terminal.app「\(name)」：字体、字号与配色",
            background: background, foreground: foreground, cursor: cursor,
            ansi: ansi
        )
    }

    static let ansiKeys = [
        "ANSIBlackColor", "ANSIRedColor", "ANSIGreenColor", "ANSIYellowColor",
        "ANSIBlueColor", "ANSIMagentaColor", "ANSICyanColor", "ANSIWhiteColor",
        "ANSIBrightBlackColor", "ANSIBrightRedColor", "ANSIBrightGreenColor", "ANSIBrightYellowColor",
        "ANSIBrightBlueColor", "ANSIBrightMagentaColor", "ANSIBrightCyanColor", "ANSIBrightWhiteColor",
    ]

    /// Terminal.app's palette for a profile that does not override a colour.
    static let basicANSI = [
        "#000000", "#990000", "#00A600", "#999900", "#0000B2", "#B200B2", "#00A6B2", "#BFBFBF",
        "#666666", "#E50000", "#00D900", "#E5E500", "#0000FF", "#E500E5", "#00E5E5", "#E5E5E5",
    ]

    /// Opaque sRGB hex. A translucent profile keeps its colour; an opaque
    /// window cannot honour the alpha anyway.
    static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}
