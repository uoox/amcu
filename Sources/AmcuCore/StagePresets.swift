import CoreGraphics
import Foundation

/// Named groups of windows that can be tucked onto or released from the stage
/// in one step, persisted in `~/.config/amcu/stage-presets.json`.
public struct StagePreset: Codable, Sendable, Equatable, Identifiable {
    public struct Item: Codable, Sendable, Equatable {
        public let app: String
        public let bundleID: String?
        public let profile: String?
        public let titleHint: String?

        public init(app: String, bundleID: String?, profile: String? = nil, titleHint: String? = nil) {
            self.app = app
            self.bundleID = bundleID
            self.profile = profile
            self.titleHint = titleHint
        }
    }

    public var id: String { name }
    public let name: String
    public let createdAt: Date
    public let items: [Item]

    public init(name: String, createdAt: Date = Date(), items: [Item]) {
        self.name = name
        self.createdAt = createdAt
        self.items = items
    }
}

public enum StagePresetStore {
    public static var url: URL {
        if let custom = ProcessInfo.processInfo.environment["AMCU_STAGE_PRESETS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("amcu/stage-presets.json")
    }

    public static func load(from fileURL: URL = url) -> [StagePreset] {
        guard let data = try? Data(contentsOf: fileURL),
              let presets = try? StageWire.decoder().decode([StagePreset].self, from: data) else { return [] }
        return presets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public static func save(_ preset: StagePreset, to fileURL: URL = url) throws -> [StagePreset] {
        let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw AmcuError(.invalidArgument, "preset name cannot be empty")
        }
        guard !preset.items.isEmpty else {
            throw AmcuError(.invalidArgument, "preset '\(name)' has no windows to save")
        }
        var existing = load(from: fileURL).filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
        existing.append(StagePreset(name: name, createdAt: preset.createdAt, items: preset.items))
        existing.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try write(existing, to: fileURL)
        return existing
    }

    @discardableResult
    public static func delete(name: String, from fileURL: URL = url) throws -> [StagePreset] {
        var existing = load(from: fileURL)
        let before = existing.count
        existing.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard existing.count != before else {
            throw AmcuError(.invalidArgument, "no stage preset named '\(name)'")
        }
        try write(existing, to: fileURL)
        return existing
    }

    private static func write(_ presets: [StagePreset], to fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = StageWire.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(presets)
        try data.write(to: fileURL, options: .atomic)
        chmod(fileURL.path, 0o600)
    }

    /// Deduplicates windows into stable preset items: browser profiles collapse
    /// to `(bundleID, profile)` so tab title changes never break matching.
    public static func buildItems(from windows: [(app: String, bundleID: String?, profile: String?, title: String?)]) -> [StagePreset.Item] {
        var seen = Set<String>()
        var result: [StagePreset.Item] = []
        for entry in windows {
            let appKey = (entry.bundleID ?? entry.app).lowercased()
            let cleanProfile = entry.profile?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let profile = cleanProfile, !profile.isEmpty {
                let key = "p:\(appKey):\(profile.lowercased())"
                guard seen.insert(key).inserted else { continue }
                result.append(StagePreset.Item(app: entry.app, bundleID: entry.bundleID, profile: profile, titleHint: nil))
            } else {
                let hint = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanHint = (hint?.isEmpty == false && hint != entry.app) ? String(hint!.prefix(40)) : nil
                let key = "w:\(appKey):\((cleanHint ?? "").lowercased())"
                guard seen.insert(key).inserted else { continue }
                result.append(StagePreset.Item(app: entry.app, bundleID: entry.bundleID, profile: nil, titleHint: cleanHint))
            }
        }
        return result
    }

    private static func sameApp(_ item: StagePreset.Item, bundleID: String?, app: String) -> Bool {
        if let wanted = item.bundleID, let actual = bundleID {
            return wanted.caseInsensitiveCompare(actual) == .orderedSame
        }
        return item.app.caseInsensitiveCompare(app) == .orderedSame
    }

    public static func matchCandidates(_ preset: StagePreset, in available: [StageAvailableWindow]) -> [StageAvailableWindow] {
        var chosen: [StageAvailableWindow] = []
        var seen = Set<CGWindowID>()
        for item in preset.items {
            let appMatches = available.filter { $0.movable && sameApp(item, bundleID: $0.bundleID, app: $0.app) }
            let matched: [StageAvailableWindow]
            if let profile = item.profile, !profile.isEmpty {
                matched = appMatches.filter { $0.profile?.caseInsensitiveCompare(profile) == .orderedSame }
            } else if appMatches.count > 1, let hint = item.titleHint, !hint.isEmpty {
                let byTitle = appMatches.filter { $0.title.localizedCaseInsensitiveContains(hint) }
                matched = byTitle.isEmpty ? appMatches : byTitle
            } else {
                matched = appMatches
            }
            for win in matched where seen.insert(win.id).inserted {
                chosen.append(win)
            }
        }
        return chosen
    }

    public static func matchStaged(_ preset: StagePreset, windows: [StageWindow], takenOver: [StageTakeover], browser: [CGWindowID: StageTabs.Paired]) -> [CGWindowID] {
        struct Entry {
            let id: CGWindowID
            let app: String
            let bundleID: String?
            let title: String
            let profile: String?
        }
        let pool: [Entry] = windows.map {
            Entry(id: CGWindowID($0.windowID), app: $0.app, bundleID: $0.bundleID, title: $0.title ?? "", profile: browser[CGWindowID($0.windowID)]?.profile)
        } + takenOver.map {
            Entry(id: CGWindowID($0.windowID), app: $0.app, bundleID: $0.bundleID, title: $0.title ?? "", profile: browser[CGWindowID($0.windowID)]?.profile)
        }
        var chosen: [CGWindowID] = []
        var seen = Set<CGWindowID>()
        for item in preset.items {
            let appMatches = pool.filter { sameApp(item, bundleID: $0.bundleID, app: $0.app) }
            let matched: [Entry]
            if let profile = item.profile, !profile.isEmpty {
                matched = appMatches.filter { $0.profile?.caseInsensitiveCompare(profile) == .orderedSame }
            } else if appMatches.count > 1, let hint = item.titleHint, !hint.isEmpty {
                let byTitle = appMatches.filter { $0.title.localizedCaseInsensitiveContains(hint) }
                matched = byTitle.isEmpty ? appMatches : byTitle
            } else {
                matched = appMatches
            }
            for entry in matched where seen.insert(entry.id).inserted {
                chosen.append(entry.id)
            }
        }
        return chosen
    }
}
