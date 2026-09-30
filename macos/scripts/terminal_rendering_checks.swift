import AppKit
import CoreText

@main
struct TerminalRenderingChecks {
    static func makeView() -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 720, height: 240), font: NativeTheme.terminalFont(size: 20))
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        return view
    }

    static func checkContinuation(_ view: TerminalView, column: Int, row: Int) {
        let terminal = view.getTerminal()
        let character = terminal.getCharData(col: column, row: row)!
        let continuation = terminal.getCharData(col: column + 1, row: row)!
        precondition(character.width == 2, "Expected a double-width character")
        precondition(continuation.code == 0, "Expected an empty continuation cell")
        precondition(continuation.attribute == character.attribute, "Wide-character continuation lost its colors or style")
    }

    static func main() throws {
        _ = NSApplication.shared
        for style in ["", "1", "3", "4", "7", "31;44", "1;7;35;46"] {
            let view = makeView()
            view.feed(text: "\u{1b}[\(style)mA中B")
            checkContinuation(view, column: 1, row: 0)
        }
        let wrapped = makeView()
        wrapped.getTerminal().resize(cols: 3, rows: 10)
        wrapped.feed(text: "\u{1b}[44mAB中")
        checkContinuation(wrapped, column: 0, row: 1)
        let inserted = makeView()
        inserted.feed(text: "abcdef\r\u{1b}[4h\u{1b}[44m中")
        checkContinuation(inserted, column: 0, row: 0)

        let view = makeView()
        view.feed(text: "ABC 中文测试 DEF\r\n\u{1b}[4mABC 中文下划线 DEF\u{1b}[0m\r\n\u{1b}[7mABC 中文反色 DEF\u{1b}[0m\r\n中文 👩‍💻 e\u{301} 𠀀 DEF\r\n")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 720, pixelsHigh: 240, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.setFillColor(NSColor.black.cgColor)
        graphics.cgContext.fill(view.bounds)
        view.drawTerminalContents(dirtyRect: view.bounds, context: graphics.cgContext, bufferOffset: 0)
        NSGraphicsContext.restoreGraphicsState()
        let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/private/tmp/agentbox-terminal-render-after.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))

        func brightPixels(column: Int, row: Int) -> (count: Int, total: Int) {
            let left = Int(ceil(CGFloat(column) * view.cellDimension.width))
            let right = Int(floor(CGFloat(column + 1) * view.cellDimension.width))
            let top = Int(CGFloat(row) * view.cellDimension.height)
            let bottom = Int(CGFloat(row + 1) * view.cellDimension.height)
            var count = 0
            for vertical in top..<bottom {
                for horizontal in left..<right {
                    let color = bitmap.colorAt(x: horizontal, y: vertical)!.usingColorSpace(.deviceRGB)!
                    if color.redComponent > 0.7 && color.greenComponent > 0.7 && color.blueComponent > 0.7 {
                        count += 1
                    }
                }
            }
            return (count, (right - left) * (bottom - top))
        }
        for column in 4..<12 {
            let pixels = brightPixels(column: column, row: 0)
            precondition(Double(pixels.count) / Double(pixels.total) < 0.8, "Unexpected white block in column \(column)")
        }
        precondition(brightPixels(column: 3, row: 0).count == 0, "Expected a blank normal space")
        precondition(brightPixels(column: 3, row: 1).count > 0, "Underline disappeared on a Chinese line")
        print("PASS: continuation colors/styles, wrapping, insert mode, Chinese white-block and underline checks")
        print("Rendering image: \(output)")
    }
}
