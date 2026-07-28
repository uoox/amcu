import Foundation

/// Snapshots are written to disk so a later command can say `--element 12`
/// without re-sending the whole tree. Sessions are namespaced so that concurrent
/// agents driving different applications do not overwrite each other.
public enum SessionStore {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("umbra", isDirectory: true)
    }

    public static func url(for session: String) throws -> URL {
        guard !session.isEmpty, !session.contains("/"), !session.contains("..") else {
            throw UmbraError(.invalidArgument, "invalid session name '\(session)'", nextSteps: ["Use a plain name such as `--session default`."])
        }
        return directory.appendingPathComponent("session-\(session).json")
    }

    public static func save(_ snapshot: Snapshot, session: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url(for: session), options: .atomic)
    }

    public static func load(session: String) throws -> Snapshot {
        let location = try url(for: session)
        guard let data = FileManager.default.contents(atPath: location.path) else {
            throw UmbraError(.staleSnapshot, "no snapshot recorded for session '\(session)'", nextSteps: [
                "Run `umbra snapshot --app <selector>` first; element indices come from a snapshot."
            ])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Snapshot.self, from: data)
    }

    public static func node(index: Int, session: String) throws -> (Snapshot, SnapshotNode) {
        let snapshot = try load(session: session)
        guard index >= 0, index < snapshot.nodes.count else {
            throw UmbraError(.elementNotFound, "element \(index) is outside the recorded snapshot (0..\(snapshot.nodes.count - 1))", nextSteps: [
                "Re-run `umbra snapshot` and read the indices from its output."
            ])
        }
        return (snapshot, snapshot.nodes[index])
    }
}
