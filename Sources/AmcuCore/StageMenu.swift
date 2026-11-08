import AppKit
import SwiftUI

/// Text the person at the screen reads, in their language.
enum StageText {
    static let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

    static func t(_ english: String, _ chinese: String) -> String {
        StageText.chinese ? chinese : english
    }
}

/// The menu bar icon and its window (see StageView): the windows on the
/// stage with a live picture each, browser tabs under their window, what the
/// user holds with "hand back", and a way to close the stage. An ordinary
/// window the user can move, resize, minimise and close; the icon brings it
/// up without activating amcu, so the user's application keeps the keyboard
/// until they click the window.
final class StageMenu: NSObject, NSWindowDelegate {
    private static let frameName = "amcu.stage.window"

    private unowned let runtime: StageRuntime
    private let statusItem: NSStatusItem
    private let model = StageViewModel()
    private let thumbnails = StageThumbnails()
    private lazy var window: StageWindowController = {
        let content = StageHostingView(rootView: StageView(model: model, thumbnails: thumbnails))
        content.sizingOptions = [.minSize]
        let window = StageWindowController(content: content)
        window.delegate = self
        return window
    }()
    private let tabQueue = DispatchQueue(label: "amcu.stage.tabs")
    private var fetchingTabs = false
    private var tabsFetched = Date.distantPast
    private var placed = false

    init(runtime: StageRuntime) {
        self.runtime = runtime
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "theatermasks", accessibilityDescription: "amcu stage")
                ?? NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "amcu stage")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(toggle(_:))
        }
        model.takeOver = { [weak self] windowID in
            self?.runtime.takeOverFromMenu(windowID)
            self?.refresh()
        }
        model.takeOverAt = { [weak self] windowID, fraction in
            // The cursor is where the user clicked the thumbnail; the window
            // lands under it and comes in front of this one.
            let cursor = CGEvent(source: nil)?.location ?? .zero
            self?.runtime.takeOver(windowID, grabbedAt: fraction, cursor: cursor)
            self?.refresh()
        }
        model.handBack = { [weak self] windowID in
            self?.runtime.handBack(windowID)
            self?.refresh()
        }
        model.closeStage = { [weak self] in
            self?.hide()
            self?.runtime.stopAndExit(reason: "closed from the menu bar")
        }
    }

    var isShown: Bool { window.isVisible && !window.isMiniaturized }

    /// Called on every change the host makes and on its two-second tick.
    func refresh() {
        let status = runtime.status()
        updateIcon(status)
        guard isShown else { return }
        model.apply(status)
        if status.screenRecording {
            thumbnails.run(status.windows.map { ($0.windowID, $0.frame.cgRect.size) })
        } else {
            thumbnails.stop()
        }
        fetchTabs(for: status.windows)
    }

    private func updateIcon(_ status: StageStatus) {
        guard let button = statusItem.button else { return }
        let count = status.windows.count
        let held = status.takenOver.count
        var title = count > 0 ? " \(count)" : ""
        // Something the user holds is something an agent waits for.
        if held > 0 { title += " · ↩︎\(held)" }
        button.title = title
        var tip = StageText.t(
            "amcu stage: \(count) window\(count == 1 ? "" : "s") on a display you cannot see — click to watch",
            "amcu 舞台：\(count) 个窗口在一块你看不到的屏上，点开查看"
        )
        if held > 0 {
            tip += StageText.t(
                "; you hold \(held) — amcu waits until you hand \(held == 1 ? "it" : "them") back",
                "；你接管着 \(held) 个，amcu 等你交还"
            )
        }
        button.toolTip = tip
    }

    /// Browsers answer over a socket, so off the main thread, one request at
    /// a time and not more often than the tick.
    private func fetchTabs(for windows: [StageWindow]) {
        guard !fetchingTabs, Date().timeIntervalSince(tabsFetched) >= 1.5 else { return }
        guard !windows.isEmpty else {
            model.setBrowser([:])
            return
        }
        fetchingTabs = true
        tabQueue.async { [weak self] in
            let browser = StageTabs.collect(for: windows)
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetchingTabs = false
                self.tabsFetched = Date()
                if self.isShown { self.model.setBrowser(browser) }
            }
        }
    }

    /// The icon always brings the window up — out of the Dock if minimised,
    /// to the front if behind others — rather than toggling it away.
    @objc private func toggle(_ sender: Any?) {
        show()
    }

    func show() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        place()
        // Not makeKeyAndOrderFront: that would take the keyboard from the
        // user's application. Clicking the window activates it, as usual.
        window.orderFrontRegardless()
        refresh()
    }

    func hide() {
        thumbnails.stop()
        window.orderOut(nil)
    }

    /// Where the user left it last time, even in an earlier stage; the very
    /// first time just below the menu bar icon.
    private func place() {
        guard !placed else { return }
        placed = true
        defer { _ = window.setFrameAutosaveName(StageMenu.frameName) }
        if window.setFrameUsingName(StageMenu.frameName) { return }
        var frame = window.frame
        guard let button = statusItem.button, let buttonWindow = button.window else { window.center(); return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        // Right after the host starts, the icon may not be laid out yet and
        // reports a spot that is not in the menu bar; then top right instead.
        let inMenuBar = anchor.width > 0 && anchor.minY >= visible.maxY - 2
        frame.origin = inMenuBar
            ? NSPoint(x: anchor.midX - frame.width / 2, y: anchor.minY - frame.height - 6)
            : NSPoint(x: visible.maxX - frame.width - 16, y: visible.maxY - frame.height - 8)
        frame.origin.x = min(max(frame.origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        frame.origin.y = max(frame.origin.y, visible.minY + 8)
        window.setFrame(frame, display: true)
    }

    // The pictures run only while someone can see them.
    func windowWillClose(_ notification: Notification) { thumbnails.stop() }
    func windowDidMiniaturize(_ notification: Notification) { thumbnails.stop() }
    func windowDidDeminiaturize(_ notification: Notification) { refresh() }

    func uninstall() {
        hide()
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

/// An ordinary titled window: move, resize, minimise, close. It does not
/// activate amcu when it appears; clicking it does, like any window. The
/// content runs under a transparent title bar.
final class StageWindowController: NSWindow {
    init(content: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        title = "amcu " + StageText.t("stage", "舞台")
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.fullScreenAuxiliary]
        contentView = content
        contentMinSize = NSSize(width: 380, height: 360)
    }
}
