import Foundation
import Darwin

public struct BrowserTaskEntry: Codable, Equatable {
    public let identity: BrowserProfileIdentity
    public let session: String
    public let url: String
    public let tabHint: Int
    public let stage: Bool

    public init(identity: BrowserProfileIdentity, session: String, url: String, tabHint: Int, stage: Bool = false) throws {
        try BrowserTaskStore.validateURL(url)
        guard tabHint > 0, !session.isEmpty, SessionName.sanitize(session) == session else {
            throw AmcuError(.invalidArgument, "task requires a positive tab hint and a safe, nonempty session")
        }
        self.identity = identity; self.session = session; self.url = url; self.tabHint = tabHint; self.stage = stage
    }
}

public struct BrowserTask: Codable, Equatable {
    public let name: String
    public var entries: [BrowserTaskEntry]
}

public final class BrowserTaskStore {
    public static let privacyNotice = "Explicitly saved URLs include query strings and fragments, which may contain private tokens. No page text, cookies, credentials, or actions are saved. Website login is unverified."
    private struct Document: Codable { var schema = 1; var tasks: [BrowserTask] = [] }
    private struct Lease: Codable { let name: String; let token: String; let expires: Date; let ownerPID: Int32? }
    private struct Leases: Codable { var items: [Lease] = [] }
    private let disk: BrowserPrivateStore
    public init(directory: URL = BrowserRegistry.defaultDirectory) { disk = BrowserPrivateStore(directory: directory) }

    public static func validateURL(_ raw: String) throws {
        guard !raw.isEmpty, !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let url = URLComponents(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw AmcuError(.invalidArgument, "task URL must be absolute http/https without embedded credentials")
        }
    }

    private func document() throws -> Document {
        let document = try disk.load("tasks.json", as: Document.self) ?? Document()
        guard document.schema == 1 else { throw AmcuError(.invalidArgument, "unsupported browser task schema") }
        guard Set(document.tasks.map(\.name)).count == document.tasks.count else { throw AmcuError(.invalidArgument, "duplicate task names") }
        var sessions = Set<String>()
        for task in document.tasks {
            guard !task.name.isEmpty, Set(task.entries.map(\.identity)).count == task.entries.count else { throw AmcuError(.invalidArgument, "duplicate profile entries") }
            for entry in task.entries {
                _ = try BrowserTaskEntry(identity: entry.identity, session: entry.session, url: entry.url, tabHint: entry.tabHint, stage: entry.stage)
                let canonical = try BrowserProfileIdentity(browser: entry.identity.browser, instanceId: entry.identity.instanceId, userDataDir: entry.identity.userDataDir, profileDir: entry.identity.profileDir)
                guard canonical == entry.identity, sessions.insert(entry.session).inserted else { throw AmcuError(.invalidArgument, "noncanonical identity or shared task session") }
            }
        }
        return document
    }
    public func list() throws -> [BrowserTask] { try disk.locked { try document().tasks } }
    public func load(name: String) throws -> BrowserTask {
        guard let task = try list().first(where: { $0.name == name }) else { throw AmcuError(.invalidArgument, "no saved task named '\(name)'") }
        return task
    }

    /// A short transaction reserves a task; the filesystem lock is released before I/O.
    /// Live owners keep the reservation; crashed owners are reclaimed immediately.
    /// Legacy leases without an owner cannot prove active recovery and are reclaimed.
    public func acquireResume(name: String, now: Date = Date()) throws -> String {
        try disk.locked {
            var leases = try disk.load("task-leases.json", as: Leases.self) ?? Leases()
            leases.items.removeAll { lease in
                guard let pid = lease.ownerPID, pid > 0 else { return true }
                // EPERM means the process exists; only ESRCH proves it is dead.
                let dead = kill(pid, 0) != 0 && errno == ESRCH
                return dead || lease.expires <= now
            }
            guard !leases.items.contains(where: { $0.name == name }) else { throw AmcuError(.invalidArgument, "task resume is already in progress; do not launch a second recovery") }
            let token = UUID().uuidString
            leases.items.append(Lease(name: name, token: token, expires: now.addingTimeInterval(86400), ownerPID: getpid()))
            try disk.save(leases, name: "task-leases.json")
            return token
        }
    }
    public func releaseResume(token: String) throws {
        try disk.locked {
            var leases = try disk.load("task-leases.json", as: Leases.self) ?? Leases()
            leases.items.removeAll { $0.token == token }
            try disk.save(leases, name: "task-leases.json")
        }
    }
    /// CAS the hint only: never overwrite a concurrent save with stale task data.
    public func recordOpened(name: String, entry: BrowserTaskEntry, tab: Int) throws {
        try disk.locked {
            var document = try self.document()
            guard let ti = document.tasks.firstIndex(where: { $0.name == name }),
                  let ei = document.tasks[ti].entries.firstIndex(of: entry) else { return }
            document.tasks[ti].entries[ei] = try BrowserTaskEntry(identity: entry.identity, session: entry.session, url: entry.url, tabHint: tab, stage: entry.stage)
            try disk.save(document, name: "tasks.json")
        }
    }

