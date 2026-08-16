import Foundation

/// Registers this binary as the extension's native messaging host and writes
/// the extension folder to disk. Both are plain files under the user's home:
/// nothing runs at install time, and nothing needs root.
public enum BrowserInstall {
    public struct KnownBrowser {
        public let name: String
        public let displayName: String
        /// Directory the browser reads native messaging manifests from, and
        /// whose parent existing tells us the browser is installed.
        public let manifestDirectory: URL
    }

    public static let knownBrowsers: [KnownBrowser] = {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        func dir(_ path: String) -> URL { support.appendingPathComponent(path, isDirectory: true).appendingPathComponent("NativeMessagingHosts", isDirectory: true) }
        return [
            KnownBrowser(name: "chrome", displayName: "Google Chrome", manifestDirectory: dir("Google/Chrome")),
            KnownBrowser(name: "chrome-beta", displayName: "Google Chrome Beta", manifestDirectory: dir("Google/Chrome Beta")),
            KnownBrowser(name: "chrome-dev", displayName: "Google Chrome Dev", manifestDirectory: dir("Google/Chrome Dev")),
            KnownBrowser(name: "chrome-canary", displayName: "Google Chrome Canary", manifestDirectory: dir("Google/Chrome Canary")),
            KnownBrowser(name: "chrome-for-testing", displayName: "Google Chrome for Testing", manifestDirectory: dir("Google/Chrome for Testing")),
            KnownBrowser(name: "chromium", displayName: "Chromium", manifestDirectory: dir("Chromium")),
            KnownBrowser(name: "edge", displayName: "Microsoft Edge", manifestDirectory: dir("Microsoft Edge")),
            KnownBrowser(name: "edge-beta", displayName: "Microsoft Edge Beta", manifestDirectory: dir("Microsoft Edge Beta")),
            KnownBrowser(name: "edge-dev", displayName: "Microsoft Edge Dev", manifestDirectory: dir("Microsoft Edge Dev")),
            KnownBrowser(name: "brave", displayName: "Brave", manifestDirectory: dir("BraveSoftware/Brave-Browser")),
            KnownBrowser(name: "vivaldi", displayName: "Vivaldi", manifestDirectory: dir("Vivaldi")),
            KnownBrowser(name: "arc", displayName: "Arc", manifestDirectory: dir("Arc/User Data")),
            KnownBrowser(name: "opera", displayName: "Opera", manifestDirectory: dir("com.operasoftware.Opera")),
        ]
    }()

