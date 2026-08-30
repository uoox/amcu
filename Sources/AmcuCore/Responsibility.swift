import AppKit
import Foundation

/// The process TCC actually attributes this run's permission checks to.
///
/// A CLI tool never answers for itself: `AXIsProcessTrusted()` and friends
/// resolve to the *responsible process* — normally the app that owns the
/// terminal amcu runs in (Terminal, iTerm, dinotty, …), or the launchd
/// service it runs under (aaa-daemon). Granting the amcu binary a permission
/// in System Settings therefore changes nothing for a terminal-hosted run,
/// which is the single most common reason `doctor` keeps saying "not
/// granted" after the user swears they granted everything.
public struct ResponsibleProcess: Sendable {
    public let pid: pid_t
    public let name: String
    public let path: String?
    /// True when this process answers for itself (launchd service, disclaimed
    /// spawn). There is only one subject then, not two.
    public let isSelf: Bool
}

public enum Responsibility {
    private typealias ResponsiblePidFn = @convention(c) (pid_t) -> pid_t
    private typealias ProcPidPathFn = @convention(c) (pid_t, UnsafeMutableRawPointer?, UInt32) -> Int32
    private typealias SetDisclaimFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>?, Int32) -> Int32

    /// Both symbols are private but have been stable for many releases; they
    /// are resolved at runtime so a future removal degrades to "unknown"
    /// instead of a link failure — the same posture as CGEventSetWindowLocation.
    private static let responsiblePid: ResponsiblePidFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsiblePidFn.self)
    }()

    private static let procPidPath: ProcPidPathFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pidpath") else { return nil }
        return unsafeBitCast(sym, to: ProcPidPathFn.self)
    }()

    private static let setDisclaim: SetDisclaimFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(sym, to: SetDisclaimFn.self)
    }()

    /// Resolves who answers for this process, or nil when the private symbol
    /// is gone.
    public static func current() -> ResponsibleProcess? {
        guard let responsiblePid else { return nil }
        let own = getpid()
        let pid = responsiblePid(own)
        guard pid > 0 else { return nil }
        if pid == own {
            return ResponsibleProcess(pid: pid, name: "amcu", path: executablePath, isSelf: true)
        }
        let path = pathFor(pid: pid)
        let app = NSRunningApplication(processIdentifier: pid)
        let name = app?.localizedName
            ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "pid \(pid)"
        return ResponsibleProcess(pid: pid, name: name, path: app?.bundleURL?.path ?? path, isSelf: false)
    }

    private static func pathFor(pid: pid_t) -> String? {
        guard let procPidPath else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBytes { procPidPath(pid, $0.baseAddress, 4096) }
        guard length > 0 else { return nil }
        return String(decoding: buffer[0..<Int(length)], as: UTF8.self)
    }

    public static var executablePath: String {
        Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? "amcu"
    }

    /// Whether `spawnSelfDisclaimed` can work on this system.
    public static var canDisclaim: Bool { setDisclaim != nil }

    /// Re-runs this binary with responsibility disclaimed, so the child is its
    /// own TCC subject and its permission checks answer for the amcu binary
    /// itself rather than for the hosting terminal. Returns the child's stdout,
    /// or nil when the spawn is impossible or the child misbehaves.
    public static func spawnSelfDisclaimed(arguments: [String], timeout: TimeInterval = 5) -> Data? {
        guard let setDisclaim else { return nil }

        var attr: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attr) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attr) }
        guard setDisclaim(&attr, 1) == 0 else { return nil }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let readEnd = fds[0], writeEnd = fds[1]

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addclose(&actions, readEnd)
        posix_spawn_file_actions_addclose(&actions, writeEnd)

        let path = executablePath
        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, environ)
        close(writeEnd)
        guard rc == 0 else {
            close(readEnd)
            return nil
        }

        // The child only makes two fast, prompt-free API calls; the timeout is
        // insurance against it wedging, not an expected path.
        var output = Data()
        let reader = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = FileHandle(fileDescriptor: readEnd, closeOnDealloc: true)
            output = (try? handle.readToEnd()) ?? Data()
            reader.signal()
        }
        if reader.wait(timeout: .now() + timeout) == .timedOut {
            kill(pid, SIGKILL)
            _ = reader.wait(timeout: .now() + 1)
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return output.isEmpty ? nil : output
    }
}
