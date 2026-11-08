import AppKit
import CoreMedia
import ScreenCaptureKit

/// Text the person at the screen reads, in their language.
enum StageText {
    static let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

    static func t(_ english: String, _ chinese: String) -> String {
        StageText.chinese ? chinese : english
    }
}

/// The menu bar icon and its panel: a live view of the stage, the windows on
/// it with a "take over" button each, and a way to close the stage — the
/// user's window into a display they otherwise cannot see. The panel never
/// activates amcu or takes the keyboard: clicking the icon leaves the user's
/// application in front, and a click anywhere else closes it.
final class StageMenu: NSObject {
    private unowned let runtime: StageRuntime
    private let statusItem: NSStatusItem
    private let panel = StagePanelController()
    private lazy var window = StagePanelWindow(content: panel.view)
    private var outsideClicks: Any?

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
        panel.onTakeOver = { [weak self] windowID in
            self?.hide()
            self?.runtime.takeOverFromMenu(windowID)
            self?.refresh()
        }
        panel.onPreviewClick = { [weak self] stagePoint in
            // The cursor is where the user clicked, in this panel; the panel
            // goes first so the window lands under the cursor in plain view.
            let cursor = CGEvent(source: nil)?.location ?? .zero
            self?.hide()
            self?.runtime.takeOver(at: stagePoint, cursor: cursor)
            self?.refresh()
        }
        panel.onHandBack = { [weak self] windowID in
            self?.runtime.handBack(windowID)
            self?.refresh()
        }
        panel.onClose = { [weak self] in
            self?.hide()
            self?.runtime.stopAndExit(reason: "closed from the menu bar")
        }
    }

    var isShown: Bool { window.isVisible }

    func refresh() {
        let status = runtime.status()
        let count = status.windows.count
        let held = status.takenOver.count
        if let button = statusItem.button {
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
        if isShown {
            panel.show(status)
            position()
        }
    }

    @objc private func toggle(_ sender: Any?) {
        isShown ? hide() : show()
    }

    func show() {
        guard !isShown else { return }
        panel.show(runtime.status())
        position()
        window.orderFrontRegardless()
        panel.startPreview()
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        panel.stopPreview()
        window.orderOut(nil)
    }

    /// Just below the menu bar icon, kept on the icon's screen.
    private func position() {
        panel.view.layoutSubtreeIfNeeded()
        let size = panel.view.fittingSize
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = max(origin.y, visible.minY + 8)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func uninstall() {
        hide()
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

/// A floating panel that neither activates amcu nor becomes key, so the user's
/// focus stays where it was while they look and click.
final class StagePanelWindow: NSPanel {
    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        contentView = background
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons in a window that is never key must take the first click.
final class StagePanelButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class StagePanelController: NSViewController {
    var onTakeOver: ((UInt32) -> Void)?
    var onHandBack: ((UInt32) -> Void)?
    var onPreviewClick: ((CGPoint) -> Void)?
    var onClose: (() -> Void)?

    private static let previewWidth: CGFloat = 600
    private let titleLabel = NSTextField(labelWithString: "amcu " + StageText.t("stage", "舞台"))
    private let detailLabel = NSTextField(labelWithString: "")
    private let previewView = StagePreviewView()
    private let list = NSStackView()
    private let footerLabel = NSTextField(wrappingLabelWithString: "")
    private let closeButton = StagePanelButton(title: StageText.t("Close stage", "关闭舞台"), target: nil, action: nil)
    private var previewHeight: NSLayoutConstraint?
    private var stream: StagePreviewStream?
    private var status: StageStatus?

    override func loadView() {
        titleLabel.font = .boldSystemFont(ofSize: 13)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        let header = NSStackView(views: [titleLabel, detailLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.toolTip = StageText.t("Click a window to take it over: it comes to your screen, under the pointer", "点画面里的窗口就地接管：它会来到你的屏幕上、鼠标底下")
        previewView.onClick = { [weak self] point in
            guard let self, let status = self.status,
                  let stagePoint = StageGeometry.stagePoint(fromPreview: point, viewSize: self.previewView.bounds.size, stage: status.bounds.cgRect) else { return }
            self.onPreviewClick?(stagePoint)
        }
        let height = previewView.heightAnchor.constraint(equalToConstant: StagePanelController.previewWidth * 1080 / 2560)
        previewHeight = height
        NSLayoutConstraint.activate([
            previewView.widthAnchor.constraint(equalToConstant: StagePanelController.previewWidth),
            height
        ])

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.preferredMaxLayoutWidth = StagePanelController.previewWidth - 120
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .small
        closeButton.target = self
        closeButton.action = #selector(closeStage(_:))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [footerLabel, spacer, closeButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        let stack = NSStackView(views: [header, previewView, list, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.widthAnchor.constraint(equalToConstant: StagePanelController.previewWidth).isActive = true
        view = stack
    }

    func show(_ status: StageStatus) {
        _ = view
        self.status = status
        let bounds = status.bounds.cgRect
        if bounds.width > 0 {
            previewHeight?.constant = (StagePanelController.previewWidth * bounds.height / bounds.width).rounded()
        }
        var detail = "\(Int(bounds.width))×\(Int(bounds.height))"
        detail += StageText.t(" · cursor kept off", " · 鼠标进不去")
        if status.cursorPullbacks > 0 {
            detail += StageText.t(" (pulled back \(status.cursorPullbacks)×)", "（已拉回 \(status.cursorPullbacks) 次）")
        }
        detailLabel.stringValue = detail
        if !status.screenRecording {
            previewView.message = StageText.t(
                "No live view: \(status.answersFor ?? "the host application") lacks Screen Recording permission.",
                "看不到画面：\(status.answersFor ?? "宿主程序") 没有屏幕录制权限。"
            )
        }

        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if status.windows.isEmpty {
            let empty = NSTextField(labelWithString: StageText.t("No windows on the stage.", "舞台上没有窗口。"))
            empty.textColor = .secondaryLabelColor
            list.addArrangedSubview(empty)
        }
        for window in status.windows {
            list.addArrangedSubview(row(for: window))
        }
        if !status.takenOver.isEmpty {
            let heading = NSTextField(labelWithString: StageText.t(
                "Taken over by you — amcu leaves these apps alone until you hand them back:",
                "你接管的窗口（交还前 amcu 不会动这些 App）："
            ))
            heading.font = .systemFont(ofSize: 11, weight: .semibold)
            heading.textColor = .secondaryLabelColor
            list.addArrangedSubview(heading)
            for held in status.takenOver {
                list.addArrangedSubview(row(for: held))
            }
        }

        if status.following.isEmpty {
            footerLabel.stringValue = StageText.t("Only what an agent puts here appears here.", "只有 agent 放上来的窗口才会出现在这里。")
        } else {
            let names = status.following.map(\.app).joined(separator: StageText.t(", ", "、"))
            footerLabel.stringValue = StageText.t(
                "New windows of \(names) come here too, unless you are using that app.",
                "\(names) 新开的窗口也会挪进来（你正在用它时除外）。"
            )
        }
    }

    private func row(for window: StageWindow) -> NSView {
        var note: String?
        if window.origin == .found { note = StageText.t("not put here by amcu", "不是 amcu 放的") }
        let button = StagePanelButton(title: StageText.t("Take over", "接管"), target: self, action: #selector(takeOver(_:)))
        button.tag = Int(window.windowID)
        button.toolTip = StageText.t("Bring this window back to your screen and switch to it; hand it back when you are done", "把这个窗口挪回你的屏幕并切换过去；用完点「交还」")
        return row(pid: window.pid, app: window.app, title: window.title, note: note, button: button)
    }

    private func row(for held: StageTakeover) -> NSView {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let button = StagePanelButton(title: StageText.t("Hand back", "交还"), target: self, action: #selector(handBack(_:)))
        button.tag = Int(held.windowID)
        button.toolTip = StageText.t("Put this window back on the stage, where it was, and let amcu continue", "把窗口放回舞台原处，让 amcu 继续")
        return row(pid: held.pid, app: held.app, title: held.title, note: StageText.t("since \(formatter.string(from: held.since))", "\(formatter.string(from: held.since)) 起"), button: button)
    }

    private func row(pid: Int32, app: String, title: String?, note: String?, button: NSButton) -> NSView {
        let icon = NSImageView()
        icon.image = NSRunningApplication(processIdentifier: pid)?.icon
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16)])

        var text = app
        if let title, !title.isEmpty, title != app { text += " — " + title }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [icon, label]
        if let note {
            let noteLabel = NSTextField(labelWithString: note)
            noteLabel.font = .systemFont(ofSize: 11)
            noteLabel.textColor = .tertiaryLabelColor
            views.append(noteLabel)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(spacer)
        button.bezelStyle = .rounded
        button.controlSize = .small
        views.append(button)
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: StagePanelController.previewWidth).isActive = true
        return row
    }

    func startPreview() {
        guard stream == nil, let status, status.screenRecording, let layer = previewView.contentLayer else { return }
        previewView.message = StageText.t("Connecting…", "正在接入画面…")
        let stream = StagePreviewStream(displayID: status.displayID, layer: layer, pixelWidth: Int(StagePanelController.previewWidth * 2), aspect: status.bounds.height / max(status.bounds.width, 1))
        stream.onFirstFrame = { [weak self] in self?.previewView.message = nil }
        stream.onFailure = { [weak self] reason in
            self?.previewView.message = StageText.t("No live view: \(reason)", "看不到画面：\(reason)")
        }
        stream.start()
        self.stream = stream
    }

    func stopPreview() {
        stream?.stop()
        stream = nil
    }

    @objc private func takeOver(_ sender: NSButton) {
        onTakeOver?(UInt32(sender.tag))
    }

    @objc private func handBack(_ sender: NSButton) {
        onHandBack?(UInt32(sender.tag))
    }

    @objc private func closeStage(_ sender: NSButton) {
        onClose?()
    }
}

final class StagePreviewView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    let contentLayer: CALayer?
    var onClick: ((CGPoint) -> Void)?

    // The panel is never key; without this the click would be spent on
    // focusing it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil))
    }

    var message: String? {
        didSet {
            label.stringValue = message ?? ""
            label.isHidden = message == nil
        }
    }

    override init(frame: NSRect) {
        let content = CALayer()
        content.contentsGravity = .resizeAspect
        content.backgroundColor = NSColor.black.cgColor
        contentLayer = content
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.addSublayer(content)
        label.textColor = .white
        label.alignment = .center
        label.font = .systemFont(ofSize: 12)
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer?.frame = bounds
        CATransaction.commit()
    }
}

/// A low-rate ScreenCaptureKit stream of the stage display into a layer,
/// running only while the popover is open.
final class StagePreviewStream: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFirstFrame: (() -> Void)?
    var onFailure: ((String) -> Void)?

    private let displayID: UInt32
    private weak var layer: CALayer?
    private let pixelWidth: Int
    private let aspect: CGFloat
    private let queue = DispatchQueue(label: "amcu.stage.preview")
    private var stream: SCStream?
    private var delivered = false
    private var stopped = false

    init(displayID: UInt32, layer: CALayer, pixelWidth: Int, aspect: CGFloat) {
        self.displayID = displayID
        self.layer = layer
        self.pixelWidth = pixelWidth
        self.aspect = aspect
    }

    func start() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == self.displayID }) else {
                    throw AmcuError(.captureFailure, StageText.t("the stage display is not capturable yet", "舞台屏暂时还截不到"))
                }
                let configuration = SCStreamConfiguration()
                configuration.width = self.pixelWidth
                configuration.height = max(2, Int((CGFloat(self.pixelWidth) * self.aspect).rounded()))
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
                configuration.queueDepth = 3
                configuration.showsCursor = false
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await stream.startCapture()
                await MainActor.run {
                    if self.stopped {
                        stream.stopCapture { _ in }
                    } else {
                        self.stream = stream
                    }
                }
            } catch {
                let reason = (error as? AmcuError)?.message ?? error.localizedDescription
                await MainActor.run { self.onFailure?(reason) }
            }
        }
    }

    func stop() {
        stopped = true
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.layer?.contents = surface
            if !self.delivered {
                self.delivered = true
                self.onFirstFrame?()
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.onFailure?(error.localizedDescription)
        }
    }
}
