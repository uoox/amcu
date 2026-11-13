import Foundation
import AppKit
import Darwin

/// Persistent identity is never a label, display name, pid, or socket.
public struct BrowserProfileIdentity: Codable, Hashable {
    public let browser: String
    public let instanceId: String
    public let userDataDir: String
    public let profileDir: String

    public init(browser: String, instanceId: String, userDataDir: String, profileDir: String) throws {
        guard !browser.isEmpty, browser.count <= 128,
              browser.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }),
              !instanceId.isEmpty, instanceId.count <= 256,
              instanceId.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }),
              userDataDir.hasPrefix("/"), !userDataDir.contains("\0"),
              !profileDir.isEmpty, profileDir != ".", profileDir != "..",
              !profileDir.contains("/"), !profileDir.contains("\\"), !profileDir.contains("\0") else {
            throw AmcuError(.invalidArgument, "incomplete or unsafe browser profile identity")
        }
        let root = URL(fileURLWithPath: userDataDir).standardizedFileURL.resolvingSymlinksInPath().path
        self.browser = browser
        self.instanceId = instanceId
        self.userDataDir = root
        self.profileDir = profileDir
    }

    private enum CodingKeys: String, CodingKey { case browser, instanceId, userDataDir, profileDir }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let root = try values.decode(String.self, forKey: .userDataDir)
        try self.init(browser: values.decode(String.self, forKey: .browser),
                      instanceId: values.decode(String.self, forKey: .instanceId), userDataDir: root,
                      profileDir: values.decode(String.self, forKey: .profileDir))
        guard userDataDir == root else { throw AmcuError(.invalidArgument, "noncanonical stored profile root") }
    }

    public init(endpoint: BrowserEndpoint) throws {
        guard let id = endpoint.instanceId, let root = endpoint.userDataDir, let dir = endpoint.profileDir else {
            throw AmcuError(.invalidArgument, "browser identity is unknown; refusing to infer a profile")
        }
        try self.init(browser: endpoint.browser, instanceId: id, userDataDir: root, profileDir: dir)
    }

    public func matches(_ endpoint: BrowserEndpoint) -> Bool {
        guard endpoint.ready, let other = try? BrowserProfileIdentity(endpoint: endpoint) else { return false }
        return self == other
    }

    /// Validates directory containment and exactly one extension marker. Never reads cookies.
    public func validateOnDisk(extensionID: String = BrowserBridge.extensionID) throws {
        let checked = try BrowserProfileIdentity(browser: browser, instanceId: instanceId, userDataDir: userDataDir, profileDir: profileDir)
        guard checked == self, !extensionID.isEmpty, !extensionID.contains("/"), extensionID != ".." else {
            throw AmcuError(.invalidArgument, "noncanonical profile identity")
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: userDataDir, isDirectory: true)
        func directory(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        let profile = root.appendingPathComponent(profileDir)
        guard directory(root), directory(profile), profile.resolvingSymlinksInPath().path == profile.path else {
            throw AmcuError(.invalidArgument, "profile directory is missing or escapes its recorded root")
        }
        let marker = Data((ProfileLocator.markerPrefix + instanceId).utf8)
        var hits: [String] = []
        for name in try fm.contentsOfDirectory(atPath: root.path) {
            let candidate = root.appendingPathComponent(name)
            let store = candidate.appendingPathComponent("Local Extension Settings").appendingPathComponent(extensionID)
            guard directory(candidate), store.resolvingSymlinksInPath().path == store.path,
                  let files = try? fm.contentsOfDirectory(atPath: store.path) else { continue }
            let found = files.contains { file in
                guard file.hasSuffix(".log") || file.hasSuffix(".ldb") else { return false }
                let url = store.appendingPathComponent(file)
                guard url.resolvingSymlinksInPath().path == url.path,
                      let attrs = try? fm.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeRegular,
                      let size = attrs[.size] as? Int, size <= 32 << 20,
                      let bytes = try? Data(contentsOf: url) else { return false }
                return bytes.range(of: marker) != nil
            }
            if found { hits.append(name) }
        }
        guard hits == [profileDir] else {
            throw AmcuError(.ambiguousBrowser, "profile marker is absent or cloned; refusing recovery", nextSteps: ["Connect the intended profile and inspect `amcu browser profiles`; do not copy an extension identity."])
        }
    }
}

public struct BrowserRegistryRecord: Codable, Equatable {
    public let identity: BrowserProfileIdentity
    public var label: String?
    public var profileName: String?
    public var applicationBundleID: String?
    public var applicationPath: String?
    public var lastSeen: Date

    public init(identity: BrowserProfileIdentity, label: String? = nil, profileName: String? = nil,
                applicationBundleID: String? = nil, applicationPath: String? = nil, lastSeen: Date = Date()) {
        self.identity = identity
        self.label = label
        self.profileName = profileName
        self.applicationBundleID = applicationBundleID
        self.applicationPath = applicationPath
        self.lastSeen = lastSeen
    }
}

