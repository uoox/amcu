import AppKit
import CoreGraphics
import Foundation

public enum LinkRouting {
    public struct Candidate: Equatable, Sendable {
        public let windowID: Int
        public let focusedAt: Double
        public let frame: CGRect
        public let minimized: Bool

        public init(windowID: Int, focusedAt: Double, frame: CGRect, minimized: Bool) {
            self.windowID = windowID
            self.focusedAt = focusedAt
            self.frame = frame
            self.minimized = minimized
        }

        init?(_ value: JSONValue) {
            guard let id = value["windowId"].int, let frame = LinkRouting.rect(value) else { return nil }
            self.init(windowID: id, focusedAt: value["focusedAt"].double ?? 0, frame: frame, minimized: value["state"].string == "minimized")
        }
    }

    public enum Decision: Equatable, Sendable {
        case stay
        case own(windowID: Int)
        case other(peer: Int, windowID: Int)
        case newWindow(CGRect)
    }

    public static func decide(window: CGRect, stage: CGRect?, own: [Candidate], others: [[Candidate]], area: CGRect) -> Decision {
        guard let stage, StageGeometry.isOnStage(window, stage: stage) else { return .stay }
        func usable(_ candidate: Candidate) -> Bool {
            !candidate.minimized && candidate.frame.width >= 100 && candidate.frame.height >= 100 && !StageGeometry.isOnStage(candidate.frame, stage: stage)
        }
        func later(_ a: Candidate, _ b: Candidate) -> Bool {
            a.focusedAt != b.focusedAt ? a.focusedAt > b.focusedAt : a.windowID > b.windowID
        }
        let mine = own.filter(usable).sorted(by: later).first
        var theirs: (peer: Int, candidate: Candidate)?
        for (peer, list) in others.enumerated() {
            for candidate in list where usable(candidate) && candidate.focusedAt > 0 {
                if theirs.map({ later(candidate, $0.candidate) }) ?? true { theirs = (peer, candidate) }
            }
        }
        if let theirs, theirs.candidate.focusedAt > (mine?.focusedAt ?? 0) {
            return .other(peer: theirs.peer, windowID: theirs.candidate.windowID)
        }
        if let mine { return .own(windowID: mine.windowID) }
        return .newWindow(newWindowFrame(in: area))
    }

    public static func newWindowFrame(in area: CGRect) -> CGRect {
        let width = min(area.width - 40, max(min(1000, area.width - 40), (area.width * 0.6).rounded()), 1600)
        let height = min(area.height - 20, max(min(700, area.height - 20), (area.height * 0.85).rounded()))
        return CGRect(x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(), width: width, height: height)
    }

    static func rect(_ value: JSONValue) -> CGRect? {
        guard let left = value["left"].double, let top = value["top"].double,
              let width = value["width"].double, let height = value["height"].double else { return nil }
        return CGRect(x: left, y: top, width: width, height: height)
    }

    static func json(_ rect: CGRect) -> [String: Any] {
        ["left": Int(rect.minX.rounded()), "top": Int(rect.minY.rounded()), "width": Int(rect.width.rounded()), "height": Int(rect.height.rounded())]
    }

    static func userArea() -> CGRect {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        if let screen = NSScreen.screens.first {
            return StageGeometry.quartzRect(fromCocoa: screen.visibleFrame, mainDisplayHeight: mainHeight)
        }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CGRect(x: bounds.minX, y: bounds.minY + 32, width: bounds.width, height: bounds.height - 32)
    }

    struct Peer {
        let endpoint: BrowserEndpoint
        let label: String
        let candidates: [Candidate]
    }

    static func peers(ownSocket: String, browser: String) -> [Peer] {
        let directory = BrowserBridge.socketDirectory
        guard let parent = Stage.parentPID(of: getpid()),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var peers: [Peer] = []
        for name in names.sorted() {
            guard let parsed = BrowserBridge.parseSocketName(name), parsed.browser == browser, parsed.pid != getpid() else { continue }
            let path = directory.appendingPathComponent(name).path
            guard path != ownSocket, Stage.parentPID(of: parsed.pid) == parent else { continue }
            let endpoint = BrowserEndpoint(browser: parsed.browser, pid: parsed.pid, socket: path)
            guard let reply = try? BrowserClient(endpoint: endpoint).request("links.windows", timeout: 1.5) else { continue }
            let label = reply["label"].string ?? reply["profile"].string ?? "pid \(parsed.pid)"
            peers.append(Peer(endpoint: endpoint, label: label, candidates: reply["windows"].array.compactMap(Candidate.init)))
        }
        return peers
    }

    static func route(_ params: JSONValue, ownSocket: String, browser: String) -> [String: Any] {
        guard let window = rect(params["window"]) else { return ["onStage": false, "reason": "no window bounds"] }
        guard let stage = Stage.display()?.bounds else { return ["onStage": false, "reason": "no stage is running"] }
        guard StageGeometry.isOnStage(window, stage: stage) else { return ["onStage": false] }
        let url = params["url"].string ?? ""
        let dryRun = params["dryRun"].bool == true
        let own = params["candidates"].array.compactMap(Candidate.init)
        let peers = peers(ownSocket: ownSocket, browser: browser)
        let area = userArea()
        let site = StageTabs.host(of: url).isEmpty ? "a link" : StageTabs.host(of: url)
        let profile = params["profile"].string.map { "\($0)'s" } ?? "a"
        var decision = decide(window: window, stage: stage, own: own, others: peers.map(\.candidates), area: area)
        if case let .other(index, windowID) = decision {
            let peer = peers[index]
            if dryRun {
                return ["onStage": true, "target": "other", "profile": peer.label, "windowId": windowID]
            }
            if (try? BrowserClient(endpoint: peer.endpoint).request("links.open", params: ["url": url, "windowId": windowID], timeout: 5)) != nil {
                StageClient.note("the user opened \(site); it landed in \(profile) browser window on the stage, so it went to their \(peer.label) window instead")
                return ["onStage": true, "target": "other", "profile": peer.label, "windowId": windowID]
            }
            decision = decide(window: window, stage: stage, own: own, others: [], area: area)
        }
        switch decision {
        case let .own(windowID):
            if !dryRun { StageClient.note("the user opened \(site); it landed in \(profile) browser window on the stage, so it went to the window they used last") }
            return ["onStage": true, "target": "own", "windowId": windowID]
        case let .newWindow(frame):
            if !dryRun { StageClient.note("the user opened \(site); it landed in \(profile) browser window on the stage, so it opened in a new window on their screen") }
            return ["onStage": true, "target": "new", "frame": json(frame)]
        case .stay, .other:
            return ["onStage": false]
        }
    }
}
