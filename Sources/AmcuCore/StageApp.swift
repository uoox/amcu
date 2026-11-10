import AppKit
import SwiftUI

enum StageText {
    static let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

    static func t(_ english: String, _ chinese: String) -> String {
        StageText.chinese ? chinese : english
    }
}

private func t(_ english: String, _ chinese: String) -> String {
    StageText.t(english, chinese)
}

final class StageApp: NSObject, NSWindowDelegate, NSMenuItemValidation {
    private static let frameName = "amcu.stage.app.window"

    private unowned let runtime: StageRuntime
    let model = StageViewModel()
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
    private var confirming = false
    private var windowMenu = NSMenu()
    private var viewItems: (top: NSMenuItem, left: NSMenuItem)?
    private var tabItems: [NSMenuItem] = []
    private var tabSignature: [String] = []

    init(runtime: StageRuntime, tabs: StageState.Tabs?) {
        self.runtime = runtime
        super.init()
        if let tabs { model.restore(order: tabs.order, selected: tabs.selected) }
        model.takeOver = { [weak self] windowID in
            self?.runtime.takeOverFromMenu(windowID)
            self?.refresh()
        }
        model.takeOverAt = { [weak self] windowID, fraction in
            let cursor = CGEvent(source: nil)?.location ?? .zero
            self?.runtime.takeOver(windowID, grabbedAt: fraction, cursor: cursor)
            self?.refresh()
        }
        model.focusHeld = { [weak self] windowID in
            self?.runtime.focusHeld(windowID)
        }
        model.handBack = { [weak self] windowID in
            self?.runtime.handBack(windowID)
            self?.refresh()
        }
        model.free = { [weak self] windowID in
            self?.runtime.free(windowID)
            self?.refresh()
        }
        model.handBackAll = { [weak self] in
            self?.runtime.handBackAll()
            self?.refresh()
        }
        model.releaseAll = { [weak self] in
            self?.runtime.freeAll()
            self?.refresh()
        }
        model.answer = { [weak self] id in
            self?.runtime.end(ask: id, .done)
            self?.refresh()
        }
        model.closeStage = { [weak self] in
            self?.confirmClose { [weak self] in
                self?.hide()
                self?.runtime.stopAndExit(reason: "closed from the stage window")
            }
        }
        model.selectionChanged = { [weak self] in
            self?.refresh()
            self?.runtime.tabsChanged()
        }
        model.layoutChanged = { [weak self] in
            self?.updateViewItems()
        }
        NSApp.applicationIconImage = StageIcon.image()
        installMainMenu()
    }

    var isShown: Bool { window.isVisible && !window.isMiniaturized }

    var isInUse: Bool { isShown && window.isKeyWindow }

    var tabs: StageState.Tabs { StageState.Tabs(order: model.windowOrder, selected: model.selected) }

