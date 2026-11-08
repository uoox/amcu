import AppKit
import SwiftUI

/// What the stage window shows, filled by the menu on the main thread.
final class StageViewModel: ObservableObject {
    struct Card: Identifiable, Equatable {
        let id: CGWindowID
        let pid: pid_t
        let app: String
        let title: String
        let size: CGSize
        /// On the stage, but not put there by amcu.
        let foreign: Bool
    }

    struct Held: Identifiable, Equatable {
        let id: CGWindowID
        let pid: pid_t
        let app: String
        let title: String
        let since: Date
    }

    struct Summary: Equatable {
        var stage: CGSize = .zero
        var pullbacks = 0
        var screenRecording = true
        var answersFor: String?
        var following: [String] = []
    }

    @Published private(set) var summary = Summary()
    @Published private(set) var cards: [Card] = []
    @Published private(set) var held: [Held] = []
    @Published private(set) var browser: [CGWindowID: StageTabs.Paired] = [:]

    var takeOver: (CGWindowID) -> Void = { _ in }
    var takeOverAt: (CGWindowID, CGPoint) -> Void = { _, _ in }
    var handBack: (CGWindowID) -> Void = { _ in }
    var closeStage: () -> Void = {}

    /// Newest first, and otherwise steady: the window server's front-to-back
    /// order changes with every click an agent makes.
    private var order: [CGWindowID] = []
    private var icons: [pid_t: NSImage] = [:]

    func apply(_ status: StageStatus) {
        let present = status.windows.map(\.windowID)
        order.removeAll { !present.contains($0) }
        order = present.filter { !order.contains($0) } + order
        let byID = Dictionary(status.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let cards = order.compactMap { byID[$0] }.map { window in
            Card(id: window.windowID, pid: window.pid, app: window.app, title: window.title ?? "", size: window.frame.cgRect.size, foreign: window.origin == .found)
        }
        if cards != self.cards { self.cards = cards }
        let held = status.takenOver.map { Held(id: $0.windowID, pid: $0.pid, app: $0.app, title: $0.title ?? "", since: $0.since) }
        if held != self.held { self.held = held }
        let summary = Summary(
            stage: status.bounds.cgRect.size,
            pullbacks: status.cursorPullbacks,
            screenRecording: status.screenRecording,
            answersFor: status.answersFor,
            following: status.following.map(\.app)
        )
        if summary != self.summary { self.summary = summary }
    }

    func setBrowser(_ browser: [CGWindowID: StageTabs.Paired]) {
        if browser != self.browser { self.browser = browser }
    }

    func icon(for pid: pid_t) -> NSImage {
        if let icon = icons[pid] { return icon }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon ?? NSWorkspace.shared.icon(for: .application)
        icons[pid] = icon
        return icon
    }
}

private func t(_ english: String, _ chinese: String) -> String {
    StageText.t(english, chinese)
}

/// How many columns of cards a width holds: as many as fit at
/// `cardMinimum` each, at most `maxColumns`, so a wide window adds columns
/// instead of stretching cards and an ultrawide one still reads as a grid.
public enum StageLayout {
    public static let cardMinimum: CGFloat = 360
    public static let spacing: CGFloat = 14
    public static let padding: CGFloat = 16
    public static let maxColumns = 4

    public static func columns(for width: CGFloat) -> Int {
        let room = width - 2 * padding
        return max(1, min(maxColumns, Int(((room + spacing) / (cardMinimum + spacing)).rounded(.down))))
    }
}

enum StagePalette {
    static let background = dynamic(light: NSColor(srgbRed: 0.945, green: 0.945, blue: 0.957, alpha: 1), dark: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.125, alpha: 1))
    static let card = dynamic(light: .white, dark: NSColor(srgbRed: 0.176, green: 0.176, blue: 0.184, alpha: 1))
    /// Lighter than a dark window and darker than a light one, so either
    /// stands out in it.
    static let well = dynamic(light: NSColor(srgbRed: 0.918, green: 0.918, blue: 0.933, alpha: 1), dark: NSColor(srgbRed: 0.255, green: 0.255, blue: 0.267, alpha: 1))
    static let stroke = dynamic(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.white.withAlphaComponent(0.09))

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// A steady colour per site, for its monogram.
    static func tint(for site: String) -> Color {
        let sum = site.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hue: Double(sum % 360) / 360, saturation: 0.5, brightness: 0.72)
    }
}

