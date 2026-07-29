import AppKit

// One enabled and one disabled button, each wired to print when its action
// actually fires. The point is the app-side evidence: AXPress on a disabled
// NSButton returns success from the AX API while the button's action never
// runs, so only the probe's own stdout can prove which clicks really landed.
// run.sh redirects that stdout to a log and counts the lines.
final class ClickReporter: NSObject {
    @objc func clicked(_ sender: NSButton) {
        print("CLICKED \(sender.title)")
        // The log is read while this process is still alive; line buffering is
        // not guaranteed when stdout is a file, so flush per event.
        fflush(stdout)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let window = NSWindow(
    contentRect: NSRect(x: 220, y: 220, width: 340, height: 120),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
)
window.title = "amcu ButtonProbe"

let reporter = ClickReporter()

let usable = NSButton(title: "Usable", target: reporter, action: #selector(ClickReporter.clicked(_:)))
usable.frame = NSRect(x: 20, y: 64, width: 140, height: 32)
window.contentView!.addSubview(usable)

let blocked = NSButton(title: "Blocked", target: reporter, action: #selector(ClickReporter.clicked(_:)))
blocked.frame = NSRect(x: 20, y: 24, width: 140, height: 32)
blocked.isEnabled = false
window.contentView!.addSubview(blocked)

window.makeKeyAndOrderFront(nil)
app.run()
