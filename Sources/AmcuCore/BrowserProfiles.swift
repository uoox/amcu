import Foundation

/// Finds which browser profile a connected extension instance lives in.
///
/// The extension cannot see its own profile directory, but it can leave a mark
/// the host can: it stores a key named `amcu_instance_<id>` in
/// chrome.storage.local, which Chromium keeps in a leveldb under
/// `<profile>/Local Extension Settings/<extension id>/`. leveldb writes keys
/// verbatim into its `.log`, so a byte search over the profiles of the host's
/// parent browser finds the one that holds the id. Table files (`.ldb`) are
/// searched too but may be compressed; the extension re-writes the key at every
/// start so the newest log carries it in plain text.
public enum ProfileLocator {
    public static let markerPrefix = "amcu_instance_"

    /// Above this a file is not one of the extension's tiny stores.
    static let maxScannedFileSize = 32 << 20

    // MARK: - User data directory

    /// The browser's `--user-data-dir`, else the default directory for that
    /// browser name. Chromium only accepts the `--switch=value` form.
    public static func userDataDirectory(arguments: [String], browser: String) -> URL? {
        // Chromium takes the last occurrence of a repeated switch.
        for argument in arguments.reversed() where argument.hasPrefix("--user-data-dir=") {
            let raw = String(argument.dropFirst("--user-data-dir=".count))
            let expanded = (raw as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return defaultUserDataDirectory(browser: browser)
    }

    public static func defaultUserDataDirectory(browser: String) -> URL? {
        BrowserInstall.knownBrowsers.first { $0.name == browser }?.manifestDirectory.deletingLastPathComponent()
    }

    /// argv of another process of this user, via `KERN_PROCARGS2`.
    public static func processArguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        size = buffer.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// Layout: Int32 argc, the executable path, NUL padding, then argc
    /// NUL-terminated arguments (environment strings follow and are ignored).
    public static func parseProcArgs(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count >= 4 else { return nil }
        let argc = Int(Int32(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
        guard argc >= 0 else { return nil }
        var index = 4
        while index < bytes.count && bytes[index] != 0 { index += 1 }
        while index < bytes.count && bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc && index < bytes.count {
            let start = index
            while index < bytes.count && bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == argc ? arguments : nil
    }

    // MARK: - Profile

    /// The profile directory name (`Default`, `Profile 2`) whose extension
    /// storage holds the instance id. nil when none does, or when more than one
    /// does (a copied profile): either way there is no single honest answer.
    public static func profileDirectory(instanceID: String, extensionID: String, userDataDir: URL) -> String? {
        guard !instanceID.isEmpty, !extensionID.isEmpty else { return nil }
        let marker = Data((markerPrefix + instanceID).utf8)
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: userDataDir.path) else { return nil }
        var found: [String] = []
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let store = userDataDir
                .appendingPathComponent(entry, isDirectory: true)
                .appendingPathComponent("Local Extension Settings", isDirectory: true)
                .appendingPathComponent(extensionID, isDirectory: true)
            guard let files = try? fileManager.contentsOfDirectory(atPath: store.path) else { continue }
            let holds = files.contains { name in
                guard name.hasSuffix(".log") || name.hasSuffix(".ldb") else { return false }
                let path = store.appendingPathComponent(name).path
                guard let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? Int, size <= maxScannedFileSize,
                      let data = fileManager.contents(atPath: path) else { return false }
                return data.range(of: marker) != nil
            }
            if holds { found.append(entry) }
        }
        return found.count == 1 ? found[0] : nil
    }

    /// The name the browser shows for a profile, from `Local State`.
    public static func profileName(userDataDir: URL, profileDir: String) -> String? {
        guard let data = FileManager.default.contents(atPath: userDataDir.appendingPathComponent("Local State").path) else { return nil }
        return profileName(localState: data, profileDir: profileDir)
    }

    public static func profileName(localState: Data, profileDir: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: localState)) as? [String: Any],
              let profile = object["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any],
              let entry = cache[profileDir] as? [String: Any],
              let name = entry["name"] as? String, !name.isEmpty else { return nil }
        return name
    }
}

/// Which connection a browser command goes to.
///
/// Each profile of each browser is its own connection. A command that could
/// mean more than one of them is refused with the candidates and the flag that
/// picks each, never sent to whichever was found first.
public enum BrowserSelection {
    public static func choose(from endpoints: [BrowserEndpoint], browser: String?, profile: String?) throws -> BrowserEndpoint {
        guard !endpoints.isEmpty else {
            throw AmcuError(.bridgeUnavailable, "no browser is connected to amcu", nextSteps: [
                "Run `amcu browser doctor` — it checks the native host registration and whether the extension is loaded.",
                "First time here? `amcu browser install`, then load the extension folder it prints in chrome://extensions (Developer mode → Load unpacked) — in every profile you want to drive.",
                "If the extension is loaded, click its toolbar icon: it says whether the host connected and why not."
            ])
        }
        let browserSelector = browser?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let profileSelector = profile?.trimmingCharacters(in: .whitespaces).nilIfEmpty

        var pool = endpoints
        if let browserSelector {
            pool = pool.filter { matchesBrowser($0, browserSelector) }
            guard !pool.isEmpty else {
                throw AmcuError(.bridgeUnavailable, "no connected browser matches --browser '\(browserSelector)'", nextSteps: [
                    "Connected: \(endpoints.map(\.summary).joined(separator: "; ")).",
                    "Pass --browser NAME or NAME:PID from that list, or --profile (see `amcu browser profiles`)."
                ])
            }
        }
        if let profileSelector {
            let matched = profileMatches(pool, profileSelector)
            guard !matched.isEmpty else {
                var steps = [
                    "Connected: \(pool.map(\.summary).joined(separator: "; ")).",
                    "--profile matches a label, a profile directory (Default, \"Profile 2\"), the profile's display name, or an instance id prefix; `amcu browser profiles` lists them.",
                    "A profile without the extension is not connected: Load unpacked once in that profile too."
                ]
                for old in pool where old.instanceId == nil {
                    steps.append("\(old.summary) runs an extension without identity (\(old.extensionVersion ?? "?")); Reload it in chrome://extensions, or select it with --browser \(old.browser):\(old.pid).")
                }
                throw AmcuError(.bridgeUnavailable, "no connected profile matches --profile '\(profileSelector)'", nextSteps: steps)
            }
            pool = matched
        }
        if pool.count == 1 { return pool[0] }
        if browserSelector == nil, profileSelector == nil {
            // A Safari relay whose extension is not polling would only time
            // out; without an explicit choice, live connections are the field.
            let live = pool.filter(\.ready)
            if live.count == 1 { return live[0] }
            if !live.isEmpty { pool = live }
            let chromes = pool.filter { $0.browser == "chrome" }
            if chromes.count == 1 { return chromes[0] }
        }
        throw ambiguity(pool, among: endpoints, browser: browserSelector, profile: profileSelector)
    }

    /// `chrome`, `chrome:1234`, or a bare host pid.
    public static func matchesBrowser(_ endpoint: BrowserEndpoint, _ selector: String) -> Bool {
        let lowered = selector.lowercased()
        return endpoint.browser == lowered || "\(endpoint.browser):\(endpoint.pid)" == lowered || String(endpoint.pid) == lowered
    }

    /// Tiers, first hit wins: label, profile directory, display name, whole
    /// instance id (all case-insensitive, exact), then instance id prefix. A
    /// label the user chose beats a display name that happens to be the same
    /// word, and a short label is not shadowed by an id starting with it.
    public static func profileMatches(_ endpoints: [BrowserEndpoint], _ selector: String) -> [BrowserEndpoint] {
        let wanted = selector.lowercased()
        let fields: [(BrowserEndpoint) -> String?] = [\.label, \.profileDir, \.profileName, \.instanceId]
        for field in fields {
            let hits = endpoints.filter { field($0)?.lowercased() == wanted }
            if !hits.isEmpty { return hits }
        }
        return endpoints.filter { $0.instanceId?.lowercased().hasPrefix(wanted) == true }
    }

    /// The shortest flag that selects exactly this endpoint among `endpoints`.
    public static func selectingFlag(for endpoint: BrowserEndpoint, among endpoints: [BrowserEndpoint]) -> String {
        for value in [endpoint.label, endpoint.profileDir, endpoint.profileName, endpoint.instanceId].compactMap({ $0 }) {
            let matched = profileMatches(endpoints, value)
            if matched.count == 1, matched[0].socket == endpoint.socket { return "--profile \(shellQuoted(value))" }
        }
        return "--browser \(endpoint.browser):\(endpoint.pid)"
    }

    static func ambiguity(_ pool: [BrowserEndpoint], among endpoints: [BrowserEndpoint], browser: String?, profile: String?) -> AmcuError {
        let asked = [browser.map { "--browser '\($0)'" }, profile.map { "--profile '\($0)'" }].compactMap { $0 }
        let what = asked.isEmpty ? "no --browser or --profile was given" : "\(asked.joined(separator: " and ")) matches \(pool.count)"
        var steps = pool.map { "\($0.summary): \(selectingFlag(for: $0, among: endpoints))" }
        steps.append("`amcu browser profiles` lists every connection; `amcu browser label --name NAME <selector>` names one for later.")
        return AmcuError(.ambiguousBrowser, "\(pool.count) browser connections could take this command (\(what)); refusing to pick one", nextSteps: steps)
    }

    public static func shellQuoted(_ value: String) -> String {
        let plain = value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.:/@".unicodeScalars.contains($0) }
        if plain && !value.isEmpty { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
