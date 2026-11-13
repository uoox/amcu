import Foundation
import AmcuCore

/// Dispatch before BrowserCommands' ordinary page-action setup.
/// run expects flags.positional == ["launch"] or ["task", "save|status|list|resume"].
enum BrowserRecoveryCommands {
    /// Optional authoritative window-id verifier. Never implement using title pairing.
    /// Until wired, existing stage pages conservatively report stage_pending.
    static var verifyStageTab: ((BrowserEndpoint, Int, Int) throws -> Bool)? = {
        try BrowserStage.isVerified(endpoint: $0, tabID: $1, browserWindowID: $2)
    }

    static let helpText = """
    amcu browser launch --profile X [--browser B] [--timeout S]
      Launch only a uniquely recorded identity; never installs or logs in.
    amcu browser task save --name T --profile X --tab ID [--stage] [--session PREFIX]
      Add/replace one profile entry; no actions are accepted. Session prefixes are isolated per entry.
    amcu browser task list
    amcu browser task status --name T
      Read only: does not launch, open pages, bind sessions, or verify website login.
    amcu browser task resume --name T [--open-missing] [--launch-missing] [--timeout S]
      Bind only a unique exact URL; explicit flags permit missing pages/profiles.
      Stage reuse requires authoritative current on-stage verification, not the saved tab id.
      --stage saves placement intent, not proof of current placement or website login.
    amcu browser profiles --known
      Historical identities, not proof of connection or website login.
    URLs explicitly saved include query strings/fragments, which may contain private tokens.
    No cookies, page text, credentials, or actions are stored.
    """

    static func knownProfiles(_ flags: Flags) throws {
        let records = try BrowserRegistry().list().filter { flags.string("browser") == nil || $0.identity.browser == flags.string("browser") }
        Output.emit(records) {
            records.map { record in
                "\(record.identity.browser) \(record.identity.profileDir) instance=\(record.identity.instanceId) root=\(record.identity.userDataDir) label=\(record.label ?? "-") app=\(record.applicationPath ?? "unknown")"
            }.joined(separator: "\n") + "\nunverified: historical record only; connection and website login not verified"
        }
    }

    static func run(_ flags: Flags) throws {
        if flags.has("help") || flags.positional == ["task", "help"] || flags.positional == ["task"] {
            Output.emit(helpText) { helpText }
            return
        }
        let registry = BrowserRegistry()
        let store = BrowserTaskStore()
        let timeout = try flags.double("timeout") ?? 30
        guard timeout.isFinite, timeout > 0, timeout <= 600 else { throw AmcuError(.invalidArgument, "--timeout must be between 0 and 600 seconds") }
        if flags.positional.first == "launch" {
            try validate(flags, allowed: ["profile", "browser", "timeout"])
            recordDiscovery(registry, endpoints: BrowserClient.discover())
            let record = try registry.select(profile: flags.required("profile"), browser: flags.string("browser"))
            let report = try BrowserRecovery.launch(record, timeout: timeout)
            Output.emit(report) { "\(report.state): \(report.identity.browser) \(report.identity.profileDir)\n\(report.loginVerification)" }
            if !report.connected { throw AmcuError(.bridgeUnavailable, "launch submitted but the exact profile did not connect; inspect before retrying") }
            return
        }
        guard flags.positional.count == 2, flags.positional[0] == "task" else { throw AmcuError(.invalidArgument, "expected browser launch or browser task save/status/list/resume") }
        let verb = flags.positional[1]
        switch verb {
        case "save":
            // Strict allowlist: a saved task can never carry an action, JS, text, or secret.
            try validate(flags, allowed: ["name", "profile", "browser", "tab", "stage", "session", "timeout"])
            let name = try flags.required("name")
            let selector = try flags.required("profile")
            let endpoint = try BrowserSelection.choose(from: BrowserClient.discover(), browser: flags.string("browser"), profile: selector)
            try registry.record([endpoint])
            let identity = try BrowserProfileIdentity(endpoint: endpoint)
            try identity.validateOnDisk()
            guard let id = try flags.int("tab"), id > 0 else { throw AmcuError(.invalidArgument, "save requires --tab ID") }
            let client = BrowserClient(endpoint: endpoint)
            let result = try client.request("tabs.list", params: [:], timeout: timeout)
            guard let tab = result["tabs"].array.first(where: { $0["id"].int == id }), let url = tab["url"].string else {
                throw AmcuError(.invalidArgument, "selected tab is absent or has no URL")
            }
            let task = try store.save(name: name, identity: identity, url: url, tabHint: id, stage: flags.has("stage"), session: flags.string("session"))
            Output.emit(Saved(task: task, privacy: BrowserTaskStore.privacyNotice)) { "saved \(task.name): \(task.entries.count) profile entries\n\(BrowserTaskStore.privacyNotice)" }
        case "list":
            try validate(flags, allowed: [])
            let tasks = try store.list()
            Output.emit(tasks) { tasks.map { "\($0.name): \($0.entries.count) profiles" }.joined(separator: "\n") + "\n" + BrowserTaskStore.privacyNotice }
        case "status", "resume":
            try validate(flags, allowed: verb == "status" ? ["name", "timeout"] : ["name", "timeout", "open-missing", "launch-missing"])
            let name = try flags.required("name")
            let token = verb == "resume" ? try store.acquireResume(name: name) : nil
            defer {
                if let token {
                    do { try store.releaseResume(token: token) }
                    catch { FileHandle.standardError.write(Data(("could not release task reservation: \(error)\n").utf8)) }
                }
            }
            let task = try store.load(name: name)
            if verb == "resume" { recordDiscovery(registry, endpoints: BrowserClient.discover()) }
            var operations = operations(registry: registry, timeout: timeout)
            let open = operations.open
            operations.open = { endpoint, entry in
                let tab = try open(endpoint, entry)
                // Persist only a hint; authoritative stage verification is repeated on every run.
                try store.recordOpened(name: name, entry: entry, tab: tab.id)
                return tab
            }
            let reports = BrowserTaskRecovery.run(task, resume: verb == "resume", openMissing: flags.has("open-missing"),
                                                  launchMissing: flags.has("launch-missing"), operations: operations) { item in
                // Keep stdout a single JSON document; progress is observable per entry on stderr.
                if verb == "resume" { FileHandle.standardError.write(Data(("\(item.identity.profileDir) [\(item.session)]: \(item.state)\n").utf8)) }
            }
            let summary = BrowserTaskRecoveryReport(progress: reports)
            Output.emit(summary) {
                reports.map { "\($0.identity.profileDir) [\($0.session)]: \($0.state)\($0.detail.map { " — " + $0 } ?? "")" }.joined(separator: "\n")
                    + "\nunverified: website login has not been checked; bridge is not an account"
            }
            if !summary.ok { throw AmcuError(.bridgeUnavailable, "task recovery is incomplete; see progress JSON for each profile", nextSteps: ["Inspect failed/offline/missing/stage_pending/ambiguous entries before retrying."]) }
        default: throw AmcuError(.invalidArgument, "unknown browser task verb '\(verb)'")
        }
    }

