import AppKit
import CoreGraphics
import Foundation

/// The process that keeps the stage display up (`amcu stage hold`), apart
/// from the host. A virtual display lives exactly as long as the process that
/// made it: held by the host, every upgrade or restart of the host removed it
/// and macOS dropped its windows onto the user's screen until they were put
/// back (half a minute once, when the browser had come to the front in the
/// gap and putting it back was refused). This process does nothing else and
/// rarely changes, so a host can be replaced under a display that stays.
/// It goes when the host asks (stop, idle), when the system ends the display,
/// or when no host has answered for a minute: one that died must not leave
/// windows on a display nobody shows and no cursor guard covers.
public enum StageDisplayHolder {
    public struct Info: Codable, Sendable, Equatable {
        public let pid: Int32
        public let displayID: UInt32
        public let width: Double
        public let height: Double
        public let scale: Int
        public let version: String
        public let since: Date
    }

    static let orphanLimit: TimeInterval = 60

    /// The holder that is up now: its record, its process alive, its display
    /// online.
    public static func current() -> Info? {
        guard let data = try? Data(contentsOf: Stage.holderURL),
              let info = try? StageWire.decoder().decode(Info.self, from: data),
              info.pid > 0, kill(info.pid, 0) == 0,
              Stage.onlineDisplays().contains(info.displayID), Stage.identity.matches(info.displayID) else { return nil }
        return info
    }

    /// Starts a holder from its own copy of this binary and waits for its
    /// display to come up.
    static func start(pointSize: CGSize, scale: Int, wait: TimeInterval = 10) throws -> Info {
        let executable = try Stage.cloneExecutable(to: Stage.holderExecutableURL)
        let pid = try Stage.spawnDetached([
            executable, "stage", "hold",
            "--size", "\(Int(pointSize.width.rounded()))x\(Int(pointSize.height.rounded()))",
            "--scale", String(scale >= 2 ? 2 : 1)
        ])
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            usleep(100_000)
            if let info = current(), info.pid == pid { return info }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid || kill(pid, 0) != 0 {
                throw AmcuError(.stageUnavailable, "the stage display holder exited during start-up: \(StageClient.lastLogLine() ?? "no log line")")
            }
        }
        kill(pid, SIGTERM)
        throw AmcuError(.timeout, "the stage display did not come up within \(Int(wait))s")
    }

    /// Ends the holder and waits until its display is gone, so a stage
    /// started right after does not find it still there.
    static func stop(_ info: Info, timeout: TimeInterval = 3) {
        guard kill(info.pid, SIGTERM) == 0 else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, Stage.onlineDisplays().contains(info.displayID) {
            usleep(50_000)
        }
    }

    // MARK: - The holder process

    public static func run(pointSize: CGSize, scale: Int) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = HolderDelegate(pointSize: pointSize, scale: scale)
        holderDelegate = delegate
        app.delegate = delegate
        app.run()
        exit(0)
    }
}

private var holderDelegate: HolderDelegate?

private final class HolderDelegate: NSObject, NSApplicationDelegate {
    private let pointSize: CGSize
    private let scale: Int
    private var display: VirtualDisplay?
    private var info: StageDisplayHolder.Info?
    private var signalSources: [DispatchSourceSignal] = []
    private var watchdog: Timer?
    private var orphanSince: Date?

    init(pointSize: CGSize, scale: Int) {
        self.pointSize = pointSize
        self.scale = scale
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let other = StageDisplayHolder.current() {
            log("another holder (pid \(other.pid)) keeps display \(other.displayID); leaving it in charge")
            exit(0)
        }
        do {
            display = try VirtualDisplay(identity: Stage.identity, pointSize: pointSize, scale: scale) { [weak self] in
                self?.finish("the system ended the stage display")
            }
        } catch {
            log("cannot create the stage display: \(error)")
            exit(2)
        }
        guard let display else { exit(2) }
        let info = StageDisplayHolder.Info(
            pid: getpid(), displayID: display.displayID,
            width: Double(pointSize.width), height: Double(pointSize.height), scale: scale >= 2 ? 2 : 1,
            version: AmcuVersion.string, since: Date()
        )
        self.info = info
        do {
            let data = try StageWire.encoder().encode(info)
            try data.write(to: Stage.holderURL, options: .atomic)
            chmod(Stage.holderURL.path, 0o600)
        } catch {
            log("cannot record the holder in \(Stage.holderURL.path): \(error)")
            finish("no record, so no host could find the display")
        }
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.finish("asked to go (signal \(number))") }
            source.resume()
            signalSources.append(source)
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.watch() }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        log("holding display \(display.displayID), \(Int(pointSize.width))x\(Int(pointSize.height))@\(scale >= 2 ? 2 : 1)x")
    }

    private func watch() {
        if StageClient.isRunning() {
            orphanSince = nil
            return
        }
        let start = orphanSince ?? Date()
        orphanSince = start
        if Date().timeIntervalSince(start) >= StageDisplayHolder.orphanLimit {
            finish("no stage host answered for \(Int(StageDisplayHolder.orphanLimit))s")
        }
    }

    private func finish(_ reason: String) {
        log("letting the display go: \(reason)")
        if let info, let data = try? Data(contentsOf: Stage.holderURL),
           let recorded = try? StageWire.decoder().decode(StageDisplayHolder.Info.self, from: data), recorded.pid == info.pid {
            try? FileManager.default.removeItem(at: Stage.holderURL)
        }
        display?.invalidate()
        display = nil
        exit(0)
    }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) amcu stage-display[\(getpid())]: \(message)\n".utf8))
    }
}
