import AppKit

// One focused NSTextField: the minimum surface for exercising set-value's
// read-back verification and replace's selection scoping against a real
// AppKit field editor rather than a mock.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let window = NSWindow(
    contentRect: NSRect(x: 160, y: 160, width: 340, height: 120),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
)
window.title = "amcu TextProbe"

let field = NSTextField(frame: NSRect(x: 20, y: 48, width: 300, height: 24))
field.stringValue = "initial"
field.setAccessibilityLabel("Probe Field")
window.contentView!.addSubview(field)

// makeKey (not just orderFront): AXFocused follows the key window's first
// responder, and the whole probe is about having a genuinely focused field.
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(field)
app.run()
