import AppKit
import SwiftUI

final class StageViewModel: ObservableObject {
    struct Card: Identifiable, Equatable {
        let id: CGWindowID
        let pid: pid_t
        let app: String
        let bundleID: String?
        let title: String
        let size: CGSize
        let origin: StageWindow.Origin
        let heldSince: Date?

        var foreign: Bool { origin == .found }
        var name: String { title.isEmpty ? app : title }
    }

    struct Summary: Equatable {
        var stage: CGSize = .zero
        var pullbacks = 0
        var screenRecording = true
        var answersFor: String?
        var following: [String] = []
        var onStage = 0
        var held = 0
    }

    static let leftKey = "amcu.stage.tabsOnLeft"
    static let kept = 12

    @Published private(set) var summary = Summary()
    @Published private(set) var cards: [Card] = []
    @Published private(set) var selected: CGWindowID?
    @Published private(set) var browser: [CGWindowID: StageTabs.Paired] = [:]
    @Published private(set) var activity: [CGWindowID: [StageActivity]] = [:]
    @Published private(set) var chrome = StageChrome()
    @Published var fullScreen = false
    @Published var tabsOnLeft: Bool {
        didSet {
            guard tabsOnLeft != oldValue else { return }
            if persistsLayout { UserDefaults.standard.set(tabsOnLeft, forKey: StageViewModel.leftKey) }
            layoutChanged()
        }
    }

    var takeOver: (CGWindowID) -> Void = { _ in }
    var takeOverAt: (CGWindowID, CGPoint) -> Void = { _, _ in }
    var focusHeld: (CGWindowID) -> Void = { _ in }
    var handBack: (CGWindowID) -> Void = { _ in }
    var free: (CGWindowID) -> Void = { _ in }
    var handBackAll: () -> Void = {}
    var releaseAll: () -> Void = {}
    var closeStage: () -> Void = {}
    var selectionChanged: () -> Void = {}
    var layoutChanged: () -> Void = {}

    private let persistsLayout: Bool
    private var order: [CGWindowID] = []
    private var icons: [pid_t: NSImage] = [:]

    init(tabsOnLeft: Bool? = nil) {
        persistsLayout = tabsOnLeft == nil
        self.tabsOnLeft = tabsOnLeft ?? UserDefaults.standard.bool(forKey: StageViewModel.leftKey)
    }

    var selectedCard: Card? { cards.first { $0.id == selected } }

    func restore(order: [CGWindowID], selected: CGWindowID?) {
        self.order = order
        self.selected = selected
    }

    func apply(_ status: StageStatus) {
        var byID: [CGWindowID: Card] = [:]
        for window in status.windows {
            byID[window.windowID] = Card(id: window.windowID, pid: window.pid, app: window.app, bundleID: window.bundleID, title: window.title ?? "", size: window.frame.cgRect.size, origin: window.origin, heldSince: nil)
        }
        for held in status.takenOver {
            byID[held.windowID] = Card(id: held.windowID, pid: held.pid, app: held.app, bundleID: held.bundleID, title: held.title ?? "", size: held.stageFrame.cgRect.size, origin: .put, heldSince: held.since)
        }
        let before = cards.isEmpty ? order : cards.map(\.id)
        order = StageTabOrder.merged(order, present: status.windows.map(\.windowID) + status.takenOver.map(\.windowID))
        let cards = order.compactMap { byID[$0] }
        if cards != self.cards { self.cards = cards }
        let chosen = StageTabOrder.selection(selected, previous: before, now: order)
        if chosen != selected { selected = chosen }
        activity = activity.filter { byID[$0.key] != nil }
        let summary = Summary(
            stage: status.bounds.cgRect.size,
            pullbacks: status.cursorPullbacks,
            screenRecording: status.screenRecording,
            answersFor: status.answersFor,
            following: status.following.map(\.app),
            onStage: status.windows.count,
            held: status.takenOver.count
        )
        if summary != self.summary { self.summary = summary }
    }

    func select(_ id: CGWindowID) {
        guard selected != id, cards.contains(where: { $0.id == id }) else { return }
        selected = id
        selectionChanged()
    }

