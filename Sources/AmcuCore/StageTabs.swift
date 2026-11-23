import AppKit

/// The tabs of the browser windows on the stage, from the extension of each
/// profile. A window server window and a tab share no id; a browser window
/// is titled after its active tab, which is how the two are paired.
public enum StageTabs {
    public struct Tab: Equatable, Identifiable, Sendable {
        public let id: Int
        public let title: String
        public let url: String
        public let active: Bool
        /// amcu's debugger is on the tab: an agent drives it, or did and has
        /// not let go.
        public let attached: Bool

        public init(id: Int, title: String, url: String, active: Bool, attached: Bool) {
            self.id = id
            self.title = title
            self.url = url
            self.active = active
            self.attached = attached
        }
    }

    /// What the stage window shows for a browser window: the profile it
    /// belongs to (its amcu label, else the profile's name), its tabs, and the
    /// native-host socket used for switching or closing tabs directly.
    public struct Paired: Equatable, Sendable {
        public let profile: String?
        public let tabs: [Tab]
        public let socket: String?

        public init(profile: String?, tabs: [Tab], socket: String? = nil) {
            self.profile = profile
            self.tabs = tabs
            self.socket = socket
        }
    }

    /// A browser's own window: its id there, which only grows, and its tabs.
    public struct BrowserWindow: Equatable, Sendable {
        public let id: Int
        public let tabs: [Tab]
        public let profile: String?
        public let socket: String?

        public init(id: Int, tabs: [Tab], profile: String? = nil, socket: String? = nil) {
            self.id = id
            self.tabs = tabs
            self.profile = profile
            self.socket = socket
        }
    }