/// The stage window: the windows on the stage as cards with a live picture
/// each, a browser window's tabs under its picture, what the user holds, and
/// a way to close the stage.
struct StageView: View {
    @ObservedObject var model: StageViewModel
    @ObservedObject var thumbnails: StageThumbnails

    var body: some View {
        VStack(spacing: 0) {
            StageHeader(summary: model.summary, count: model.cards.count)
            Divider()
            GeometryReader { proxy in
                let columns = Array(
                    repeating: GridItem(.flexible(), spacing: StageLayout.spacing, alignment: .top),
                    count: StageLayout.columns(for: proxy.size.width)
                )
                ScrollView {
                    VStack(alignment: .leading, spacing: StageLayout.spacing) {
                        if !model.summary.screenRecording {
                            StagePermissionBanner(answersFor: model.summary.answersFor)
                        }
                        if !model.held.isEmpty {
                            StageHeldSection(model: model)
                        }
                        if model.cards.isEmpty {
                            StageEmpty()
                        } else {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: StageLayout.spacing) {
                                ForEach(model.cards) { card in
                                    StageWindowCard(card: card, browser: model.browser[card.id], model: model, thumbnails: thumbnails)
                                }
                            }
                        }
                    }
                    .padding(StageLayout.padding)
                }
            }
            Divider()
            StageFooter(summary: model.summary, close: model.closeStage)
        }
        .frame(minWidth: 380, minHeight: 360)
        .background(StagePalette.background.ignoresSafeArea())
    }
}

private struct StageHeader: View {
    let summary: StageViewModel.Summary
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            StageChip(symbol: "display", text: "\(Int(summary.stage.width))×\(Int(summary.stage.height))")
            StageChip(
                symbol: "cursorarrow.slash",
                text: summary.pullbacks > 0
                    ? t("cursor kept off · pulled back \(summary.pullbacks)×", "鼠标进不去 · 已拉回 \(summary.pullbacks) 次")
                    : t("cursor kept off", "鼠标进不去")
            )
            Spacer(minLength: 8)
            Text(t("\(count) window\(count == 1 ? "" : "s") on stage", "舞台上 \(count) 个窗口"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 10)
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

private struct StageWindowCard: View {
    let card: StageViewModel.Card
    let browser: StageTabs.Paired?
    let model: StageViewModel
    @ObservedObject var thumbnails: StageThumbnails

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: model.icon(for: card.pid))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(card.app)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if let profile = browser?.profile {
                            StageBadge(text: profile, tint: .accentColor)
                                .help(t("The browser profile this window belongs to", "这个窗口所属的浏览器 profile"))
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
                Spacer(minLength: 8)
                if card.foreign {
                    StageBadge(text: t("not put here by amcu", "不是 amcu 放的"), tint: .secondary)
                }
                Button(t("Take over", "接管")) { model.takeOver(card.id) }
                    .controlSize(.small)
                    .help(t("Bring this window back to where it was on your screen and switch to it; hand it back when you are done",
                            "把窗口挪回你屏幕上的原位并切过去；用完点「交还」"))
            }
            StageThumbnail(card: card, thumbnails: thumbnails) { fraction in
                model.takeOverAt(card.id, fraction)
            }
            if let tabs = browser?.tabs, !tabs.isEmpty {
                StageTabList(tabs: tabs)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StagePalette.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(StagePalette.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
}

/// The window as it is now, in a well the size of the card. Clicking a spot
/// takes the window over with that spot under the pointer.
private struct StageThumbnail: View {
    let card: StageViewModel.Card
    @ObservedObject var thumbnails: StageThumbnails
    let onClick: (CGPoint) -> Void
    @State private var hovering = false

    var body: some View {
        let state = thumbnails.state(for: card.id)
        let width = max(card.size.width, 1)
        let height = max(card.size.height, 1)
        ZStack {
            StageLayerView(layer: thumbnails.layer(for: card.id), onClick: onClick)
            overlay(for: state)
                .allowsHitTesting(false)
        }
        // Only the width is bounded, so the height follows the window's
        // proportions with no band above or below; a tall window gets a
        // narrower bound so it stays under 340 points.
        .aspectRatio(width / height, contentMode: .fit)
        .frame(maxWidth: min(width, 340 * width / height))
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StagePalette.well))
        .onHover { hovering = $0 }
        .help(t("Click to take the window over: it comes to your screen with the spot you clicked under the pointer",
                "点一下就地接管：窗口会来到你的屏幕上，点到的位置正好在鼠标下"))
    }

    @ViewBuilder
    private func overlay(for state: StageThumbnails.State) -> some View {
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
                    Label(t("Click to take over here", "点一下就地接管"), systemImage: "hand.tap")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 10)
                }
            }
        }
    }
}