    /// Repeated save replaces just this identity. Each entry owns a separate session,
    /// even when --session is supplied (it is a readable prefix, not a shared namespace).
    @discardableResult
    public func save(name: String, identity: BrowserProfileIdentity, url: String, tabHint: Int,
                     stage: Bool = false, session: String? = nil) throws -> BrowserTask {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 256 else { throw AmcuError(.invalidArgument, "task name is empty or too long") }
        return try disk.locked {
            var document = try self.document()
            let index = document.tasks.firstIndex { $0.name == name }
            var task = index.map { document.tasks[$0] } ?? BrowserTask(name: name, entries: [])
            let old = task.entries.firstIndex { $0.identity == identity }
            let namespace = old.map { task.entries[$0].session } ?? "\(String(SessionName.sanitize(session ?? "task").prefix(40)))-\(UUID().uuidString.lowercased())"
            let entry = try BrowserTaskEntry(identity: identity, session: namespace, url: url, tabHint: tabHint, stage: stage)
            if let old { task.entries[old] = entry } else { task.entries.append(entry) }
            if let index { document.tasks[index] = task } else { document.tasks.append(task) }
            try disk.save(document, name: "tasks.json")
            return task
        }
    }
}

public struct BrowserRecoveryTab: Equatable {
    public let id: Int
    public let url: String
    public let verifiedOnStage: Bool
    public init(id: Int, url: String, verifiedOnStage: Bool = false) { self.id = id; self.url = url; self.verifiedOnStage = verifiedOnStage }
}

/// The only effects permitted by task resume. Stage implementations must create a
/// new page through browser tab --new --stage (never move/click an existing page).
public struct BrowserTaskOperations {
    public var discover: BrowserRecovery.Discover
    public var tabs: (BrowserEndpoint) throws -> [BrowserRecoveryTab]
    public var bind: (BrowserEndpoint, Int, String) throws -> Void
    public var open: (BrowserEndpoint, BrowserTaskEntry) throws -> BrowserRecoveryTab
    public var launch: (BrowserProfileIdentity) throws -> Void
    public init(discover: @escaping BrowserRecovery.Discover,
                tabs: @escaping (BrowserEndpoint) throws -> [BrowserRecoveryTab],
                bind: @escaping (BrowserEndpoint, Int, String) throws -> Void,
                open: @escaping (BrowserEndpoint, BrowserTaskEntry) throws -> BrowserRecoveryTab,
                launch: @escaping (BrowserProfileIdentity) throws -> Void) {
        self.discover = discover; self.tabs = tabs; self.bind = bind; self.open = open; self.launch = launch
    }
}

public struct BrowserTaskProgress: Encodable {
    public var ok: Bool { ["available", "bound", "opened"].contains(state) }
    public let identity: BrowserProfileIdentity
    public let session: String
    public let state: String
    public let tab: Int?
    public let detail: String?
    public let loginVerification = "unverified: website login has not been checked; bridge is not an account"
}

public struct BrowserTaskRecoveryReport: Encodable {
    public let ok: Bool
    public let progress: [BrowserTaskProgress]
    public init(progress: [BrowserTaskProgress]) {
        self.progress = progress
        self.ok = progress.allSatisfy { $0.ok || ["launching", "opening"].contains($0.state) }
    }
}

public enum BrowserTaskRecovery {
    /// Task snapshot is loaded before this call. Never holds the store lock during browser I/O.
    /// tabHint is deliberately ignored: numeric ids can be reused after restart.
    public static func run(_ task: BrowserTask, resume: Bool = false, openMissing: Bool = false,
                           launchMissing: Bool = false, operations: BrowserTaskOperations,
                           progress: (BrowserTaskProgress) -> Void = { _ in }) -> [BrowserTaskProgress] {
        var reports: [BrowserTaskProgress] = []
        for entry in task.entries {
            func report(_ state: String, tab: Int? = nil, detail: String? = nil) {
                let item = BrowserTaskProgress(identity: entry.identity, session: entry.session, state: state, tab: tab, detail: detail)
                reports.append(item); progress(item)
            }
            do {
                try BrowserTaskStore.validateURL(entry.url)
                var endpoint = try BrowserRecovery.connected(entry.identity, among: operations.discover())
                if endpoint == nil, resume, launchMissing {
                    report("launching")
                    try operations.launch(entry.identity)
                    endpoint = try BrowserRecovery.connected(entry.identity, among: operations.discover())
                }
                guard let endpoint else { report("offline"); continue }
                let matches = try operations.tabs(endpoint).filter { $0.url == entry.url }
                if matches.count > 1 { report("ambiguous_url", detail: "multiple exact URLs; no binding or new tab"); continue }
                if let tab = matches.first {
                    if entry.stage && !tab.verifiedOnStage {
                        report("stage_pending", tab: tab.id, detail: "stage requested, but current tab/window is not authoritatively verified on stage; saved tab id is only a hint; no move or duplicate open")
                        continue
                    }
                    if resume { try operations.bind(endpoint, tab.id, entry.session) }
                    report(resume ? "bound" : "available", tab: tab.id)
                } else if resume && openMissing {
                    report("opening")
                    let tab = try operations.open(endpoint, entry)
                    guard tab.url == entry.url else { throw AmcuError(.invalidArgument, "opened page URL changed; not binding a different page") }
                    guard !entry.stage || tab.verifiedOnStage else {
                        report("stage_pending", tab: tab.id, detail: "page created but stage placement is unverified; inspect before retrying")
                        continue
                    }
                    try operations.bind(endpoint, tab.id, entry.session)
                    report("opened", tab: tab.id)
                } else { report("missing_page", detail: "use --open-missing to create a page") }
            } catch { report("failed", detail: String(describing: error)) }
        }
        return reports
    }
}
