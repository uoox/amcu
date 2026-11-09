import CoreGraphics
import Foundation

/// A point as a fraction of a window, from its top-left corner.
public struct StagePoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// `point` (screen coordinates) inside `frame`, or nil when it is not in it.
    public init?(_ point: CGPoint, in frame: CGRect) {
        guard frame.width > 0, frame.height > 0, frame.insetBy(dx: -1, dy: -1).contains(point) else { return nil }
        x = min(1, max(0, Double((point.x - frame.minX) / frame.width)))
        y = min(1, max(0, Double((point.y - frame.minY) / frame.height)))
    }
}

/// One thing an agent did to a window on the stage: what the stage window
/// shows under that window's picture, so the person watching sees how it is
/// being operated and by which session. Typed text never travels, only how
/// much of it there was.
public struct StageActivity: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case click, press, type, paste, setValue = "set-value", replace, key, scroll, drag, menu, window
        case navigate, back, forward, reload, hover, fill, select, upload, script, dialog, tab, resize
        case handBack = "hand-back"
    }

    /// Given by the host, in arrival order.
    public var seq: Int
    public var kind: Kind
    public var session: String
    public var at: Date
    /// The application's process; for a browser verb, the browser's.
    public var pid: Int32
    public var windowID: UInt32?
    /// A browser verb's tab, for the host to find its window.
    public var tabID: Int?
    /// What was acted on, as the accessibility tree or the page names it.
    public var target: String?
    /// Characters typed or filled, files uploaded.
    public var count: Int?
    /// A key combination such as `cmd+v`.
    public var keys: String?
    /// The menu path, the site, the scroll direction, the window operation.
    public var detail: String?
    /// Where in the window it happened.
    public var fraction: StagePoint?
    /// The same thing done again and again in a row (a panel polling with
    /// a script every second) is one line with a count.
    public var repeats: Int?

    public var id: Int { seq }

    /// Whether `other` is this again: same session, same kind, same target.
    public func repeated(by other: StageActivity) -> Bool {
        kind == other.kind && session == other.session && windowID == other.windowID && target == other.target
            && count == other.count && keys == other.keys && detail == other.detail
    }

    public init(kind: Kind, session: String, pid: Int32, windowID: UInt32? = nil, tabID: Int? = nil, target: String? = nil, count: Int? = nil, keys: String? = nil, detail: String? = nil, fraction: StagePoint? = nil, at: Date = Date(), seq: Int = 0) {
        self.seq = seq
        self.kind = kind
        self.session = session
        self.at = at
        self.pid = pid
        self.windowID = windowID
        self.tabID = tabID
        self.target = target.map { StageActivity.clip($0, 60) }
        self.count = count
        self.keys = keys
        self.detail = detail.map { StageActivity.clip($0, 80) }
        self.fraction = fraction
    }

    /// What happened, in a few words, for the person at the screen.
    public func summary(chinese: Bool) -> String {
        let times = repeats ?? 1
        return times > 1 ? "\(once(chinese: chinese)) ×\(times)" : once(chinese: chinese)
    }

    private func once(chinese: Bool) -> String {
        let named = target.map(StageActivity.name(of:)).flatMap { $0.isEmpty ? nil : StageActivity.clip($0, chinese ? 24 : 32) }
        func quoted(_ text: String) -> String { chinese ? "「\(text)」" : "“\(text)”" }
        func on(_ zh: String, _ en: String) -> String {
            guard let named else { return chinese ? zh : en }
            return chinese ? "\(zh)\(quoted(named))" : "\(en) \(quoted(named))"
        }
        let n = count ?? 0
        let known = count != nil
        switch kind {
        case .click: return on("点击", "Clicked")
        case .press:
            let action = detail.map { " (\($0))" } ?? ""
            return on("操作", "Acted on") + action
        case .type:
            guard known else { return chinese ? "输入文字" : "Typed" }
            return chinese ? "输入 \(n) 个字" : "Typed \(n) character\(n == 1 ? "" : "s")"
        case .paste: return chinese ? "粘贴 \(n) 个字" : "Pasted \(n) character\(n == 1 ? "" : "s")"
        case .setValue, .fill:
            let what = known
                ? (chinese ? "填入 \(n) 个字" : "Filled in \(n) character\(n == 1 ? "" : "s")")
                : (chinese ? "填入内容" : "Filled in")
            guard let named else { return what }
            return chinese ? "在\(quoted(named))\(what)" : "\(what) in \(quoted(named))"
        case .replace: return chinese ? "替换为 \(n) 个字" : "Replaced with \(n) character\(n == 1 ? "" : "s")"
        case .key: return (chinese ? "按 " : "Pressed ") + StageActivity.keyLabel(keys ?? "")
        case .scroll:
            switch detail {
            case "up": return chinese ? "向上滚动" : "Scrolled up"
            case "down": return chinese ? "向下滚动" : "Scrolled down"
            default: return chinese ? "横向滚动" : "Scrolled sideways"
            }
        case .drag: return on("拖动", "Dragged")
        case .menu: return chinese ? "菜单\(quoted(detail ?? ""))" : "Menu \(quoted(detail ?? ""))"
        case .window:
            let names: [String: (String, String)] = [
                "raise": ("置前", "raised"), "move": ("移动", "moved"), "resize": ("改大小", "resized"),
                "minimize": ("最小化", "minimised"), "restore": ("还原", "restored")
            ]
            let parts = (detail ?? "").split(separator: ",").compactMap { names[String($0)] }
            if parts.isEmpty { return chinese ? "调整窗口" : "Changed the window" }
            return chinese ? "窗口" + parts.map(\.0).joined(separator: "、") : "Window " + parts.map(\.1).joined(separator: ", ")
        case .navigate: return chinese ? "打开 \(detail ?? "网页")" : "Opened \(detail ?? "a page")"
        case .back: return chinese ? "后退" : "Went back"
        case .forward: return chinese ? "前进" : "Went forward"
        case .reload: return chinese ? "刷新" : "Reloaded"
        case .hover: return on("悬停", "Hovered")
        case .select: return on("选择", "Selected in")
        case .upload: return chinese ? "上传 \(n) 个文件" : "Uploaded \(n) file\(n == 1 ? "" : "s")"
        case .script: return chinese ? "运行脚本" : "Ran a script"
        case .dialog:
            return detail == "dismiss" ? (chinese ? "关掉对话框" : "Dismissed a dialog") : (chinese ? "确认对话框" : "Accepted a dialog")
        case .tab:
            switch detail {
            case "new": return chinese ? "新开标签" : "Opened a tab"
            case "close": return chinese ? "关闭标签" : "Closed a tab"
            default: return chinese ? "切换标签" : "Switched tabs"
            }
        case .resize: return chinese ? "改网页视口大小" : "Resized the viewport"
        case .handBack: return chinese ? "把你接管的窗口收回舞台" : "Took the window back from you"
        }
    }

    /// A page describes an element as `button "Send"`: the name is what the
    /// person sees on the page; the role only when there is no name.
    static func name(of target: String) -> String {
        guard let open = target.firstIndex(of: "\""), target.last == "\"", open < target.index(before: target.endIndex) else { return target }
        let role = target[..<open].trimmingCharacters(in: .whitespaces)
        guard !role.isEmpty, !role.contains(" ") || role.split(separator: " ").count <= 2 else { return target }
        let name = target[target.index(after: open)..<target.index(before: target.endIndex)]
        return name.isEmpty ? role : String(name)
    }

    /// `cmd+shift+v` as ⌘⇧V, `return` as ↩.
    public static func keyLabel(_ keys: String) -> String {
        let symbols: [String: String] = [
            "cmd": "⌘", "command": "⌘", "shift": "⇧", "alt": "⌥", "option": "⌥", "opt": "⌥", "ctrl": "⌃", "control": "⌃", "fn": "fn ",
            "return": "↩", "enter": "↩", "tab": "⇥", "escape": "⎋", "esc": "⎋", "space": "␣", "delete": "⌫", "backspace": "⌫",
            "forwarddelete": "⌦", "up": "↑", "down": "↓", "left": "←", "right": "→", "home": "↖", "end": "↘",
            "pageup": "⇞", "pagedown": "⇟"
        ]
        return keys.split(separator: "+").map { part in
            let raw = String(part)
            return symbols[raw.lowercased()] ?? (raw.count == 1 ? raw.uppercased() : raw)
        }.joined()
    }

    /// A Claude Code session id is a UUID; its first block tells sessions apart.
    public static func sessionLabel(_ session: String) -> String {
        if session.count == 36, session.filter({ $0 == "-" }).count == 4 { return String(session.prefix(8)) }
        return clip(session, 24)
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