/// Hosts a window's capture layer and reports clicks as a fraction of the
/// window from its top-left corner. Takes the first click, so one click
/// works while another application has the keyboard.
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

/// A browser window's tabs: the active one highlighted, the ones amcu's
/// debugger is on marked, long lists folded.
private struct StageTabList: View {
    let tabs: [StageTabs.Tab]
    @State private var expanded = false
    private let folded = 6

    var body: some View {
        let shown = expanded
            ? tabs
            : tabs.enumerated().filter { $0.offset < folded || $0.element.active || $0.element.attached }.map(\.element)
        VStack(alignment: .leading, spacing: 1) {
            Text(t("\(tabs.count) tab\(tabs.count == 1 ? "" : "s")", "\(tabs.count) 个标签"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 3)
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
            Text(tab.title.isEmpty ? (site.isEmpty ? tab.url : site) : tab.title)
                .font(.system(size: 12, weight: tab.active ? .semibold : .regular))
                .foregroundStyle(tab.active ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 6)
            if tab.attached {
                StageBadge(text: t("amcu on it", "amcu 在用"), tint: .orange)
                    .help(t("amcu's debugger is on this tab: an agent is driving it, or did and has not let go",
                            "amcu 的调试器挂在这个标签上：agent 正在操作它，或操作过还没放手"))
            }
            if !site.isEmpty {
                Text(site)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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

private struct StageHeldSection: View {
    @ObservedObject var model: StageViewModel

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text(t("Taken over by you", "你接管的窗口"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Text(t("amcu leaves these apps alone until you hand them back", "交还前 amcu 不会碰这些 App"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ForEach(model.held) { item in
                HStack(spacing: 10) {
                    Image(nsImage: model.icon(for: item.pid))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.app)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if !item.title.isEmpty, item.title != item.app {
                            Text(item.title)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(t("since \(StageHeldSection.clock.string(from: item.since))", "\(StageHeldSection.clock.string(from: item.since)) 起"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button(t("Hand back", "交还")) { model.handBack(item.id) }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                        .help(t("Put this window back on the stage, where it was, and let amcu continue", "把窗口放回舞台原处，让 amcu 继续"))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.32), lineWidth: 1))
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
            Text(t("Windows an agent puts here with `amcu stage put` show up with a live picture.",
                   "agent 用 amcu stage put 放上来的窗口会出现在这里，带实时画面。"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
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

private struct StageFooter: View {
    let summary: StageViewModel.Summary
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if summary.following.isEmpty {
                    Text(t("Only windows an agent puts here appear here.", "只有 agent 放上来的窗口才会出现在这里。"))
                } else {
                    let names = summary.following.joined(separator: t(", ", "、"))
                    Text(t("New windows of \(names) come here too, unless you are using it.", "\(names) 新开的窗口也会挪上舞台（你正在用它时除外）。"))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            Spacer(minLength: 8)
            Button(t("Close stage", "关闭舞台"), role: .destructive) { close() }
                .controlSize(.small)
                .help(t("Put every window back where it was and remove the stage", "把所有窗口放回原处并移除舞台"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Takes the first click, so buttons work while another application has
/// the keyboard.
final class StageHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