    func refresh() {
        let status = runtime.status()
        model.apply(status)
        updateTabItems()
        let open = status.asks.filter(\.isOpen).count
        let badge = open > 0 ? "\(open)" : nil
        if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }
        guard isShown else { return }
        let pictured = model.selectedCard.map { [(id: $0.window, size: $0.size)] } ?? []
        if status.screenRecording {
            thumbnails.run(pictured)
        } else {
            thumbnails.stop()
        }
        fetchTabs(for: status.windows.map { (windowID: CGWindowID($0.windowID), pid: $0.pid) } + status.takenOver.map { (windowID: CGWindowID($0.windowID), pid: $0.pid) })
    }

    func present(_ entry: StageActivity) {
        model.add(entry)
    }

    func asked(_ ask: StageAsk) {
        refresh()
        if !isInUse { model.select(CGWindowID(ask.windowID)) }
        NSApp.requestUserAttention(.informationalRequest)
    }

    private func fetchTabs(for windows: [(windowID: CGWindowID, pid: pid_t)]) {
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
                self.runtime.updateTabPairing(browser)
                self.model.setBrowser(browser)
            }
        }
    }

    func show(activate: Bool = false) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        place()
        model.load(runtime.shownActivity)
        if activate {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
        model.adopt(window.chrome)
        refresh()
    }

    func hide() {
        thumbnails.stop()
        window.orderOut(nil)
    }

    private func place() {
        if !placed {
            placed = true
            let restored = window.setFrameUsingName(StageApp.frameName)
            _ = window.setFrameAutosaveName(StageApp.frameName)
            if restored, StageApp.seenByUser(window.frame) { return }
        } else if StageApp.seenByUser(window.frame) {
            return
        }
        guard let visible = NSScreen.screens.first(where: { !StageApp.isStage($0) })?.visibleFrame else { return }
        let size = NSSize(width: min(1280, visible.width - 80), height: min(860, visible.height - 60))
        window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height), display: true)
    }

    func screensChanged() {
        if isShown { place() }
    }

    private static func seenByUser(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { !isStage($0) && $0.frame.intersects(frame) }
    }

    private static func isStage(_ screen: NSScreen) -> Bool {
        Stage.identity.matches((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
    }

    func reopen() {
        show(activate: true)
    }

    func select(windowID: CGWindowID, activate: Bool) {
        model.select(windowID)
        show(activate: activate)
    }

    func uninstall() {
        hide()
    }

    // MARK: - Closing the stage

    func confirmClose(then: @escaping () -> Void) {
        let status = runtime.status()
        let count = status.windows.count + status.takenOver.count
        guard count > 0 else {
            then()
            return
        }
        guard !confirming else { return }
        confirming = true
        show(activate: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("Close the stage?", "关闭舞台？")
        alert.informativeText = t(
            "The \(count) window\(count == 1 ? "" : "s") on it go back to your screen, and agents working in them are interrupted. To put this window away and keep the stage running, close the window instead (⌘W).",
            "舞台上的 \(count) 个窗口会回到你的屏幕，正在操作它们的 agent 会被打断。只想收起这个窗口的话，关掉窗口就行（⌘W），舞台照常运行。"
        )
        let close = alert.addButton(withTitle: t("Close Stage", "关闭舞台"))
        close.hasDestructiveAction = true
        alert.addButton(withTitle: t("Cancel", "取消")).keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.confirming = false
            if response == .alertFirstButtonReturn { then() }
        }
    }

    // MARK: - Menus

    private func installMainMenu() {
        let main = NSMenu()
        main.addItem(holder(for: appMenu(), title: "amcu"))
        main.addItem(holder(for: stageMenu(), title: t("Stage", "舞台")))
        main.addItem(holder(for: viewMenu(), title: t("View", "显示")))
        windowMenu = buildWindowMenu()
        main.addItem(holder(for: windowMenu, title: t("Window", "窗口")))
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    private func holder(for menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target ?? (action.map { responds(to: $0) } == true ? self : nil)
        return item
    }

    private func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(t("About amcu", "关于 amcu"), #selector(about(_:))))
        menu.addItem(.separator())
        menu.addItem(item(t("Hide amcu", "隐藏 amcu"), #selector(NSApplication.hide(_:)), "h", target: NSApp))
        menu.addItem(item(t("Hide Others", "隐藏其他"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp))
        menu.addItem(item(t("Show All", "全部显示"), #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
        menu.addItem(.separator())
        menu.addItem(item(t("Quit amcu and Close the Stage", "退出 amcu 并关闭舞台"), #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        return menu
    }

    private func stageMenu() -> NSMenu {
        let menu = NSMenu()
        let takeOver = item(t("Take Over This Window", "接管这个窗口"), #selector(takeOverSelected(_:)), "\r")
        let handBack = item(t("Hand This Window Back", "交还这个窗口"), #selector(handBackSelected(_:)), "\r", [.command, .shift])
        let free = item(t("Release This Window", "释放这个窗口"), #selector(freeSelected(_:)))
        let handBackAll = item(t("Hand Back All", "全部交还"), #selector(handBackAll(_:)))
        let releaseAll = item(t("Release All", "全部释放"), #selector(releaseAll(_:)))
        let close = item(t("Close Stage…", "关闭舞台…"), #selector(closeStage(_:)))
        [takeOver, handBack, free].forEach(menu.addItem)
        menu.addItem(.separator())
        [handBackAll, releaseAll].forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(close)
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu()
        let top = item(t("Tabs on Top", "标签放在顶部"), #selector(tabsOnTop(_:)))
        let left = item(t("Tabs on the Left", "标签放在左侧"), #selector(tabsOnLeft(_:)))
        viewItems = (top, left)
        menu.addItem(top)
        menu.addItem(left)
        menu.addItem(.separator())
        menu.addItem(item(t("Enter Full Screen", "进入全屏幕"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], target: nil))
        updateViewItems()
        return menu
    }

    private func buildWindowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(t("Minimize", "最小化"), #selector(NSWindow.performMiniaturize(_:)), "m", target: nil))
        menu.addItem(item(t("Zoom", "缩放"), #selector(NSWindow.performZoom(_:)), target: nil))
        menu.addItem(item(t("Close Window", "关闭窗口"), #selector(NSWindow.performClose(_:)), "w", target: nil))
        menu.addItem(.separator())
        menu.addItem(item(t("Show Next Tab", "下一个标签"), #selector(nextTab(_:)), "]", [.command, .shift]))
        menu.addItem(item(t("Show Previous Tab", "上一个标签"), #selector(previousTab(_:)), "[", [.command, .shift]))
        for (key, modifiers, selector) in [("\t", NSEvent.ModifierFlags.control, #selector(nextTab(_:))), ("\t", [.control, .shift], #selector(previousTab(_:))),
                                           (String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option], #selector(nextTab(_:))),
                                           (String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option], #selector(previousTab(_:)))] {
            let hidden = item("", selector, key, modifiers)
            hidden.isHidden = true
            hidden.allowsKeyEquivalentWhenHidden = true
            menu.addItem(hidden)
        }
        let last = item("", #selector(lastTab(_:)), "9")
        last.isHidden = true
        last.allowsKeyEquivalentWhenHidden = true
        menu.addItem(last)
        menu.addItem(.separator())
        menu.addItem(item(t("Bring All to Front", "前置全部窗口"), #selector(NSApplication.arrangeInFront(_:)), target: NSApp))
        return menu
    }

    private func updateViewItems() {
        viewItems?.top.state = model.tabsOnLeft ? .off : .on
        viewItems?.left.state = model.tabsOnLeft ? .on : .off
    }

    private func updateTabItems() {
        let signature = model.cards.map { "\($0.id)|\($0.title)|\($0.app)" }
        guard signature != tabSignature else { return }
        tabSignature = signature
        tabItems.forEach(windowMenu.removeItem)
        tabItems = []
        guard !model.cards.isEmpty, let anchor = windowMenu.items.lastIndex(where: { $0.isSeparatorItem }) else { return }
        var index = anchor + 1
        for (number, card) in model.cards.enumerated() {
            let title = card.title.isEmpty || card.title == card.app ? card.app : "\(card.app) — \(card.title)"
            let entry = item(StageActivity.clip(title, 60), #selector(selectTab(_:)), number < 8 ? String(number + 1) : "")
            entry.tag = Int(card.id)
            windowMenu.insertItem(entry, at: index)
            tabItems.append(entry)
            index += 1
        }
        let separator = NSMenuItem.separator()
        windowMenu.insertItem(separator, at: index)
        tabItems.append(separator)
    }

    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(t("Show Stage Window", "显示舞台窗口"), #selector(showWindow(_:))))
        if !model.cards.isEmpty {
            menu.addItem(.separator())
            for card in model.cards {
                let name = StageActivity.clip(card.title.isEmpty ? card.app : card.title, 48)
                let mark = card.ask != nil ? t(" · needs you", " · 需要你") : card.held ? t(" · you hold it", " · 你接管着") : ""
                let entry = item(name + mark, #selector(selectFromDock(_:)))
                entry.tag = Int(card.id)
                entry.image = model.icon(for: card).resizedForMenu()
                menu.addItem(entry)
            }
        }
        if model.summary.held > 0 {
            menu.addItem(.separator())
            menu.addItem(item(t("Hand Back All", "全部交还"), #selector(handBackAll(_:))))
            menu.addItem(item(t("Release All", "全部释放"), #selector(releaseAll(_:))))
        }
        return menu
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let card = model.selectedCard
        switch item.action {
        case #selector(takeOverSelected(_:)): return card != nil && card?.heldSince == nil
        case #selector(handBackSelected(_:)), #selector(freeSelected(_:)): return card?.heldSince != nil
        case #selector(handBackAll(_:)), #selector(releaseAll(_:)): return model.summary.held > 0
        case #selector(nextTab(_:)), #selector(previousTab(_:)), #selector(lastTab(_:)): return model.cards.count > 1
        default: return true
        }
    }

    @objc private func about(_ sender: Any?) {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "amcu",
            .applicationVersion: AmcuVersion.string,
            .version: "",
            .applicationIcon: StageIcon.image(),
            .credits: NSAttributedString(string: t("The stage: windows agents drive, on a display you never see.", "舞台：agent 操作的窗口放在一块你看不到的屏上。"))
        ])
    }

    @objc private func showWindow(_ sender: Any?) { show(activate: true) }
    @objc private func selectFromDock(_ sender: NSMenuItem) { select(windowID: CGWindowID(sender.tag), activate: true) }
    @objc private func selectTab(_ sender: NSMenuItem) { select(windowID: CGWindowID(sender.tag), activate: true) }
    @objc private func nextTab(_ sender: Any?) { model.step(1) }
    @objc private func previousTab(_ sender: Any?) { model.step(-1) }
    @objc private func lastTab(_ sender: Any?) { if let last = model.cards.last { model.select(last.id) } }
    @objc private func tabsOnTop(_ sender: Any?) { model.tabsOnLeft = false }
    @objc private func tabsOnLeft(_ sender: Any?) { model.tabsOnLeft = true }
    @objc private func takeOverSelected(_ sender: Any?) { if let card = model.selectedCard { model.takeOver(card.window) } }
    @objc private func handBackSelected(_ sender: Any?) { if let card = model.selectedCard { model.handBack(card.window) } }
    @objc private func freeSelected(_ sender: Any?) { if let card = model.selectedCard { model.free(card.window) } }
    @objc private func handBackAll(_ sender: Any?) { model.handBackAll() }
    @objc private func releaseAll(_ sender: Any?) { model.releaseAll() }
    @objc private func closeStage(_ sender: Any?) { model.closeStage() }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        thumbnails.stop()
        runtime.tabsChanged()
    }

    func windowDidMiniaturize(_ notification: Notification) { thumbnails.stop() }
    func windowDidDeminiaturize(_ notification: Notification) { refresh() }
    func windowDidEnterFullScreen(_ notification: Notification) { model.fullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        model.fullScreen = false
        model.adopt(window.chrome)
    }
}

private extension NSImage {
    func resizedForMenu() -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            self.draw(in: rect)
            return true
        }
        return image
    }
}

struct StageChrome: Equatable {
    var leading: CGFloat = 78
    var center: CGFloat = 14
}

final class StageWindowController: NSWindow {
    init(content: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        title = "amcu " + StageText.t("Stage", "舞台")
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        tabbingMode = .disallowed
        collectionBehavior = [.fullScreenPrimary]
        contentView = content
        contentMinSize = NSSize(width: 620, height: 420)
    }

    var chrome: StageChrome {
        guard let close = standardWindowButton(.closeButton), let zoom = standardWindowButton(.zoomButton) else { return StageChrome() }
        let closeFrame = close.convert(close.bounds, to: nil)
        let zoomFrame = zoom.convert(zoom.bounds, to: nil)
        guard closeFrame.height > 0, zoomFrame.maxX > 0 else { return StageChrome() }
        return StageChrome(leading: (zoomFrame.maxX + 14).rounded(), center: (frame.height - closeFrame.midY).rounded())
    }
}

final class StageHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