    static func recordDiscovery(_ registry: BrowserRegistry, endpoints: [BrowserEndpoint]) {
        for endpoint in endpoints {
            do { try registry.record([endpoint]) }
            catch { FileHandle.standardError.write(Data(("registry did not record \(endpoint.summary): \(error)\n").utf8)) }
        }
    }

    private struct Saved: Encodable { let task: BrowserTask; let privacy: String }
    private static func validate(_ flags: Flags, allowed: Set<String>) throws {
        let supplied = Set(flags.values.keys).union(flags.booleans).subtracting(["json"])
        let unexpected = supplied.subtracting(allowed)
        guard unexpected.isEmpty else { throw AmcuError(.invalidArgument, "unsupported recovery flags: \(unexpected.sorted().joined(separator: ", "))") }
    }

    static func operations(registry: BrowserRegistry, timeout: TimeInterval) -> BrowserTaskOperations {
        BrowserTaskOperations(discover: { BrowserClient.discover() }, tabs: { endpoint in
            let result = try BrowserClient(endpoint: endpoint).request("tabs.list", timeout: timeout)
            return try result["tabs"].array.compactMap { item in
                guard let id = item["id"].int, let url = item["url"].string else { return nil }
                let onStage: Bool
                if let window = item["windowId"].int, let verify = verifyStageTab { onStage = try verify(endpoint, id, window) }
                else { onStage = false }
                return BrowserRecoveryTab(id: id, url: url, verifiedOnStage: onStage)
            }
        }, bind: { endpoint, id, session in
            _ = try BrowserClient(endpoint: endpoint).request("tabs.select", params: ["tab": id, "session": session, "activate": false], timeout: timeout)
        }, open: { endpoint, entry in
            let client = BrowserClient(endpoint: endpoint)
            var params: [String: Any] = ["url": entry.url, "session": entry.session, "activate": false, "wait": true]
            if entry.stage {
                let placement = try BrowserStage.prepare(client: client, session: entry.session, timeout: timeout)
                params["stageWindowId"] = placement.windowID
                params["stageBounds"] = ["left": Int(placement.bounds.x), "top": Int(placement.bounds.y + 40),
                                         "width": min(1280, Int(placement.bounds.width)), "height": min(850, Int(placement.bounds.height - 40))]
            }
            let result = try client.request("tabs.create", params: params, timeout: timeout)
            guard let id = result["tab"]["id"].int, let url = result["tab"]["url"].string else {
                throw AmcuError(.invalidArgument, "new tab response is incomplete; inspect tabs before retrying")
            }
            let verified: Bool
            if entry.stage, let window = result["tab"]["windowId"].int, let verify = verifyStageTab {
                verified = try verify(endpoint, id, window)
            } else { verified = false }
            return BrowserRecoveryTab(id: id, url: url, verifiedOnStage: verified)
        }, launch: { identity in
            let matches = try registry.list().filter { $0.identity == identity }
            let sameID = try registry.list().filter { $0.identity.instanceId == identity.instanceId }
            guard matches.count == 1, sameID.count == 1 else { throw AmcuError(.ambiguousBrowser, "task identity has no unique registry launch record") }
            _ = try BrowserRecovery.launch(matches[0], timeout: timeout)
        })
    }
}