    func step(_ delta: Int) {
        guard !cards.isEmpty else { return }
        let index = cards.firstIndex { $0.id == selected } ?? 0
        select(cards[((index + delta) % cards.count + cards.count) % cards.count].id)
    }

    func adopt(_ chrome: StageChrome) {
        if chrome != self.chrome { self.chrome = chrome }
    }

    func add(_ entry: StageActivity) {
        guard let id = entry.windowID else { return }
        var list = activity[id] ?? []
        list.removeAll { $0.seq == entry.seq }
        list.insert(entry, at: 0)
        activity[id] = Array(list.prefix(StageViewModel.kept))
    }

    func load(_ entries: [StageActivity]) {
        var grouped: [CGWindowID: [StageActivity]] = [:]
        for entry in entries.sorted(by: { $0.at > $1.at }) {
            guard let id = entry.windowID, (grouped[id]?.count ?? 0) < StageViewModel.kept else { continue }
            grouped[id, default: []].append(entry)
        }
        activity = grouped
    }

    func setBrowser(_ browser: [CGWindowID: StageTabs.Paired]) {
        if browser != self.browser { self.browser = browser }
    }

    func icon(for card: Card) -> NSImage {
        if let icon = icons[card.pid] { return icon }
        let icon = NSRunningApplication(processIdentifier: card.pid)?.icon
            ?? card.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .application)
        icons[card.pid] = icon
        return icon
    }

    func isWorking(_ id: CGWindowID, at date: Date) -> Bool {
        guard let last = activity[id]?.first else { return false }
        return date.timeIntervalSince(last.at) < 15
    }

    func tooltip(for card: Card) -> String {
        var lines = [[card.app, browser[card.id]?.profile].compactMap { $0 }.joined(separator: " · ")]
        if !card.title.isEmpty, card.title != card.app { lines.append(card.title) }
        if let since = card.heldSince {
            lines.append(t("You hold it, since \(StageClock.minutes.string(from: since))", "你接管着，\(StageClock.minutes.string(from: since)) 起"))
        } else if card.foreign {
            lines.append(t("Not put here by amcu", "不是 amcu 放上来的"))
        }
        return lines.joined(separator: "\n")
    }
}

public enum StageTabOrder {
    public static func merged(_ order: [CGWindowID], present: [CGWindowID]) -> [CGWindowID] {
        let here = Set(present)
        var result = order.filter(here.contains)
        var seen = Set(result)
        for id in present where !seen.contains(id) {
            result.append(id)
            seen.insert(id)
        }
        return result
    }

    public static func selection(_ selected: CGWindowID?, previous: [CGWindowID], now: [CGWindowID]) -> CGWindowID? {
        guard !now.isEmpty else { return nil }
        if let selected, now.contains(selected) { return selected }
        if let selected, let index = previous.firstIndex(of: selected) {
            if let after = previous[(index + 1)...].first(where: now.contains) { return after }
            if let before = previous[..<index].last(where: now.contains) { return before }
        }
        return now.first
    }
}

public enum StageTabLayout {
    public static let topMaximum: CGFloat = 240
    public static let topMinimum: CGFloat = 96
    public static let topSpacing: CGFloat = 4
    public static let tabHeight: CGFloat = 26
    public static let sidebarWidth: CGFloat = 248
    public static let wideInspector: CGFloat = 900
    public static let inspectorWidth: CGFloat = 300

    public static func topWidth(count: Int, room: CGFloat) -> CGFloat {
        guard count > 0 else { return topMaximum }
        let share = (room - topSpacing * CGFloat(count - 1)) / CGFloat(count)
        return max(topMinimum, min(topMaximum, share.rounded(.down)))
    }

    public static func topScrolls(count: Int, room: CGFloat) -> Bool {
        guard count > 0 else { return false }
        return CGFloat(count) * topWidth(count: count, room: room) + topSpacing * CGFloat(count - 1) > room + 0.5
    }

    public static func tabTop(lightsCenter: CGFloat, fullScreen: Bool) -> CGFloat {
        fullScreen ? 5 : max(4, (lightsCenter - tabHeight / 2).rounded())
    }

    public static func stripHeight(lightsCenter: CGFloat, fullScreen: Bool) -> CGFloat {
        let top = tabTop(lightsCenter: lightsCenter, fullScreen: fullScreen)
        return top + tabHeight + max(5, top)
    }
}

