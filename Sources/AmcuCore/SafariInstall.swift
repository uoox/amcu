import AppKit
import Foundation

/// Builds the Safari container app from this very binary, registers it, and
/// diagnoses what is still missing.
///
/// Nothing is compiled at install time: the app's executable and the appex's
/// executable are both copies of the running amcu (the appex copy enters
/// `NSExtensionMain` when it finds itself inside an `.appex`), the plists and
/// the extension's files are generated from what the binary carries, and the
/// bundle is signed with `codesign`, which every Mac has. So the release
/// tarball is enough — no Xcode on the user's machine.
public enum SafariInstall {
    // MARK: - Locations

    public static var defaultAppURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent(SafariBridge.appName + ".app", isDirectory: true)
    }

    /// `AMCU_SAFARI_APP` relocates the bundle (tests, unusual setups).
    public static var appURL: URL {
        if let custom = ProcessInfo.processInfo.environment["AMCU_SAFARI_APP"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        // The relay running from inside the app uses the app it lives in.
        let own = Bundle.main.bundleURL
        if own.pathExtension == "app", Bundle.main.bundleIdentifier == SafariBridge.appBundleID { return own }
        return defaultAppURL
    }

    public static func appExecutableURL(_ app: URL) -> URL {
        app.appendingPathComponent("Contents/MacOS/\(SafariBridge.appExecutable)")
    }

    public static func appexURL(_ app: URL) -> URL {
        app.appendingPathComponent("Contents/PlugIns/\(SafariBridge.appexName).appex", isDirectory: true)
    }

    public static func appexInfoURL(_ app: URL) -> URL {
        appexURL(app).appendingPathComponent("Contents/Info.plist")
    }

    public static func appexResourcesURL(_ app: URL) -> URL {
        appexURL(app).appendingPathComponent("Contents/Resources", isDirectory: true)
    }

    public static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/amcu/safari-relay.log")
    }

    // MARK: - Plists

    public static func appInfo(version: String) -> [String: Any] {
        [
            "CFBundleIdentifier": SafariBridge.appBundleID,
            "CFBundleExecutable": SafariBridge.appExecutable,
            "CFBundleName": SafariBridge.appName,
            "CFBundleDisplayName": SafariBridge.appName,
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "CFBundleSupportedPlatforms": ["MacOSX"],
            "LSMinimumSystemVersion": "14.0",
            // No Dock icon, no menu bar: the app only exists to carry the
            // extension and to run the relay in the background.
            "LSUIElement": true,
            "NSHumanReadableCopyright": "amcu — https://github.com/uoox/amcu"
        ]
    }

    public static func appexInfo(version: String, config: SafariBridge.RelayConfig) -> [String: Any] {
        [
            "CFBundleIdentifier": SafariBridge.extensionBundleID,
            "CFBundleExecutable": SafariBridge.appexExecutable,
            "CFBundleName": SafariBridge.appexName,
            "CFBundleDisplayName": "amcu bridge",
            "CFBundlePackageType": "XPC!",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "CFBundleSupportedPlatforms": ["MacOSX"],
            "LSMinimumSystemVersion": "14.0",
            "NSExtension": [
                "NSExtensionPointIdentifier": "com.apple.Safari.web-extension",
                "NSExtensionPrincipalClass": SafariBridge.handlerClassName
            ],
            SafariBridge.portKey: Int(config.port),
            SafariBridge.tokenKey: config.token,
            SafariBridge.versionKey: version
        ]
    }

    /// Safari only loads sandboxed extensions. Loopback TCP to the relay is
    /// all the appex needs beyond that.
    public static let appexEntitlements: [String: Any] = [
        "com.apple.security.app-sandbox": true,
        "com.apple.security.network.client": true
    ]

    // MARK: - Extension files

    /// The extension as it is written into the appex: the Safari-specific
    /// files plus the content script and icons shared with the Chrome
    /// extension (one source of truth for the page outline).
    public static var extensionFiles: [(name: String, data: Data)] {
        var files = SafariExtensionBundle.files.map { ($0.name, $0.data) }
        for name in SafariExtensionBundle.sharedWithChrome {
            if let file = ExtensionBundle.files.first(where: { $0.name == name }) { files.append((name, file.data)) }
        }
        return files
    }

    // MARK: - Signing

    public enum Signer: Equatable {
        case adHoc
        case identity(String)

        public var codesignArgument: String {
            switch self {
            case .adHoc: return "-"
            case .identity(let name): return name
            }
        }

        public var description: String {
            switch self {
            case .adHoc: return "ad-hoc (no certificate)"
            case .identity(let name): return name
            }
        }

        public var isDeveloperID: Bool {
            if case .identity(let name) = self { return name.hasPrefix("Developer ID Application") }
            return false
        }
    }

    /// Picks how to sign from `security find-identity -v -p codesigning`
    /// output: a Developer ID Application identity if there is one (Safari
    /// can then load the extension without "Allow unsigned extensions"), an
    /// explicitly requested AMCU_SIGN_IDENTITY if it exists, else ad-hoc.
    public static func chooseSigner(identityListing: String, requested: String?) -> Signer {
        let names = identityListing.split(separator: "\n").compactMap { line -> String? in
            guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close else { return nil }
            return String(line[line.index(after: open)..<close])
        }
        if let requested, !requested.isEmpty, names.contains(where: { $0 == requested || $0.contains(requested) }) {
            return .identity(names.first { $0 == requested } ?? names.first { $0.contains(requested) }!)
        }
        if let developerID = names.first(where: { $0.hasPrefix("Developer ID Application") }) {
            return .identity(developerID)
        }
        return .adHoc
    }

    // MARK: - Install

    public struct InstallReport: Encodable {
        public let app: String
        public let version: String
        public let signer: String
        public let developerID: Bool
        public let registered: Bool
        public let relayPort: Int
        public let relayRestarted: Bool
        public let steps: [String]
    }

    /// The one-time steps that need a person, in order. Shared by install's
    /// report and by doctor.
    public static func ownerSteps(developerID: Bool) -> [String] {
        var steps: [String] = []
        if !developerID {
            steps.append("Safari → Settings → Advanced → tick \"Show features for web developers\" (already on if the Develop menu shows), then Settings → Developer → tick \"Allow unsigned extensions\" (asks for your password; Safari turns it off again every time it quits, so repeat after a Safari restart).")
        }
        steps.append("Safari → Settings → Extensions → tick \"amcu bridge\".")
        steps.append("Still there, click \"Edit Websites…\" (or the extension's website access) and set \"Other websites\" to Allow — without it the extension can list tabs but not read or act on pages.")
        return steps
    }

    public static func install(appURL target: URL = appURL) throws -> InstallReport {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: BrowserInstall.executablePath).resolvingSymlinksInPath()
        guard fm.isExecutableFile(atPath: source.path) else {
            throw AmcuError(.unsupported, "cannot find the running amcu binary to copy (\(source.path))")
        }
        let version = AmcuVersion.string
        let config = try relayConfigForInstall(existingApp: target)

        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(SafariBridge.appName)-\(getpid()).app", isDirectory: true)
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }

        let appexDir = appexURL(staging)
        try fm.createDirectory(at: staging.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: appexDir.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: appexResourcesURL(staging), withIntermediateDirectories: true)

        try writePlist(appInfo(version: version), to: staging.appendingPathComponent("Contents/Info.plist"))
        try Data("APPL????".utf8).write(to: staging.appendingPathComponent("Contents/PkgInfo"))
        try fm.copyItem(at: source, to: appExecutableURL(staging))
        try writePlist(appexInfo(version: version, config: config), to: appexInfoURL(staging))
        try fm.copyItem(at: source, to: appexDir.appendingPathComponent("Contents/MacOS/\(SafariBridge.appexExecutable)"))
        for file in extensionFiles {
            try file.data.write(to: appexResourcesURL(staging).appendingPathComponent(file.name))
        }

        let listing = (try? run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]).output) ?? ""
        let signer = chooseSigner(identityListing: listing, requested: ProcessInfo.processInfo.environment["AMCU_SIGN_IDENTITY"])
        let entitlements = staging.appendingPathComponent("Contents/appex.entitlements")
        try writePlist(appexEntitlements, to: entitlements)
        var signArgs = ["--force", "--sign", signer.codesignArgument]
        if signer.isDeveloperID { signArgs += ["--options", "runtime", "--timestamp"] }
        let appexSign = try run("/usr/bin/codesign", signArgs + ["--entitlements", entitlements.path, appexDir.path])
        try fm.removeItem(at: entitlements)
        guard appexSign.status == 0 else {
            throw AmcuError(.unsupported, "codesign failed for the extension: \(appexSign.output)")
        }
        let appSign = try run("/usr/bin/codesign", signArgs + [staging.path])
        guard appSign.status == 0 else {
            throw AmcuError(.unsupported, "codesign failed for the app: \(appSign.output)")
        }

        // The old relay runs the old binary and holds the port; stop it so
        // the next command starts the new one.
        var restarted = false
        if let endpoint = SafariRelay.runningEndpoint() {
            kill(endpoint.pid, SIGTERM)
            restarted = true
            usleep(300_000)
        }
        if fm.fileExists(atPath: target.path) {
            _ = try? run(lsregister, ["-u", target.path])
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: staging, to: target)

        _ = try? run(lsregister, ["-f", target.path])
        _ = try? run("/usr/bin/pluginkit", ["-a", appexURL(target).path])
        let registered = isRegistered(appURL: target)
        return InstallReport(
            app: target.path,
            version: version,
            signer: signer.description,
            developerID: signer.isDeveloperID,
            registered: registered,
            relayPort: Int(config.port),
            relayRestarted: restarted,
            steps: ownerSteps(developerID: signer.isDeveloperID)
        )
    }

    /// Keeps the port and token of an existing install so a reinstall does
    /// not strand a running extension; picks fresh ones otherwise, or when
    /// the old port is now taken by something else.
    static func relayConfigForInstall(existingApp: URL) throws -> SafariBridge.RelayConfig {
        if let info = NSDictionary(contentsOf: appexInfoURL(existingApp)) as? [String: Any],
           let existing = SafariBridge.relayConfig(from: info) {
            let heldByOurRelay = SafariRelay.runningEndpoint() != nil
            if heldByOurRelay || RelaySockets.portIsFree(existing.port) { return existing }
        }
        for _ in 0..<50 {
            let port = UInt16.random(in: 49_200...60_999)
            if RelaySockets.portIsFree(port) { return .init(port: port, token: SafariBridge.randomToken()) }
        }
        throw AmcuError(.unsupported, "found no free loopback port for the Safari relay")
    }

    public static func uninstall(appURL target: URL = appURL) throws -> Bool {
        if let endpoint = SafariRelay.runningEndpoint() { kill(endpoint.pid, SIGTERM) }
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        _ = try? run("/usr/bin/pluginkit", ["-r", appexURL(target).path])
        _ = try? run(lsregister, ["-u", target.path])
        try FileManager.default.removeItem(at: target)
        return true
    }

    // MARK: - Status

    public struct Status: Encodable {
        public var appPath: String
        public var appInstalled: Bool
        public var appVersion: String?
        public var binaryVersion: String
        public var signatureValid: Bool
        public var signer: String?
        public var registered: Bool
        public var safariInstalled: Bool
        public var safariRunning: Bool
        public var safariEnabled: Bool?
        public var safariWebsiteAccess: String?
        public var relayRunning: Bool
        public var relayPid: Int?
        public var relayError: String?
        public var extensionPolling: Bool
        public var extensionVersion: String?
        public var lastPollAgoSeconds: Int?
        public var hostAccess: Bool?

        public init(appPath: String, appInstalled: Bool, appVersion: String?, binaryVersion: String, signatureValid: Bool, signer: String?, registered: Bool, safariInstalled: Bool, safariRunning: Bool, safariEnabled: Bool?, safariWebsiteAccess: String?, relayRunning: Bool, relayPid: Int?, relayError: String?, extensionPolling: Bool, extensionVersion: String?, lastPollAgoSeconds: Int?, hostAccess: Bool?) {
            self.appPath = appPath; self.appInstalled = appInstalled; self.appVersion = appVersion; self.binaryVersion = binaryVersion
            self.signatureValid = signatureValid; self.signer = signer; self.registered = registered; self.safariInstalled = safariInstalled
            self.safariRunning = safariRunning; self.safariEnabled = safariEnabled; self.safariWebsiteAccess = safariWebsiteAccess
            self.relayRunning = relayRunning; self.relayPid = relayPid; self.relayError = relayError; self.extensionPolling = extensionPolling
            self.extensionVersion = extensionVersion; self.lastPollAgoSeconds = lastPollAgoSeconds; self.hostAccess = hostAccess
        }
    }

    /// Gathers everything doctor reports. Starts the relay when the app is
    /// installed (a background process, nothing visible) and gives the
    /// extension `pollWait` seconds to check in.
    public static func status(appURL target: URL = appURL, pollWait: TimeInterval = 5) -> Status {
        let fm = FileManager.default
        let installed = fm.fileExists(atPath: appExecutableURL(target).path) && fm.fileExists(atPath: appexInfoURL(target).path)
        let appVersion = (NSDictionary(contentsOf: appexInfoURL(target)) as? [String: Any])?[SafariBridge.versionKey] as? String
        var signatureValid = false
        var signer: String?
        if installed {
            signatureValid = ((try? run("/usr/bin/codesign", ["--verify", "--deep", "--strict", target.path]).status) ?? 1) == 0
            if let details = try? run("/usr/bin/codesign", ["-dvv", target.path]).output {
                if details.contains("Signature=adhoc") { signer = "ad-hoc" }
                else if let line = details.split(separator: "\n").first(where: { $0.hasPrefix("Authority=") }) { signer = String(line.dropFirst("Authority=".count)) }
            }
        }
        let safariInstalled = fm.fileExists(atPath: "/Applications/Safari.app")
        let safariRunning = !runningPids(bundleID: "com.apple.Safari").isEmpty
        let enabled = safariExtensionState()

        var relayRunning = false
        var relayPid: Int?
        var relayError: String?
        var polling = false
        var extVersion: String?
        var lastPoll: Int?
        var hostAccess: Bool?
        if installed {
            do {
                let endpoint = try SafariRelay.ensureRunning(appURL: target)
                relayRunning = true
                relayPid = Int(endpoint.pid)
                let deadline = Date().addingTimeInterval(pollWait)
                var info = relayHello(endpoint)
                while info?["ready"] as? Bool != true && Date() < deadline {
                    usleep(250_000)
                    info = relayHello(endpoint)
                }
                polling = info?["ready"] as? Bool == true
                extVersion = info?["extensionVersion"] as? String
                lastPoll = info?["lastPollAgoSeconds"] as? Int
                hostAccess = info?["hostAccess"] as? Bool
            } catch let error as AmcuError {
                relayError = error.message
            } catch {
                relayError = "\(error)"
            }
        }
        return Status(
            appPath: target.path, appInstalled: installed, appVersion: appVersion, binaryVersion: AmcuVersion.string,
            signatureValid: signatureValid, signer: signer, registered: installed && isRegistered(appURL: target),
            safariInstalled: safariInstalled, safariRunning: safariRunning, safariEnabled: enabled.enabled,
            safariWebsiteAccess: enabled.websiteAccess, relayRunning: relayRunning, relayPid: relayPid, relayError: relayError,
            extensionPolling: polling, extensionVersion: extVersion, lastPollAgoSeconds: lastPoll, hostAccess: hostAccess
        )
    }

    public struct Check: Encodable, Equatable {
        public let ok: Bool
        public let name: String
        public let detail: String
        public let next: [String]
    }

    /// Turns a status into doctor's checklist. Pure, so every branch is
    /// testable without Safari.
    public static func diagnose(_ s: Status) -> [Check] {
        var checks: [Check] = []
        let install = "amcu browser install --browser safari"
        guard s.safariInstalled else {
            return [Check(ok: false, name: "safari", detail: "Safari is not installed at /Applications/Safari.app", next: [])]
        }
        guard s.appInstalled else {
            checks.append(Check(ok: false, name: "app", detail: "the container app is not installed (\(s.appPath))", next: ["Run `\(install)`."]))
            return checks
        }
        if s.appVersion != s.binaryVersion {
            checks.append(Check(ok: false, name: "app", detail: "installed bridge is \(s.appVersion ?? "unknown"), this binary is \(s.binaryVersion)", next: ["Run `\(install)` to update it."]))
        } else {
            checks.append(Check(ok: true, name: "app", detail: "\(s.appPath) (\(s.binaryVersion))", next: []))
        }
        checks.append(s.signatureValid
            ? Check(ok: true, name: "signature", detail: "valid, \(s.signer ?? "unknown signer")", next: [])
            : Check(ok: false, name: "signature", detail: "codesign --verify fails — the bundle was modified or half-copied", next: ["Run `\(install)`."]))
        checks.append(s.registered
            ? Check(ok: true, name: "registration", detail: "the extension is registered with the system (pluginkit)", next: [])
            : Check(ok: false, name: "registration", detail: "the system does not list the extension", next: ["Run `\(install)`; it registers the app with LaunchServices and pluginkit."]))
        if let error = s.relayError {
            checks.append(Check(ok: false, name: "relay", detail: error, next: ["See \(logURL.path); re-run `\(install)`."]))
        } else if s.relayRunning {
            checks.append(Check(ok: true, name: "relay", detail: "running (pid \(s.relayPid ?? 0)); it starts on demand and exits after 30 idle minutes", next: []))
        }
        if !s.safariRunning {
            checks.append(Check(ok: false, name: "extension", detail: "Safari is not running, so the extension cannot check in", next: ["Open Safari (the bridge needs it running, like any extension)."]))
            return checks
        }
        if s.extensionPolling {
            var detail = "polling the relay (extension \(s.extensionVersion ?? "?"))"
            var next: [String] = []
            if let version = s.extensionVersion, version != s.binaryVersion {
                detail += " — but this binary is \(s.binaryVersion)"
                next.append("Safari still runs the old extension; turn amcu bridge off and on in Safari Settings → Extensions.")
            }
            checks.append(Check(ok: next.isEmpty, name: "extension", detail: detail, next: next))
            if s.hostAccess == false {
                checks.append(Check(ok: false, name: "website access", detail: "the extension may not read or act on pages", next: [ownerSteps(developerID: true).last!]))
            } else if s.hostAccess == true {
                checks.append(Check(ok: true, name: "website access", detail: "granted on all websites", next: []))
            }
            return checks
        }
        // Registered, Safari running, but no poll: one of the owner's steps is missing.
        var detail = "Safari is running but the extension has not contacted the relay"
        if s.safariEnabled == false { detail += " (Safari lists it as turned off)" }
        if let ago = s.lastPollAgoSeconds { detail += "; last contact \(ago)s ago — Safari may have put its background page to sleep, or was restarted" }
        let developerID = s.signer?.hasPrefix("Developer ID Application") == true
        checks.append(Check(ok: false, name: "extension", detail: detail, next: ownerSteps(developerID: developerID) + [
            "Then run `amcu browser doctor --browser safari` again."
        ]))
        return checks
    }

    // MARK: - Helpers

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    public static func isRegistered(appURL target: URL) -> Bool {
        guard let output = try? run("/usr/bin/pluginkit", ["-m", "-v", "-i", SafariBridge.extensionBundleID]).output else { return false }
        return output.contains(SafariBridge.extensionBundleID) && output.contains(target.lastPathComponent)
    }

    /// Safari's own record of the extension, when the file is readable:
    /// whether it is turned on and the website access level.
    static func safariExtensionState() -> (enabled: Bool?, websiteAccess: String?) {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Safari")
        for name in ["WebExtensions/Extensions.plist", "AppExtensions/Extensions.plist"] {
            guard let plist = NSDictionary(contentsOf: base.appendingPathComponent(name)) as? [String: Any] else { continue }
            for (key, value) in plist where key.hasPrefix(SafariBridge.extensionBundleID + " ") || key == SafariBridge.extensionBundleID {
                let entry = value as? [String: Any] ?? [:]
                let enabled = entry["Enabled"] as? Bool
                let level = (entry["WebsiteAccess"] as? [String: Any])?["Level"] as? String
                return (enabled, level)
            }
        }
        return (nil, nil)
    }

    static func relayHello(_ endpoint: BrowserEndpoint) -> [String: Any]? {
        guard let fd = RelaySockets.connectUnix(path: endpoint.socket) else { return nil }
        defer { close(fd) }
        guard RelaySockets.writeLine(fd, ["id": 0, "method": "hello", "params": [:]]) else { return nil }
        var buffer = Data()
        guard let line = RelaySockets.readLine(fd, buffer: &buffer, timeout: 3),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        return object["result"] as? [String: Any]
    }

    static func runningPids(bundleID: String) -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
    }

    static func writePlist(_ object: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

extension RelaySockets {
    static func connectUnix(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dest in
                for (index, byte) in bytes.enumerated() { dest[index] = byte }
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); return nil }
        return fd
    }
}