    /// Where the extension folder is written. Chrome loads it from here as an
    /// unpacked extension; the fixed `key` in its manifest gives it the same
    /// id regardless of the path.
    public static var extensionDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/amcu/extension", isDirectory: true)
    }

    public static var manifestFileName: String { BrowserBridge.hostName + ".json" }

    /// The absolute path of the running binary, as invoked. A symlink is kept
    /// as a symlink: `~/.local/bin/amcu` outlives the build it points at.
    public static var executablePath: String {
        let invoked = CommandLine.arguments.first ?? ""
        if invoked.hasPrefix("/") { return URL(fileURLWithPath: invoked).standardizedFileURL.path }
        if invoked.contains("/") {
            return URL(fileURLWithPath: invoked, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
        }
        // Found through PATH: ask the system where.
        if let resolved = Bundle.main.executableURL?.standardizedFileURL.path, !resolved.isEmpty { return resolved }
        return invoked
    }

    public static func manifestJSON(executable: String) -> Data {
        let object: [String: Any] = [
            "name": BrowserBridge.hostName,
            "description": "amcu native messaging host — lets the amcu CLI drive this browser",
            "path": executable,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(BrowserBridge.extensionID)/"]
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    // MARK: - Install

    public struct InstallReport: Encodable {
        public struct Manifest: Encodable {
            public let browser: String
            public let path: String
        }
        public let manifests: [Manifest]
        public let skipped: [String]
        public let extensionDirectory: String
        public let extensionID: String
        public let extensionVersion: String
        public let executable: String
    }

    /// Writes the manifest for every installed browser (or the ones named)
    /// and the extension folder. Idempotent: re-running updates in place.
    /// `manifestDirectory` bypasses the browser list and writes one manifest
    /// exactly there — for a browser started with `--user-data-dir`, which
    /// reads `<that dir>/NativeMessagingHosts` instead of the usual place.
    public static func install(browsers requested: [String], extensionDirectory: URL? = nil, manifestDirectory: URL? = nil) throws -> InstallReport {
        let executable = executablePath
        var written: [InstallReport.Manifest] = []
        var skipped: [String] = []
        let targets: [KnownBrowser]
        if let manifestDirectory {
            targets = [KnownBrowser(name: "custom", displayName: manifestDirectory.path, manifestDirectory: manifestDirectory)]
        } else if requested.isEmpty {
            targets = knownBrowsers
        } else {
            targets = try requested.map { name in
                guard let known = knownBrowsers.first(where: { $0.name == name.lowercased() }) else {
                    throw AmcuError(.invalidArgument, "unknown browser '\(name)'", nextSteps: [
                        "Known: \(knownBrowsers.map(\.name).joined(separator: ", "))."
                    ])
                }
                return known
            }
        }
        for browser in targets {
            let parent = browser.manifestDirectory.deletingLastPathComponent()
            let installed = FileManager.default.fileExists(atPath: parent.path)
            guard installed || !requested.isEmpty || manifestDirectory != nil else {
                skipped.append(browser.name)
                continue
            }
            try FileManager.default.createDirectory(at: browser.manifestDirectory, withIntermediateDirectories: true)
            let file = browser.manifestDirectory.appendingPathComponent(manifestFileName)
            try manifestJSON(executable: executable).write(to: file, options: .atomic)
            written.append(.init(browser: browser.name, path: file.path))
        }

        let directory = extensionDirectory ?? Self.extensionDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in ExtensionBundle.files {
            try file.data.write(to: directory.appendingPathComponent(file.name), options: .atomic)
        }
        return InstallReport(
            manifests: written,
            skipped: skipped,
            extensionDirectory: directory.path,
            extensionID: ExtensionBundle.id,
            extensionVersion: ExtensionBundle.version,
            executable: executable
        )
    }

    // MARK: - Status

    public struct ManifestStatus: Encodable {
        public let browser: String
        public let path: String
        public let present: Bool
        /// The path the manifest points at, when it exists.
        public let executable: String?
        public let pointsAtThisBinary: Bool
        public let allowsThisExtension: Bool
    }

    /// What is on disk, for `doctor`.
    public static func manifestStatuses() -> [ManifestStatus] {
        let executable = executablePath
        var statuses: [ManifestStatus] = []
        for browser in knownBrowsers {
            let parent = browser.manifestDirectory.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: parent.path) else { continue }
            let file = browser.manifestDirectory.appendingPathComponent(manifestFileName)
            guard let data = FileManager.default.contents(atPath: file.path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                statuses.append(.init(browser: browser.name, path: file.path, present: false, executable: nil, pointsAtThisBinary: false, allowsThisExtension: false))
                continue
            }
            let path = object["path"] as? String
            let origins = object["allowed_origins"] as? [String] ?? []
            statuses.append(.init(
                browser: browser.name,
                path: file.path,
                present: true,
                executable: path,
                pointsAtThisBinary: path == executable || (path.map { resolve($0) } == resolve(executable)),
                allowsThisExtension: origins.contains("chrome-extension://\(BrowserBridge.extensionID)/")
            ))
        }
        return statuses
    }

    private static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Whether the extension folder on disk matches the embedded bundle.
    public static func extensionOnDiskMatches(directory: URL? = nil) -> Bool? {
        let directory = directory ?? extensionDirectory
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) else { return nil }
        for file in ExtensionBundle.files {
            guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(file.name).path) else { return false }
            if data != file.data { return false }
        }
        return true
    }
}