private func t(_ english: String, _ chinese: String) -> String {
    StageText.t(english, chinese)
}

enum StagePalette {
    static let background = dynamic(light: NSColor(srgbRed: 0.945, green: 0.945, blue: 0.957, alpha: 1), dark: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.125, alpha: 1))
    static let strip = dynamic(light: NSColor(srgbRed: 0.886, green: 0.886, blue: 0.902, alpha: 1), dark: NSColor(srgbRed: 0.078, green: 0.078, blue: 0.086, alpha: 1))
    static let card = dynamic(light: .white, dark: NSColor(srgbRed: 0.176, green: 0.176, blue: 0.184, alpha: 1))
    static let well = dynamic(light: NSColor(srgbRed: 0.918, green: 0.918, blue: 0.933, alpha: 1), dark: NSColor(srgbRed: 0.255, green: 0.255, blue: 0.267, alpha: 1))
    static let stroke = dynamic(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.white.withAlphaComponent(0.09))

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func tint(for site: String) -> Color {
        let sum = site.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hue: Double(sum % 360) / 360, saturation: 0.5, brightness: 0.72)
    }
}

struct StageView: View {
    @ObservedObject var model: StageViewModel
    @ObservedObject var thumbnails: StageThumbnails

    var body: some View {
        VStack(spacing: 0) {
            if model.tabsOnLeft {
                HStack(spacing: 0) {
                    StageSideTabs(model: model)
                        .frame(width: StageTabLayout.sidebarWidth)
                    Divider()
                    StagePane(model: model, thumbnails: thumbnails, underTitlebar: true)
                }
            } else {
                StageTopTabs(model: model)
                Divider()
                StagePane(model: model, thumbnails: thumbnails, underTitlebar: false)
            }
            Divider()
            StageStatusBar(model: model)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 620, minHeight: 420)
        .background(StagePalette.background.ignoresSafeArea())
    }
}

private struct StageTopTabs: View {
    @ObservedObject var model: StageViewModel

    var body: some View {
        let height = StageTabLayout.stripHeight(lightsCenter: model.chrome.center, fullScreen: model.fullScreen)
        let top = StageTabLayout.tabTop(lightsCenter: model.chrome.center, fullScreen: model.fullScreen)
        let leading = model.fullScreen ? 10 : model.chrome.leading
        GeometryReader { proxy in
            let room = max(0, proxy.size.width - leading - 42)
            let width = StageTabLayout.topWidth(count: model.cards.count, room: room)
            HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: leading, height: 1)
                if model.cards.isEmpty {
                    Text(t("Nothing on the stage yet", "舞台上还没有窗口"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(height: StageTabLayout.tabHeight)
                    Spacer(minLength: 0)
                } else if StageTabLayout.topScrolls(count: model.cards.count, room: room) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        tabs(width: width)
                    }
                } else {
                    tabs(width: width)
                    Spacer(minLength: 0)
                }
                Button {
                    model.tabsOnLeft = true
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(StageIconButton())
                .help(t("Show the tabs on the left", "把标签放到左侧"))
                .frame(height: StageTabLayout.tabHeight)
                .padding(.horizontal, 8)
            }
            .padding(.top, top)
        }
        .frame(height: height)
        .background(StageDragArea())
        .background(StagePalette.strip)
        .contextMenu {
            Button(t("Show Tabs on the Left", "标签放在左侧")) { model.tabsOnLeft = true }
        }
    }

    private func tabs(width: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: StageTabLayout.topSpacing) {
                ForEach(Array(model.cards.enumerated()), id: \.element.id) { index, card in
                    let next = index + 1 < model.cards.count ? model.cards[index + 1].id : nil
                    StageTopTab(card: card, model: model, selected: card.id == model.selected, working: model.isWorking(card.id, at: context.date))
                        .frame(width: width)
                        .overlay(alignment: .trailing) {
                            if let next, card.id != model.selected, next != model.selected {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.16))
                                    .frame(width: 1, height: 14)
                                    .offset(x: StageTabLayout.topSpacing / 2 + 0.5)
                            }
                        }
                }
            }
        }
    }
}

