import AppKit
import CoreText

enum NativeTheme {
    static let accent = dynamic(light: NSColor(calibratedRed: 0.059, green: 0.463, blue: 0.431, alpha: 1),
                                dark: NSColor(calibratedRed: 0.176, green: 0.831, blue: 0.749, alpha: 1))
    static let accentSoft = dynamic(light: NSColor(calibratedRed: 0.902, green: 0.973, blue: 0.965, alpha: 1),
                                    dark: NSColor(calibratedRed: 0.055, green: 0.180, blue: 0.173, alpha: 1))
    static let violet = dynamic(light: NSColor(calibratedRed: 0.427, green: 0.247, blue: 0.820, alpha: 1),
                                dark: NSColor(calibratedRed: 0.737, green: 0.647, blue: 0.969, alpha: 1))
    static let violetSoft = dynamic(light: NSColor(calibratedRed: 0.945, green: 0.925, blue: 1, alpha: 1),
                                    dark: NSColor(calibratedRed: 0.141, green: 0.122, blue: 0.271, alpha: 1))
    static let sidebar = dynamic(light: NSColor(calibratedWhite: 0.985, alpha: 1),
                                 dark: NSColor(calibratedRed: 0.063, green: 0.094, blue: 0.153, alpha: 1))
    static let content = dynamic(light: NSColor(calibratedRed: 0.961, green: 0.973, blue: 0.988, alpha: 1),
                                 dark: NSColor(calibratedRed: 0.043, green: 0.067, blue: 0.125, alpha: 1))
    static let card = dynamic(light: NSColor.white,
                              dark: NSColor(calibratedRed: 0.071, green: 0.110, blue: 0.180, alpha: 1))
    static let cardHover = dynamic(light: NSColor(calibratedRed: 0.941, green: 0.957, blue: 0.976, alpha: 1),
                                   dark: NSColor(calibratedRed: 0.102, green: 0.149, blue: 0.227, alpha: 1))
    static let border = dynamic(light: NSColor(calibratedRed: 0.859, green: 0.890, blue: 0.933, alpha: 1),
                                dark: NSColor(calibratedRed: 0.145, green: 0.204, blue: 0.286, alpha: 1))
    static let primaryText = dynamic(light: NSColor(calibratedRed: 0.071, green: 0.106, blue: 0.169, alpha: 1),
                                     dark: NSColor(calibratedRed: 0.878, green: 0.914, blue: 0.953, alpha: 1))
    static let secondaryText = dynamic(light: NSColor(calibratedRed: 0.361, green: 0.427, blue: 0.522, alpha: 1),
                                       dark: NSColor(calibratedRed: 0.553, green: 0.635, blue: 0.725, alpha: 1))
    static let terminalBackground = NSColor(calibratedRed: 0.031, green: 0.051, blue: 0.090, alpha: 1)
    static let terminalHeader = NSColor(calibratedRed: 0.055, green: 0.090, blue: 0.149, alpha: 1)

    static func symbol(_ name: String, size: CGFloat = 14, weight: NSFont.Weight = .regular) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// Creates a terminal font with an explicit CJK fallback cascade list.
    /// Without this, Menlo alone cannot render Chinese/Japanese/Korean characters,
    /// which appear as white block tofu glyphs.
    /// `postScriptName` picks the base family (settings picker); any family
    /// that fails to resolve falls back to Menlo, then the system monospaced.
    static func terminalFont(size: CGFloat = 13, postScriptName: String? = nil) -> NSFont {
        let baseFont = postScriptName.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont(name: "Menlo-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)

        // Build a cascade list of CJK-capable fonts so CoreText can find
        // glyphs for characters not covered by Menlo.
        let cascadeNames = [
            "PingFang SC",        // Simplified Chinese (macOS built-in)
            "PingFang TC",        // Traditional Chinese
            "PingFang HK",        // Hong Kong Traditional Chinese
            "Hiragino Sans",      // Japanese
            "Apple SD Gothic Neo", // Korean
            "Apple Color Emoji",  // Emoji
        ]
        var cascadeDescriptors: [CTFontDescriptor] = []
        for name in cascadeNames {
            let attrs = [kCTFontFamilyNameAttribute: name] as CFDictionary
            cascadeDescriptors.append(CTFontDescriptorCreateWithAttributes(attrs))
        }

        let baseCT = baseFont as CTFont
        let baseDesc = CTFontCopyFontDescriptor(baseCT)
        let newAttrs = [kCTFontCascadeListAttribute: cascadeDescriptors] as CFDictionary
        let newDesc = CTFontDescriptorCreateCopyWithAttributes(baseDesc, newAttrs)
        let cascadedCT = CTFontCreateWithFontDescriptor(newDesc, size, nil)

        return cascadedCT as NSFont
    }

    static func panel(radius: CGFloat = 12) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.backgroundColor = card.cgColor
        view.layer?.borderColor = border.cgColor
        view.layer?.borderWidth = 1
        return view
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}
