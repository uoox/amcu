import AppKit
import Foundation

/// A browser window is admitted to the stage only through a unique marker
/// created by that profile's extension. Title-order pairing is for previews,
/// never authority to move one of the user's windows.
public enum BrowserStage {
    public struct Placement: Encodable {
        public let windowID: Int
        public let nativeWindowID: UInt32
        public let bounds: FrameJSON
    }

    public static func prepare(client: BrowserClient, session: String, timeout: TimeInterval = 20) throws -> Placement {
        guard client.endpoint.browser != SafariBridge.browserName else {
            throw AmcuError(.unsupported, "Safari cannot create an unfocused stage window", nextSteps: ["Use a Chrome-family browser for --stage."])
        }
        guard timeout.isFinite, timeout > 0, timeout <= 600 else {
            throw AmcuError(.invalidArgument, "--timeout must be finite and between 0 and 600 seconds")
        }
        try Permissions.requireAccessibility()
        guard !Stage.screenIsLocked else {
            throw AmcuError(.unsupported, "the screen is locked; a stage window cannot be verified", nextSteps: ["Unlock the Mac, then resume the task."])
        }
        guard let pid = Stage.browserPID(for: client.endpoint), let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            throw AmcuError(.appNotFound, "the browser process is no longer running")
        }
        let guardFocus = FocusGuard(targetPID: pid)
        let stage = try StageClient.start().reply.status
        let bounds = stage.bounds
        let geometry: [String: Any] = ["left": Int(bounds.x), "top": Int(bounds.y + 40),
                                       "width": min(1280, Int(bounds.width)), "height": min(850, Int(bounds.height - 40))]
        let result = try client.request("window.stage.prepare", params: ["session": session, "stageBounds": geometry], timeout: timeout)
        guard let windowID = result["window"]["id"].int,
              let markerTitle = result["markerTitle"].string, !markerTitle.isEmpty,
              let markerTabID = result["markerTabId"].int else {
            throw AmcuError(.pageError, "the extension did not supply a verifiable stage marker", nextSteps: ["Update the extension with `amcu browser install`, then retry."])
        }
        if result["needsPlacement"].bool == true {
            FileHandle.standardError.write(Data("warning: Chrome ignored the new work window's initial stage coordinates; its uniquely identified marker window may have appeared briefly before registration\n".utf8))
        }
        let listed = try client.request("tabs.list", params: ["session": session], timeout: 5)
        guard listed["tabs"].array.contains(where: { $0["id"].int == markerTabID && $0["windowId"].int == windowID }) else {
            throw AmcuError(.staleSnapshot, "the stage marker is no longer in this profile's window")
        }
        let deadline = Date().addingTimeInterval(timeout)
        var chosen: WindowInfo?
        while Date() < deadline {
            let candidates = try Target.windows(of: app).map(\.info).filter { info in
                guard let title = info.title else { return false }
                return title == markerTitle || title.hasPrefix(markerTitle + " - ") || title.hasPrefix(markerTitle + " — ")
            }
            if candidates.count > 1 {
                throw AmcuError(.ambiguousBrowser, "more than one native window carries the stage marker; refusing to move either")
            }
            if let candidate = candidates.first, candidate.windowID != nil { chosen = candidate; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard let chosen, let nativeID = chosen.windowID else {
            throw AmcuError(.windowNotFound, "the browser stage marker did not become an accessibility window", nextSteps: ["Run `amcu doctor`; no existing user window was moved."])
        }
        // A newly created marker is ours, even when Chrome made itself active.
        // No application-wide follow: other profiles belong to other tasks.
        let reply = try StageClient.request("put", StageParams(pid: pid, windowIDs: [nativeID], follow: false, by: session))
        guard let move = reply.moves.first, move.ok,
              let landed = Stage.windowFrame(nativeID), StageGeometry.overlap(landed, bounds.cgRect) >= 0.5 else {
            throw AmcuError(.stageUnavailable, "the profile's work window could not be verified on the stage: \(reply.moves.first?.note ?? "unknown position")")
        }
        if let warning = guardFocus.note() {
            FileHandle.standardError.write(Data((warning + "\n").utf8))
        }
        try remember(client.endpoint, browserPID: pid, windowID: windowID, nativeID: nativeID)
        return Placement(windowID: windowID, nativeWindowID: nativeID, bounds: bounds)
    }

    private struct Proof: Codable {
        let identity: BrowserProfileIdentity
        let hostPID: Int32
        let browserPID: Int32
        let windowID: Int
        let nativeID: UInt32
    }
    private static var proofDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/amcu/browser-stage")
    }
    private static func remember(_ endpoint: BrowserEndpoint, browserPID: Int32, windowID: Int, nativeID: UInt32) throws {
        let disk = BrowserPrivateStore(directory: proofDirectory)
        let identity = try BrowserProfileIdentity(endpoint: endpoint)
        try disk.locked {
            var proofs = try disk.load("proofs.json", as: [Proof].self) ?? []
            proofs.removeAll { $0.identity == identity || kill($0.browserPID, 0) != 0 }
            proofs.append(Proof(identity: identity, hostPID: endpoint.pid, browserPID: browserPID, windowID: windowID, nativeID: nativeID))
            try disk.save(proofs, name: "proofs.json")
        }
    }

    /// Read-only proof. A restart invalidates old native/browser window ids;
    /// matching titles and numeric tab hints cannot make a new proof.
    public static func isVerified(endpoint: BrowserEndpoint, tabID: Int, browserWindowID: Int) throws -> Bool {
        guard !Stage.screenIsLocked, let stage = Stage.display(),
              let pid = Stage.browserPID(for: endpoint),
              let identity = try? BrowserProfileIdentity(endpoint: endpoint) else { return false }
        let disk = BrowserPrivateStore(directory: proofDirectory)
        let proofs = try disk.locked { try disk.load("proofs.json", as: [Proof].self) ?? [] }
        guard let proof = proofs.first(where: { $0.identity == identity && $0.hostPID == endpoint.pid && $0.browserPID == pid && $0.windowID == browserWindowID }),
              let frame = Stage.windowFrame(proof.nativeID), StageGeometry.overlap(frame, stage.bounds) >= 0.5 else { return false }
        // The supplied tab/window membership comes from this exact profile's
        // fresh tabs.list response; no user window is moved while checking.
        return tabID > 0 && kill(proof.browserPID, 0) == 0
    }
}
