import AppKit

// Two labelled NSComboBoxes, one focused and one not. A label is what makes
// tree shaping want to suppress a combo's subtree. The focused one checks
// that the focus ancestry chain defeats suppression; the *unfocused* one is
// the sharper probe — with no focus to hide behind, only the actionable-child
// rule can keep its internal drop-down button (the only way to open the list)
// visible.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let window = NSWindow(
    contentRect: NSRect(x: 240, y: 240, width: 340, height: 120),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
)
window.title = "amcu ComboProbe"
// The window-chrome buttons are hidden so "a Button is visible" can only be
// satisfied by the combo box's own drop-down button, not by the close button.
for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
    window.standardWindowButton(kind)?.isHidden = true
}

let focusedCombo = NSComboBox(frame: NSRect(x: 20, y: 64, width: 300, height: 26))
focusedCombo.addItems(withObjectValues: ["Alpha", "Beta", "Gamma"])
focusedCombo.placeholderString = "Choose an item"
focusedCombo.setAccessibilityLabel("Flavour")
window.contentView!.addSubview(focusedCombo)

let idleCombo = NSComboBox(frame: NSRect(x: 20, y: 24, width: 300, height: 26))
idleCombo.addItems(withObjectValues: ["Sprinkles", "Fudge", "None"])
idleCombo.placeholderString = "Choose an item"
idleCombo.setAccessibilityLabel("Topping")
window.contentView!.addSubview(idleCombo)

window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(focusedCombo)
app.run()
