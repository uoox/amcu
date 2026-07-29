import AppKit

// A 200-row table scrolled to row 150 before amcu looks at it. The scroll is
// the whole point: viewport culling once compared rows against the table's own
// frame — which spans all content, so every row "intersected" it and the
// snapshot kept ROW-0..ROW-19 instead of what was on screen. Only a genuinely
// scrolled window can catch that class of bug.
final class Rows: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 200 }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        "ROW-\(row)"
    }
}

let app = NSApplication.shared
// Accessory: visible to the window server and the AX API, but never in the
// Dock and never stealing focus — probes must not disturb the user's session
// beyond the pixels they occupy.
app.setActivationPolicy(.accessory)

let window = NSWindow(
    contentRect: NSRect(x: 120, y: 120, width: 420, height: 400),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
)
window.title = "amcu TableProbe"

let table = NSTableView(frame: .zero)
let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
column.width = 380
table.addTableColumn(column)
table.headerView = nil
let rows = Rows()
table.dataSource = rows

let scroll = NSScrollView(frame: window.contentView!.bounds)
scroll.autoresizingMask = [.width, .height]
scroll.hasVerticalScroller = true
scroll.documentView = table
window.contentView!.addSubview(scroll)
table.reloadData()

window.orderFrontRegardless()
// After the run loop starts, so layout has real geometry to scroll within.
DispatchQueue.main.async { table.scrollRowToVisible(150) }
app.run()