    /// Tabs per window on the stage. Only browsers that have a window on the
    /// stage are asked, each profile over its own socket, so an idle stage
    /// costs no round trip. All of a browser's windows take part in the
    /// pairing, on the stage or not, so a twin elsewhere is told apart.
    public static func collect(for windows: [(windowID: CGWindowID, pid: pid_t)]) -> [CGWindowID: Paired] {
        let pids = Set(windows.map(\.pid))
        let directory = BrowserBridge.socketDirectory
        guard !pids.isEmpty, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [:] }
        var browserWindows: [pid_t: [BrowserWindow]] = [:]
        for name in names.sorted() {
            guard let parsed = BrowserBridge.parseSocketName(name) else { continue }
            let endpoint = BrowserEndpoint(browser: parsed.browser, pid: parsed.pid, socket: directory.appendingPathComponent(name).path)
            let client = BrowserClient(endpoint: endpoint)
            guard let browserPID = Stage.browserPID(for: endpoint), pids.contains(browserPID),
                  let reply = try? client.request("tabs.list", params: ["session": "amcu-stage-window"], timeout: 2)
            else { continue }
            let hello = try? client.request("hello", timeout: 2)
            let profile = ["label", "profileName", "profileDir"].lazy.compactMap { hello?[$0].string }.first { !$0.isEmpty }
            var order: [Int] = []
            var tabs: [Int: [Tab]] = [:]
            for item in reply["tabs"].array {
                let windowID = item["windowId"].int ?? 0
                if tabs[windowID] == nil { order.append(windowID) }
                tabs[windowID, default: []].append(Tab(
                    id: item["id"].int ?? 0,
                    title: item["title"].string ?? "",
                    url: item["url"].string ?? "",
                    active: item["active"].bool == true,
                    attached: item["attached"].bool == true
                ))
            }
            browserWindows[browserPID, default: []] += order.map { BrowserWindow(id: $0, tabs: tabs[$0] ?? [], profile: profile, socket: endpoint.socket) }
        }
        var result: [CGWindowID: Paired] = [:]
        for (pid, known) in browserWindows {
            let pairs = pair(namedWindows(pid: pid), with: known)
            for window in windows where window.pid == pid {
                if let index = pairs[window.windowID] {
                    result[window.windowID] = Paired(profile: known[index].profile, tabs: known[index].tabs, socket: known[index].socket)
                }
            }
        }
        return result
    }

    /// Activates a tab inside its staged browser window without focusing the
    /// browser or touching any agent session's current tab.
    @discardableResult
    public static func activate(tabID: Int, socket: String) -> Bool {
        let client = BrowserClient(endpoint: BrowserEndpoint(browser: "browser", pid: 0, socket: socket))
        return (try? client.request("stage.tab.activate", params: ["tab": tabID], timeout: 3)) != nil
    }

    /// Closes a tab inside a staged browser window (refused by the extension
    /// when it is the profile's last tab of its last window).
    @discardableResult
    public static func close(tabID: Int, socket: String) -> Bool {
        let client = BrowserClient(endpoint: BrowserEndpoint(browser: "browser", pid: 0, socket: socket))
        return (try? client.request("stage.tab.close", params: ["tab": tabID], timeout: 3)) != nil
    }

    /// Pairs window server windows with a browser's windows: a window is
    /// titled after its active tab. Where titles repeat (two profiles on the
    /// same site), the windows are paired in creation order — window server
    /// numbers and browser window ids both only grow — if the counts agree,
    /// and not at all if they do not. Values index `browserWindows`.
    public static func pair(_ windows: [(id: CGWindowID, title: String)], with browserWindows: [BrowserWindow]) -> [CGWindowID: Int] {
        let count = windows.count
        var parent = Array(0..<(count + browserWindows.count))
        func root(_ node: Int) -> Int {
            var node = node
            while parent[node] != node {
                parent[node] = parent[parent[node]]
                node = parent[node]
            }
            return node
        }
        var edges = Set<[Int]>()
        for (w, window) in windows.enumerated() where !window.title.isEmpty {
            for (b, browserWindow) in browserWindows.enumerated() {
                guard let active = browserWindow.tabs.first(where: \.active), titled(window.title, by: active) else { continue }
                edges.insert([w, b])
                parent[root(w)] = root(count + b)
            }
        }
        var components: [Int: (windows: [Int], browser: [Int])] = [:]
        for w in 0..<count where edges.contains(where: { $0[0] == w }) {
            components[root(w), default: ([], [])].windows.append(w)
        }
        for b in browserWindows.indices where edges.contains(where: { $0[1] == b }) {
            components[root(count + b), default: ([], [])].browser.append(b)
        }
        var result: [CGWindowID: Int] = [:]
        for component in components.values where component.windows.count == component.browser.count {
            let ordered = component.windows.sorted { windows[$0].id < windows[$1].id }
            let browser = component.browser.sorted { browserWindows[$0].id < browserWindows[$1].id }
            guard zip(ordered, browser).allSatisfy({ edges.contains([$0, $1]) }) else { continue }
            for (w, b) in zip(ordered, browser) { result[windows[w].id] = b }
        }
        return result
    }

    /// The browser's named, normal-level windows anywhere: on screen, on the
    /// stage, on another desktop or minimised.
    static func namedWindows(pid: pid_t) -> [(id: CGWindowID, title: String)] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let title = entry[kCGWindowName as String] as? String, !title.isEmpty,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) >= 100, (bounds["Height"] ?? 0) >= 100
            else { return nil }
            return (id, title)
        }
    }

    /// A browser window is titled after its active tab, maybe with the
    /// browser and profile after it, and a long title shortened in the middle
    /// with "…": every piece around the ellipsis appears in order.
    public static func titled(_ windowTitle: String, by tab: Tab) -> Bool {
        let name = tab.title.isEmpty ? tab.url : tab.title
        guard !name.isEmpty else { return false }
        if windowTitle.hasPrefix(name) { return true }
        let pieces = windowTitle.components(separatedBy: "…").map { $0.trimmingCharacters(in: .whitespaces) }
        guard pieces.count > 1, let first = pieces.first, !first.isEmpty, name.hasPrefix(first) else { return false }
        var rest = name[name.index(name.startIndex, offsetBy: first.count)...]
        for piece in pieces.dropFirst() where !piece.isEmpty {
            guard let found = rest.range(of: piece) else { return false }
            rest = rest[found.upperBound...]
        }
        return true
    }

    /// The site a tab shows, without "www.".
    public static func host(of url: String) -> String {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Identifies which native macOS window corresponds to a browser extension's
/// `chrome.windows.Window` snapshot, refusing when candidates stay ambiguous.
public enum StageBrowserMatcher {
    public struct Candidate: Equatable, Sendable {
        public let id: CGWindowID
        public let frame: CGRect
        public let title: String
        public let main: Bool
        public let zOrder: Int

        public init(id: CGWindowID, frame: CGRect, title: String, main: Bool, zOrder: Int) {
            self.id = id
            self.frame = frame
            self.title = title
            self.main = main
            self.zOrder = zOrder
        }
    }

    public static func match(candidates: [Candidate], target: StageBrowserWindowMatch) -> CGWindowID? {
        guard !candidates.isEmpty else { return nil }
        let wanted = target.bounds.cgRect
        let tab = StageTabs.Tab(id: 0, title: target.title ?? "", url: target.url ?? "", active: true, attached: false)
        let hasTab = !tab.title.isEmpty || !tab.url.isEmpty

        func within(_ rect: CGRect, _ tolerance: CGFloat) -> Bool {
            abs(rect.minX - wanted.minX) <= tolerance
                && abs(rect.minY - wanted.minY) <= tolerance
                && abs(rect.width - wanted.width) <= tolerance
                && abs(rect.height - wanted.height) <= tolerance
        }

        func narrow(_ pool: [Candidate]) -> CGWindowID? {
            if pool.count == 1 { return pool[0].id }
            guard pool.count > 1 else { return nil }
            let byTitle = hasTab ? pool.filter { StageTabs.titled($0.title, by: tab) } : pool
            if byTitle.count == 1 { return byTitle[0].id }
            let active = byTitle.isEmpty ? pool : byTitle
            guard target.focused else { return nil }
            let mains = active.filter(\.main)
            if mains.count == 1 { return mains[0].id }
            return active.min { $0.zOrder < $1.zOrder }?.id
        }

        let exact = candidates.filter { within($0.frame, 4) }
        if !exact.isEmpty { return narrow(exact) }

        if hasTab {
            let near = candidates.filter { within($0.frame, 20) && StageTabs.titled($0.title, by: tab) }
            if let hit = narrow(near) { return hit }
        }
        if target.focused {
            let mainSized = candidates.filter {
                $0.main && abs($0.frame.width - wanted.width) <= 24 && abs($0.frame.height - wanted.height) <= 24
                    && (!hasTab || StageTabs.titled($0.title, by: tab))
            }
            if mainSized.count == 1 { return mainSized[0].id }
        }
        return nil
    }
}
