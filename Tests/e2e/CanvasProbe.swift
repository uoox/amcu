import AppKit
import CoreText

// A window that paints its interface itself and tells the accessibility API
// there is nothing inside — the shape of Chromium-less Electron views, game
// UIs and custom canvases. amcu must report such a window as
// accessibility-blind instead of pretending it is empty; the drawn labels are
// there so an optical fallback has something real to recognise.
final class CanvasView: NSView {
    override var isFlipped: Bool { true }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // CoreText directly, bypassing any AppKit text machinery that might
        // helpfully publish accessibility information behind our back.
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let labels = ["保存文档", "Export PDF", "Cancel"]
        for (index, text) in labels.enumerated() {
            let attributed = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.black
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 24, y: bounds.height - CGFloat(48 + index * 36))
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Borderless, because a titled window carries close/miniaturize/zoom buttons —
// real AXButtons with AXPress — and the probe exists to present a window with
// no actionable elements at all.
let window = NSWindow(
    contentRect: NSRect(x: 200, y: 200, width: 320, height: 180),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
window.contentView = CanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
window.orderFrontRegardless()
app.run()
