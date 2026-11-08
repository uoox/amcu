import AppKit
import CoreMedia
import ScreenCaptureKit

/// Live pictures of the windows on the stage, one ScreenCaptureKit stream per
/// window while the stage window is open. Each window is captured on its own
/// (`desktopIndependentWindow`), so it fills its thumbnail however small it
/// is and whatever covers it on the stage; frames go straight into a layer,
/// and only when the window changed. The host runs from its own copy of the
/// binary (`Stage.hostExecutableURL`), or these streams would stall every
/// `amcu screenshot` in replayd.
final class StageThumbnails: ObservableObject {
    enum State: Equatable {
        case connecting
        case live
        case failed(String)
    }

    @Published private(set) var states: [CGWindowID: State] = [:]
    private var layers: [CGWindowID: CALayer] = [:]
    private var captures: [CGWindowID: StageWindowCapture] = [:]
    private var sizes: [CGWindowID: CGSize] = [:]
    private var failedAt: [CGWindowID: Date] = [:]

    func state(for id: CGWindowID) -> State {
        states[id] ?? .connecting
    }

    func layer(for id: CGWindowID) -> CALayer {
        if let layer = layers[id] { return layer }
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layers[id] = layer
        return layer
    }

    /// Captures exactly these windows: starts the new ones, follows a resize,
    /// retries a failed one after a few seconds, forgets the ones that left.
    func run(_ windows: [(id: CGWindowID, size: CGSize)]) {
        let wanted = Dictionary(windows.map { ($0.id, $0.size) }, uniquingKeysWith: { first, _ in first })
        for id in Array(captures.keys) where wanted[id] == nil {
            captures.removeValue(forKey: id)?.stop()
        }
        for id in Array(layers.keys) where wanted[id] == nil {
            layers[id] = nil
            sizes[id] = nil
            failedAt[id] = nil
            states[id] = nil
        }
        for (id, size) in wanted {
            if let capture = captures[id] {
                if case .failed = states[id], Date().timeIntervalSince(failedAt[id] ?? .distantPast) > 3 {
                    capture.stop()
                    captures[id] = nil
                } else {
                    if let old = sizes[id], abs(old.width - size.width) > 2 || abs(old.height - size.height) > 2 {
                        sizes[id] = size
                        capture.resize(to: size)
                    }
                    continue
                }
            }
            start(id, size: size)
        }
    }

    /// Stops every stream and keeps the last pictures for when the window
    /// opens again.
    func stop() {
        for capture in captures.values { capture.stop() }
        captures.removeAll()
    }

    private func start(_ id: CGWindowID, size: CGSize) {
        let capture = StageWindowCapture(windowID: id, layer: layer(for: id))
        capture.onFirstFrame = { [weak self] in self?.set(.live, for: id) }
        capture.onFailure = { [weak self] reason in
            self?.failedAt[id] = Date()
            self?.set(.failed(reason), for: id)
        }
        if states[id] != .live { set(.connecting, for: id) }
        captures[id] = capture
        sizes[id] = size
        capture.start(size: size)
    }

    private func set(_ state: State, for id: CGWindowID) {
        guard layers[id] != nil, states[id] != state else { return }
        states[id] = state
    }
}

/// One window's stream: at most five frames a second, none while the window
/// does not change.
final class StageWindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFirstFrame: (() -> Void)?
    var onFailure: ((String) -> Void)?

    private let windowID: CGWindowID
    private weak var layer: CALayer?
    private let queue: DispatchQueue
    private var stream: SCStream?
    private var delivered = false
    private var stopped = false

    init(windowID: CGWindowID, layer: CALayer) {
        self.windowID = windowID
        self.layer = layer
        queue = DispatchQueue(label: "amcu.stage.thumbnail.\(windowID)")
    }

    func start(size: CGSize) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == self.windowID }) else {
                    throw AmcuError(.captureFailure, StageText.t("this window cannot be captured yet", "这个窗口暂时截不到"))
                }
                let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: StageWindowCapture.configuration(for: size), delegate: self)
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
                await MainActor.run {
                    if !self.stopped { self.onFailure?(reason) }
                }
            }
        }
    }

    /// Twice the window's size for a sharp thumbnail on a Retina screen,
    /// at most 1200 pixels on the long side.
    static func configuration(for size: CGSize) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = min(2, 1200 / max(size.width, size.height, 1))
        configuration.width = max(2, Int((size.width * scale).rounded()))
        configuration.height = max(2, Int((size.height * scale).rounded()))
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        return configuration
    }

    func resize(to size: CGSize) {
        stream?.updateConfiguration(StageWindowCapture.configuration(for: size)) { _ in }
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
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer?.contents = surface
            CATransaction.commit()
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