private struct StageTopTab: View {
    let card: StageViewModel.Card
    @ObservedObject var model: StageViewModel
    let selected: Bool
    let working: Bool
    @State private var hovering = false

    var body: some View {
        let profile = model.browser[card.id]?.profile
        HStack(spacing: 6) {
            Image(nsImage: model.icon(for: card))
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
            if let profile {
                StageProfileTag(profile: profile)
            }
            Text(card.name)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            StageTabMark(held: card.heldSince != nil, working: working)
        }
        .padding(.horizontal, 9)
        .frame(height: StageTabLayout.tabHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? StagePalette.card : (hovering ? Color.primary.opacity(0.07) : Color.clear)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? StagePalette.stroke : Color.clear, lineWidth: 1))
        .shadow(color: .black.opacity(selected ? 0.10 : 0), radius: 1.5, y: 0.5)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture { model.select(card.id) }
        .onHover { hovering = $0 }
        .help(model.tooltip(for: card))
        .contextMenu { StageTabMenu(card: card, model: model) }
    }
}

private struct StageSideTabs: View {
    @ObservedObject var model: StageViewModel

    var body: some View {
        let top = StageTabLayout.stripHeight(lightsCenter: model.chrome.center, fullScreen: model.fullScreen)
        VStack(spacing: 0) {
            Color.clear
                .frame(height: top)
                .background(StageDragArea())
            if model.cards.isEmpty {
                Text(t("Nothing on the stage yet", "舞台上还没有窗口"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(spacing: 2) {
                            ForEach(model.cards) { card in
                                StageSideTab(card: card, model: model, selected: card.id == model.selected, working: model.isWorking(card.id, at: context.date))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Button {
                    model.tabsOnLeft = false
                } label: {
                    Label(t("Tabs on top", "标签放到顶部"), systemImage: "rectangle.topthird.inset.filled")
                }
                .buttonStyle(StageIconButton())
                .help(t("Show the tabs along the top", "把标签放到顶部"))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
        }
        .background(StagePalette.strip)
        .contextMenu {
            Button(t("Show Tabs on Top", "标签放在顶部")) { model.tabsOnLeft = false }
        }
    }
}

private struct StageSideTab: View {
    let card: StageViewModel.Card
    @ObservedObject var model: StageViewModel
    let selected: Bool
    let working: Bool
    @State private var hovering = false

    var body: some View {
        let profile = model.browser[card.id]?.profile
        HStack(spacing: 9) {
            Image(nsImage: model.icon(for: card))
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.name)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    if let profile {
                        StageProfileTag(profile: profile)
                    }
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(card.heldSince != nil ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            StageTabMark(held: card.heldSince != nil, working: working)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? StagePalette.card : (hovering ? Color.primary.opacity(0.07) : Color.clear)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? StagePalette.stroke : Color.clear, lineWidth: 1))
        .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1.5, y: 0.5)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture { model.select(card.id) }
        .onHover { hovering = $0 }
        .help(model.tooltip(for: card))
        .contextMenu { StageTabMenu(card: card, model: model) }
    }

    private var subtitle: String {
        if let since = card.heldSince { return t("you hold it · since \(StageClock.minutes.string(from: since))", "你接管着 · \(StageClock.minutes.string(from: since)) 起") }
        if card.foreign { return t("\(card.app) · not put here by amcu", "\(card.app) · 不是 amcu 放的") }
        return card.app
    }
}

private struct StageProfileTag: View {
    let profile: String

    var body: some View {
        let tint = StagePalette.tint(for: profile)
        Text(profile)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.16)))
    }
}

private struct StageTabMark: View {
    let held: Bool
    let working: Bool

    var body: some View {
        if held {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 9.5))
                .foregroundStyle(Color.orange)
                .help(t("You hold this window", "你接管着这个窗口"))
        } else if working {
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
                .help(t("An agent is working in it", "agent 正在操作它"))
        }
    }
}

private struct StageTabMenu: View {
    let card: StageViewModel.Card
    @ObservedObject var model: StageViewModel