public final class BrowserRegistry {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/amcu/browser", isDirectory: true)
    }
    private let disk: BrowserPrivateStore
    public init(directory: URL = BrowserRegistry.defaultDirectory) { disk = BrowserPrivateStore(directory: directory) }
    private struct Document: Codable { var schema = 1; var profiles: [BrowserRegistryRecord] = [] }

    public func list() throws -> [BrowserRegistryRecord] {
        try disk.locked {
            let document = try disk.load("registry.json", as: Document.self) ?? Document()
            guard document.schema == 1 else { throw AmcuError(.invalidArgument, "unsupported browser registry schema") }
            guard Set(document.profiles.map(\.identity)).count == document.profiles.count else {
                throw AmcuError(.invalidArgument, "duplicate stored browser identities")
            }
            return document.profiles
        }
    }

    /// Call after discovery. Unknown/incomplete endpoints are not made launchable.
    /// Discovery callers should surface persistence errors rather than silently claim history was saved.
    public func record(_ endpoints: [BrowserEndpoint]) throws {
        var records: [BrowserRegistryRecord] = []
        for endpoint in endpoints where endpoint.ready {
            guard endpoint.instanceId != nil, endpoint.userDataDir != nil, endpoint.profileDir != nil else { continue }
            let identity = try BrowserProfileIdentity(endpoint: endpoint)
            try identity.validateOnDisk()
            let app = Stage.browserPID(for: endpoint).flatMap { NSRunningApplication(processIdentifier: $0) }
            records.append(BrowserRegistryRecord(identity: identity, label: endpoint.label, profileName: endpoint.profileName,
                                                applicationBundleID: app?.bundleIdentifier, applicationPath: app?.bundleURL?.path))
        }
        try merge(records)
    }

    /// Also useful for import/tests. Disk identity is revalidated at launch, not trusted from JSON.
    public func merge(_ records: [BrowserRegistryRecord]) throws {
        try disk.locked {
            var document = try disk.load("registry.json", as: Document.self) ?? Document()
            guard document.schema == 1 else { throw AmcuError(.invalidArgument, "unsupported browser registry schema") }
            for var record in records {
                if let i = document.profiles.firstIndex(where: { $0.identity == record.identity }) {
                    record.applicationPath = record.applicationPath ?? document.profiles[i].applicationPath
                    record.applicationBundleID = record.applicationBundleID ?? document.profiles[i].applicationBundleID
                    document.profiles[i] = record
                } else { document.profiles.append(record) }
            }
            try disk.save(document, name: "registry.json")
        }
    }

    public func select(profile: String, browser: String? = nil) throws -> BrowserRegistryRecord {
        let records = try list().filter { browser == nil || $0.identity.browser == browser }
        guard Set(records.map(\.identity)).count == records.count else {
            throw AmcuError(.invalidArgument, "duplicate stored browser identities")
        }
        let wanted = profile.lowercased()
        guard !wanted.isEmpty else { throw AmcuError(.invalidArgument, "--profile must not be empty") }
        let fields: [(BrowserRegistryRecord) -> String?] = [{ $0.label }, { $0.identity.profileDir }, { $0.profileName }, { $0.identity.instanceId }]
        var matches: [BrowserRegistryRecord] = []
        for field in fields {
            matches = records.filter { field($0)?.lowercased() == wanted }
            if !matches.isEmpty { break }
        }
        if matches.isEmpty { matches = records.filter { $0.identity.instanceId.lowercased().hasPrefix(wanted) } }
        guard matches.count == 1 else {
            throw AmcuError(matches.isEmpty ? .bridgeUnavailable : .ambiguousBrowser, "recorded profile selection has \(matches.count) matches; refusing to guess")
        }
        let match = matches[0]
        guard records.filter({ $0.identity.instanceId == match.identity.instanceId }).count == 1 else {
            throw AmcuError(.ambiguousBrowser, "recorded instance identity belongs to multiple profiles")
        }
        return match
    }
}

/// Shared short transactions. No browser operations may run inside this lock.
/// Refuse symlink components, use O_NOFOLLOW, and publish a 0600 temporary file by rename.
final class BrowserPrivateStore {
    let directory: URL
    init(directory: URL) { self.directory = directory.standardizedFileURL }

    private let transactionLock = NSLock()
    private var directoryFD: Int32 = -1
    private func prepare() throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw failure("open filesystem root") }
        do {
            for component in directory.pathComponents.dropFirst() {
                if mkdirat(fd, component, 0o700) != 0 && errno != EEXIST { throw failure("create private directory") }
                let child = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard child >= 0 else { throw failure("refuse non-directory or symlink component") }
                close(fd); fd = child
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == geteuid(), fchmod(fd, 0o700) == 0 else {
                throw failure("validate private directory ownership/permissions")
            }
            return fd
        } catch { close(fd); throw error }
    }
    func locked<T>(_ body: () throws -> T) throws -> T {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        let parent = try prepare()
        defer { close(parent) }
        let fd = openat(parent, "store.lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw failure("open private lock") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, fchmod(fd, 0o600) == 0 else { throw failure("protect private lock") }
        while flock(fd, LOCK_EX) != 0 { if errno != EINTR { throw failure("lock private store") } }
        defer { flock(fd, LOCK_UN) }
        directoryFD = parent
        defer { directoryFD = -1 }
        return try body()
    }
    func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T? {
        let fd = openat(directoryFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 { if errno == ENOENT { return nil }; throw failure("read private store") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_size >= 0, info.st_size <= 16 << 20,
              fchmod(fd, 0o600) == 0 else { throw failure("validate private store file") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return try JSONDecoder().decode(type, from: handle.readToEnd() ?? Data())
    }
    func save<T: Encodable>(_ object: T, name: String) throws {
        let temporary = ".\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure("create private temporary file") }
        defer { close(fd); unlinkat(directoryFD, temporary, 0) }
        let data = try JSONEncoder().encode(object)
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(fd) == 0, renameat(directoryFD, temporary, directoryFD, name) == 0 else { throw failure("publish private store") }
        guard fsync(directoryFD) == 0 else { throw failure("sync private directory") }
    }
    private func failure(_ action: String) -> AmcuError {
        AmcuError(.invalidArgument, "cannot \(action): \(String(cString: strerror(errno)))")
    }
}