    var body: some View {
        if card.heldSince != nil {
            Button(t("Hand Back", "交还")) { model.handBack(card.id) }
            Button(t("Release", "释放")) { model.free(card.id) }
            Button(t("Bring It to the Front", "切到这个窗口")) { model.focusHeld(card.id) }
        } else {
            Button(t("Take Over", "接管")) { model.takeOver(card.id) }
        }
        Divider()
        Button(model.tabsOnLeft ? t("Show Tabs on Top", "标签放在顶部") : t("Show Tabs on the Left", "标签放在左侧")) {
            model.tabsOnLeft.toggle()
        }
    }
}

private struct StagePane: View {
    @ObservedObject var model: StageViewModel
    @ObservedObject var thumbnails: StageThumbnails
    let underTitlebar: Bool

    var body: some View {
        if let card = model.selectedCard {
            let entries = model.activity[card.id] ?? []
            let tabs = model.browser[card.id]?.tabs ?? []
            VStack(spacing: 0) {
                StageWindowBar(card: card, model: model, underTitlebar: underTitlebar)
                Divider()
                if !model.summary.screenRecording {
                    StagePermissionBanner(answersFor: model.summary.answersFor)
                        .padding([.horizontal, .top], 12)
                }
                GeometryReader { proxy in
                    if proxy.size.width >= StageTabLayout.wideInspector {
                        HStack(spacing: 0) {
                            StagePicture(card: card, thumbnails: thumbnails, entries: entries, model: model)
                                .padding(20)
                            Divider()
                            StageInspector(card: card, entries: entries, tabs: tabs, model: model)
                                .frame(width: StageTabLayout.inspectorWidth)
                        }
                    } else {
                        VStack(spacing: 0) {
                            StagePicture(card: card, thumbnails: thumbnails, entries: entries, model: model)
                                .padding(14)
                                .frame(height: max(200, proxy.size.height * 0.62))
                            Divider()
                            StageInspector(card: card, entries: entries, tabs: tabs, model: model)
                        }
                    }
                }
            }
        } else {
            VStack(spacing: 0) {
                if underTitlebar {
                    Color.clear
                        .frame(height: StageTabLayout.stripHeight(lightsCenter: model.chrome.center, fullScreen: model.fullScreen))
                        .background(StageDragArea())
                }
                if !model.summary.screenRecording {
                    StagePermissionBanner(answersFor: model.summary.answersFor)
                        .padding([.horizontal, .top], 12)
                }
                StageEmpty()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct StageWindowBar: View {
    let card: StageViewModel.Card
    @ObservedObject var model: StageViewModel
    let underTitlebar: Bool

    var body: some View {
        let profile = model.browser[card.id]?.profile
        HStack(spacing: 10) {
            Image(nsImage: model.icon(for: card))
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(card.app)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let profile {
                        StageBadge(text: profile, tint: .accentColor)
                            .help(t("The browser profile this window belongs to", "这个窗口所属的浏览器 profile"))
                    }
                    if card.foreign, card.heldSince == nil {
                        StageBadge(text: t("not put here by amcu", "不是 amcu 放的"), tint: .secondary)
                    }
                }
                if !card.title.isEmpty, card.title != card.app {
                    Text(card.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if let since = card.heldSince {
                StageBadge(text: t("you hold it · since \(StageClock.minutes.string(from: since))", "你接管着 · \(StageClock.minutes.string(from: since)) 起"), tint: .orange)
                    .help(t("On your screen now. \"Hand back\" puts it back on the stage; an agent acting on it takes it back too",
                            "现在在你的屏幕上。点「交还」放回舞台；agent 要操作它时也会自动收回"))
                Button { model.handBack(card.id) } label: {
                    Label(t("Hand back", "交还"), systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(StageCapsuleButton(prominent: true))
                .help(t("Put this window back where it was on the stage, and let amcu continue", "把这个窗口放回舞台原处，让 amcu 继续"))
                Button { model.free(card.id) } label: {
                    Label(t("Release", "释放"), systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(StageCapsuleButton(prominent: false))
                .help(t("Keep this window on your screen for good: it leaves the stage, and amcu still works on it where it is",
                        "窗口留在你的屏幕上，不再属于舞台；amcu 仍可在原地操作它"))
            } else {
                Button { model.takeOver(card.id) } label: {
                    Label(t("Take over", "接管"), systemImage: "hand.point.up.left")
                }
                .buttonStyle(StageCapsuleButton(prominent: false))
                .help(t("Bring this window back to where it was on your screen and switch to it; hand it back when you are done",
                        "把窗口挪回你屏幕上的原位并切过去；用完点「交还」"))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(underTitlebar ? StageDragArea() : nil)
        .background(StagePalette.card)
    }
}

private struct StagePicture: View {
    let card: StageViewModel.Card
    @ObservedObject var thumbnails: StageThumbnails
    let entries: [StageActivity]
    let model: StageViewModel
    @State private var hovering = false

    var body: some View {
        let state = thumbnails.state(for: card.id)
        let width = max(card.size.width, 1)
        let height = max(card.size.height, 1)
        let held = card.heldSince != nil
        let pointer = entries.first { $0.fraction != nil }
        ZStack {
            StageLayerView(layer: thumbnails.layer(for: card.id)) { fraction in
                if held {
                    model.focusHeld(card.id)
                } else {
                    model.takeOverAt(card.id, fraction)
                }
            }
            overlay(for: state, held: held)
                .allowsHitTesting(false)
            if let pointer, let fraction = pointer.fraction, Date().timeIntervalSince(pointer.at) < 3 {
                StageRipple(fraction: fraction)
                    .id("\(pointer.seq)-\(pointer.repeats ?? 1)")
            }
            if let latest = entries.first {
                StageOperatorBadge(entry: latest)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(width / height, contentMode: .fit)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(StagePalette.well))
        .overlay(held ? RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.orange.opacity(0.7), lineWidth: 2) : nil)
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        .frame(maxWidth: width, maxHeight: height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { hovering = $0 }
        .help(held
              ? t("Click to bring this window to the front on your screen", "点一下把这个窗口切到你屏幕的最前面")
              : t("Click to take the window over: it comes to your screen with the spot you clicked under the pointer",
                  "点一下就地接管：窗口会来到你的屏幕上，点到的位置正好在鼠标下"))
    }

    @ViewBuilder
    private func overlay(for state: StageThumbnails.State, held: Bool) -> some View {
        switch state {
        case .connecting:
            ProgressView()
                .controlSize(.small)
        case let .failed(reason):
            VStack(spacing: 6) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 18))
                Text(reason)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .padding(10)
        case .live:
            if hovering {
                VStack {
                    Spacer()
                    Label(held ? t("Click to bring it to the front", "点一下切到它") : t("Click to take over here", "点一下就地接管"), systemImage: "hand.tap")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 12)
                }
            }
        }
    }
}

private struct StageInspector: View {
    let card: StageViewModel.Card
    let entries: [StageActivity]
    let tabs: [StageTabs.Tab]
    @ObservedObject var model: StageViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                StageSection(title: t("What agents did", "agent 动态")) {
                    if entries.isEmpty {
                        Text(t("No agent has acted in this window yet.", "还没有 agent 在这个窗口里操作过。"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        StageActivityList(entries: entries)
                    }
                }
                if !tabs.isEmpty {
                    StageSection(title: t("\(tabs.count) tab\(tabs.count == 1 ? "" : "s")", "\(tabs.count) 个标签")) {
                        StageTabList(tabs: tabs)
                    }
                }
                StageSection(title: t("Window", "窗口")) {
                    StageFacts(card: card)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StageSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct StageFacts: View {
    let card: StageViewModel.Card

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            fact(t("Size", "大小"), "\(Int(card.size.width)) × \(Int(card.size.height))")
            fact(t("Where", "位置"), origin)
            if let since = card.heldSince {
                fact(t("Since", "接管于"), StageClock.minutes.string(from: since))
            }
            fact(t("Process", "进程"), "pid \(card.pid)")
        }
    }

    private var origin: String {
        if card.heldSince != nil { return t("on your screen, taken over", "在你的屏幕上（接管中）") }
        switch card.origin {
        case .put: return t("put here by an agent", "agent 放上来的")
        case .followed: return t("opened later by an application amcu follows", "被跟随的 App 后来新开的")
        case .found: return t("on the stage, not put here by amcu", "在舞台上，但不是 amcu 放的")
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

private struct StageStatusBar: View {
    @ObservedObject var model: StageViewModel

    var body: some View {
        let summary = model.summary
        let held = summary.held
        HStack(spacing: 6) {
            StageChip(symbol: "display", text: "\(Int(summary.stage.width))×\(Int(summary.stage.height))")
                .help(t("The stage: a display off the corner of your screen that you never see", "舞台：在你屏幕角外的一块看不到的屏"))
            StageChip(
                symbol: "cursorarrow.slash",
                text: summary.pullbacks > 0
                    ? t("cursor kept off · pulled back \(summary.pullbacks)×", "鼠标进不去 · 已拉回 \(summary.pullbacks) 次")
                    : t("cursor kept off", "鼠标进不去")
            )
            if held > 0 {
                Button(action: model.handBackAll) {
                    Label(held > 1 ? t("Hand back \(held)", "交还 \(held) 个") : t("Hand back", "交还"), systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(StageCapsuleButton(prominent: true))
                .help(t("Put every window you took over back where it was on the stage, and let amcu continue",
                        "把你接管的窗口都放回舞台原处，让 amcu 继续"))
                Button(action: model.releaseAll) {
                    Label(held > 1 ? t("Release \(held)", "释放 \(held) 个") : t("Release", "释放"), systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(StageCapsuleButton(prominent: false))
                .help(t("Keep the windows you took over on your screen for good: they leave the stage, and amcu still works on them where they are",
                        "接管的窗口留在你的屏幕上，不再属于舞台；amcu 仍可在原地操作它们"))
            }
            Spacer(minLength: 8)
            Text(held > 0
                 ? t("\(summary.onStage) on stage · you hold \(held)", "舞台上 \(summary.onStage) 个 · 你接管 \(held) 个")
                 : t("\(summary.onStage) window\(summary.onStage == 1 ? "" : "s") on stage", "舞台上 \(summary.onStage) 个窗口"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(followingNote(summary))
            Button(t("Close Stage", "关闭舞台"), role: .destructive) { model.closeStage() }
                .controlSize(.small)
                .help(t("Put every window back where it was and remove the stage", "把所有窗口放回原处并移除舞台"))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(StagePalette.strip)
    }

    private func followingNote(_ summary: StageViewModel.Summary) -> String {
        if summary.following.isEmpty {
            return t("Only windows an agent puts here appear here.", "只有 agent 放上来的窗口才会出现在这里。")
        }
        let names = summary.following.joined(separator: t(", ", "、"))
        return t("New windows of \(names) come here too, unless you are using it.", "\(names) 新开的窗口也会挪上舞台（你正在用它时除外）。")
    }
}

private struct StageCapsuleButton: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(prominent ? Color.orange : Color.primary.opacity(0.07)))
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : Color.primary.opacity(0.14), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

private struct StageIconButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.0001)))
            .contentShape(Rectangle())
    }
}

private struct StageChip: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

private struct StageBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

enum StageClock {
    static let minutes: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let seconds: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct StageOperatorBadge: View {
    let entry: StageActivity

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if context.date.timeIntervalSince(entry.at) < 15 {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    Text(t("\(StageActivity.sessionLabel(entry.session)) at work", "\(StageActivity.sessionLabel(entry.session)) 在操作"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.green.opacity(0.5), lineWidth: 1))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            }
        }
    }
}

private struct StageActivityList: View {
    let entries: [StageActivity]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 7) {
                ForEach(entries) { entry in
                    StageActivityRow(entry: entry, fresh: context.date.timeIntervalSince(entry.at) < 8)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

private struct StageActivityRow: View {
    let entry: StageActivity
    let fresh: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle()
                    .fill(fresh ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
                Text(StageActivity.sessionLabel(entry.session))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StagePalette.tint(for: entry.session))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.session)
                Spacer(minLength: 6)
                Text(StageClock.seconds.string(from: entry.at))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            Text(entry.summary(chinese: StageText.chinese))
                .font(.system(size: 11.5))
                .foregroundStyle(fresh ? .primary : .secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .padding(.leading, 12)
        }
    }
}

private struct StageRipple: View {
    let fraction: StagePoint
    @State private var grown = false

    var body: some View {
        GeometryReader { proxy in
            let point = CGPoint(x: fraction.x * proxy.size.width, y: fraction.y * proxy.size.height)
            ZStack {
                Circle()
                    .stroke(Color.orange, lineWidth: 2.5)
                    .frame(width: 40, height: 40)
                    .scaleEffect(grown ? 1.5 : 0.3)
                    .opacity(grown ? 0 : 1)
                    .animation(.easeOut(duration: 1.0), value: grown)
                Circle()
                    .fill(Color.orange)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                    .opacity(grown ? 0 : 1)
                    .animation(.easeIn(duration: 2.6), value: grown)
            }
            .position(point)
        }
        .allowsHitTesting(false)
        .onAppear { grown = true }
    }
}

private struct StageLayerView: NSViewRepresentable {
    let layer: CALayer
    let onClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> StageLayerHostView {
        let view = StageLayerHostView()
        view.host(layer)
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: StageLayerHostView, context: Context) {
        view.host(layer)
        view.onClick = onClick
    }
}

final class StageLayerHostView: NSView {
    var onClick: ((CGPoint) -> Void)?
    private weak var hosted: CALayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    func host(_ content: CALayer) {
        guard hosted !== content else { return }
        hosted?.removeFromSuperlayer()
        layer?.addSublayer(content)
        hosted = content
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted?.frame = bounds
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        onClick?(CGPoint(x: point.x / bounds.width, y: (bounds.height - point.y) / bounds.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }
}

private struct StageDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> StageDragView { StageDragView() }
    func updateNSView(_ view: StageDragView, context: Context) {}
}

final class StageDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount >= 2 {
            let action = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String
            switch action {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
            return
        }
        window.performDrag(with: event)
    }
}

private struct StageTabList: View {
    let tabs: [StageTabs.Tab]
    @State private var expanded = false
    private let folded = 8

    var body: some View {
        let shown = expanded
            ? tabs
            : tabs.enumerated().filter { $0.offset < folded || $0.element.active || $0.element.attached }.map(\.element)
        VStack(alignment: .leading, spacing: 1) {
            ForEach(shown) { tab in
                StageTabRow(tab: tab)
            }
            if expanded || shown.count < tabs.count {
                Button(expanded ? t("Show fewer", "收起") : t("\(tabs.count - shown.count) more", "还有 \(tabs.count - shown.count) 个")) {
                    expanded.toggle()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.top, 3)
            }
        }
    }
}

private struct StageTabRow: View {
    let tab: StageTabs.Tab

    var body: some View {
        let site = StageTabs.host(of: tab.url)
        HStack(spacing: 8) {
            StageMonogram(site: site)
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.title.isEmpty ? (site.isEmpty ? tab.url : site) : tab.title)
                    .font(.system(size: 12, weight: tab.active ? .semibold : .regular))
                    .foregroundStyle(tab.active ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !site.isEmpty {
                    Text(site)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            if tab.attached {
                StageBadge(text: t("amcu on it", "amcu 在用"), tint: .orange)
                    .help(t("amcu's debugger is on this tab: an agent is driving it, or did and has not let go",
                            "amcu 的调试器挂在这个标签上：agent 正在操作它，或操作过还没放手"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tab.active ? Color.accentColor.opacity(0.13) : Color.clear))
        .help(tab.url)
    }
}

private struct StageMonogram: View {
    let site: String

    var body: some View {
        Text(site.first.map { String($0).uppercased() } ?? "·")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(site.isEmpty ? Color.gray : StagePalette.tint(for: site)))
    }
}

private struct StageEmpty: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "theatermasks")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(t("Nothing on the stage", "舞台上还没有窗口"))
                .font(.system(size: 14, weight: .semibold))
            Text(t("Windows an agent puts here with `amcu stage put` show up as tabs, each with a live picture.",
                   "agent 用 amcu stage put 放上来的窗口会一个个出现在标签里，带实时画面。"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 56)
        .padding(.horizontal, 24)
    }
}

private struct StagePermissionBanner: View {
    let answersFor: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(t("\(answersFor ?? "The host application") has no Screen Recording permission, so window pictures and titles are hidden.",
                   "\(answersFor ?? "宿主程序") 没有屏幕录制权限，看不到窗口画面和标题。"))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.yellow.opacity(0.12)))
    }
}
