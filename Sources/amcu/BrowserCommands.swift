import Foundation
import AmcuCore

/// `amcu browser <verb>` — web pages, through the extension.
///
/// Every verb resolves a connected browser, sends one request over the host
/// socket, and formats the reply. The extension does the work; this file is
/// argument handling and presentation.
enum BrowserCommands {
    static let helpText = """
    amcu browser — read and drive web pages in the user's own browser

    USAGE
      amcu browser <verb> [flags]

    SET UP (once)
      install     [--browser chrome,edge]   register the native host and write the extension folder
                  [--extension-dir D] [--manifest-dir D]   (a browser run with --user-data-dir reads
                                        <that dir>/NativeMessagingHosts; point --manifest-dir there)
      doctor                                check registration, extension, connection
      status                                what is connected, attached, and current
      guide                                 operating instructions for an agent

    TABS
      tabs                                  list tabs (id, window, title, url); marks the current one
      frames                                list the current tab's frames (ids appear in refs as f<id>)
      tab         --new [--url U]           open a tab in the background (--activate to show it)
      tab         --select ID               make ID the session's current tab (--activate to show it)
      tab         --close [--tab ID]        close a tab
      navigate    --url U                   load a URL in the current tab and wait for it
      back | forward | reload [--hard]

    READ
      snapshot    [--selector CSS] [--interactive] [--all-refs] [--max-nodes N] [--frame ID]
                                            the page as an accessibility outline with refs
      screenshot  [--out F] [--ref R] [--full] [--format png|jpeg]
      eval        --js EXPR [--ref R]       evaluate in the page (a function receives the element)
      console     [--level error] [--clear] console messages, including ones logged before attach
      network     [--clear]                 requests seen since the debugger attached
      wait        --text T | --text-gone T | --url U | --load | --time S

    ACT (by ref from the last snapshot)
      click       --ref R [--button right] [--count 2] [--mod cmd] [--force]
      hover       --ref R
      type        --ref R --text T [--submit] [--slowly] [--replace]
      fill        --ref R --value V         replace the value and read it back (verified)
      select-option --ref R --value V | --values A,B
      key         --key K [--mod cmd,shift] [--ref R] [--count N]
      scroll      [--dy N] [--dx N] [--ref R]
      drag        --from R --to R
      upload      --ref R --file F[,F2]
      dialog      [--accept [--text T] | --dismiss]
      resize      --width W --height H
      detach      [--all]                   release the debugger (removes the infobar)

    COMMON FLAGS
      --tab ID          act on a specific tab instead of the session's current one
      --session NAME    keep a separate current tab per agent (default: "default")
      --browser NAME    chrome, edge, brave, … or NAME:PID when several are connected
      --timeout S       per-command limit in seconds (default 30; navigation and wait honour it)
      --json            machine-readable output

    Refs look like e12 (main frame) or f42e12 (frame 42). They are re-verified
    against the element's role and name before use; a changed page yields a
    stale_snapshot error, not a click on whatever moved there.
    """

    static func run(_ flags: Flags) throws {
        guard let verb = flags.positional.first else {
            print(helpText)
            return
        }
        switch verb {
        case "install": try install(flags)
        case "doctor": try doctor(flags)
        case "status": try status(flags)
        case "guide": print(browserGuideText)
        case "help": print(helpText)
        case "tabs": try tabs(flags)
        case "frames": try frames(flags)
        case "tab": try tab(flags)
        case "navigate", "goto", "open": try navigate(flags)
        case "back": try simple(flags, "back", action: "back")
        case "forward": try simple(flags, "forward", action: "forward")
        case "reload": try simple(flags, "reload", action: "reload", extra: ["hard": flags.has("hard")])
        case "snapshot": try snapshot(flags)
        case "screenshot": try screenshot(flags)
        case "eval", "evaluate": try evaluate(flags)
        case "console": try console(flags)
        case "network": try network(flags)
        case "wait": try wait(flags)
        case "click": try click(flags)
        case "hover": try hover(flags)
        case "type": try type(flags)
        case "fill": try fill(flags)
        case "select-option", "select": try selectOption(flags)
        case "key", "press": try key(flags)
        case "scroll": try scroll(flags)
        case "drag": try drag(flags)
        case "upload": try upload(flags)
        case "dialog": try dialog(flags)
        case "resize": try resize(flags)
        case "detach": try detach(flags)
        default:
            throw AmcuError(.invalidArgument, "unknown browser verb '\(verb)'", nextSteps: ["Run `amcu browser help` for the verb list."])
        }
    }

    // MARK: - Shared

    static func client(_ flags: Flags) throws -> BrowserClient {
        try BrowserClient.select(flags.string("browser") ?? ProcessInfo.processInfo.environment["AMCU_BROWSER"])
    }

    /// The parameters every tab-scoped request carries.
    static func baseParams(_ flags: Flags) throws -> [String: Any] {
        var params: [String: Any] = ["session": flags.string("session") ?? "default"]
        if let tab = try flags.int("tab") { params["tab"] = tab }
        if let seconds = try flags.double("timeout") { params["timeoutMs"] = Int(seconds * 1000) }
        return params
    }

    static func timeout(_ flags: Flags, default fallback: TimeInterval = 30) throws -> TimeInterval {
        try flags.double("timeout") ?? fallback
    }

    static func requiredRef(_ flags: Flags, _ name: String = "ref") throws -> String {
        let ref = try flags.required(name, hint: "Pass --\(name) with a ref from `amcu browser snapshot`, e.g. --\(name) e12.")
        guard BrowserBridge.parseRef(ref) != nil else {
            throw AmcuError(.invalidArgument, "'\(ref)' is not a ref", nextSteps: [
                "Refs look like e12 (main frame) or f42e12 (frame 42), exactly as printed by `amcu browser snapshot`."
            ])
        }
        return ref
    }

    /// `tab 123 "Title" https://…` — every result names the tab it touched.
    static func tabLine(_ tab: JSONValue) -> String {
        let id = tab["id"].int.map(String.init) ?? "?"
        let title = tab["title"].string ?? ""
        let url = tab["url"].string ?? ""
        return "tab \(id) \"\(title)\" \(url)"
    }

    static func afterLine(_ after: JSONValue) -> String? {
        guard !after.isNull else { return nil }
        if !after["dialog"].isNull {
            let dialog = after["dialog"]
            return "→ a \(dialog["type"].string ?? "dialog") dialog opened: \"\(dialog["message"].string ?? "")\" — handle it with `amcu browser dialog --accept [--text T]` or `--dismiss`"
        }
        if after["closed"].bool == true { return "→ the tab closed" }
        if after["navigated"].bool == true {
            let loading = after["loading"].bool == true ? " (still loading)" : ""
            return "→ navigated to \(after["url"].string ?? "?")\(loading)"
        }
        return nil
    }

    struct BrowserResult: Encodable {
        let ok = true
        let browser: String
        let action: String
        let result: AnyEncodable
    }

    static func emit(_ client: BrowserClient, action: String, result: JSONValue, text: () -> String) {
        Output.emit(BrowserResult(browser: client.endpoint.browser, action: action, result: result.encodable), text: text)
    }

    // MARK: - Setup

    static func install(_ flags: Flags) throws {
        let browsers = flags.list("browser")
        let directory = flags.string("extension-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let manifestDirectory = flags.string("manifest-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let report = try BrowserInstall.install(browsers: browsers, extensionDirectory: directory, manifestDirectory: manifestDirectory)
        // A running extension can reload itself to pick up the new files.
        var reloaded: [String] = []
        for endpoint in BrowserClient.discover() {
            if let client = try? BrowserClient.select("\(endpoint.browser):\(endpoint.pid)"),
               (try? client.request("extension.reload", timeout: 5)) != nil {
                reloaded.append(endpoint.label)
            }
        }
        struct Payload: Encodable {
            let ok = true
            let report: BrowserInstall.InstallReport
            let reloaded: [String]
        }
        Output.emit(Payload(report: report, reloaded: reloaded)) {
            var lines: [String] = []
            for manifest in report.manifests {
                lines.append("registered native host for \(manifest.browser): \(manifest.path)")
            }
            if report.manifests.isEmpty {
                lines.append("no supported browser found on this Mac (looked for \(BrowserInstall.knownBrowsers.map(\.name).joined(separator: ", ")))")
            }
            lines.append("host binary: \(report.executable)")
            lines.append("wrote extension \(report.extensionVersion) (id \(report.extensionID)) to \(report.extensionDirectory)")
            lines.append("")
            if reloaded.isEmpty {
                lines.append("next: in the browser open chrome://extensions, turn on Developer mode (top right), click \"Load unpacked\"")
                lines.append("      and choose:  \(report.extensionDirectory)")
                lines.append("      (in the file dialog, ⌘⇧G lets you paste that path; already loaded? click Reload on the amcu bridge card)")
                lines.append("then: amcu browser doctor")
            } else {
                lines.append("asked the running extension to reload itself: \(reloaded.joined(separator: ", "))")
                lines.append("then: amcu browser doctor")
            }
            return lines.joined(separator: "\n")
        }
    }

    static func doctor(_ flags: Flags) throws {
        let manifests = BrowserInstall.manifestStatuses()
        let onDisk = BrowserInstall.extensionOnDiskMatches()
        let endpoints = BrowserClient.discover()

        struct Payload: Encodable {
            let ok: Bool
            let executable: String
            let manifests: [BrowserInstall.ManifestStatus]
            let extensionDirectory: String
            let extensionOnDisk: String
            let extensionID: String
            let extensionVersion: String
            let connected: [BrowserEndpoint]
        }
        let anyManifest = manifests.contains { $0.present && $0.pointsAtThisBinary && $0.allowsThisExtension }
        let payload = Payload(
            ok: anyManifest && !endpoints.isEmpty,
            executable: BrowserInstall.executablePath,
            manifests: manifests,
            extensionDirectory: BrowserInstall.extensionDirectory.path,
            extensionOnDisk: onDisk == nil ? "missing" : (onDisk! ? "current" : "outdated"),
            extensionID: ExtensionBundle.id,
            extensionVersion: ExtensionBundle.version,
            connected: endpoints
        )
        Output.emit(payload) {
            var lines = ["amcu browser doctor — extension \(ExtensionBundle.version), id \(ExtensionBundle.id)"]
            if manifests.isEmpty {
                lines.append("  [  ] no supported browser found; install Chrome, Edge, Brave, Chromium, Vivaldi, Arc or Opera")
            }
            for status in manifests {
                let mark: String
                let detail: String
                if !status.present {
                    mark = "  "; detail = "native host not registered — run `amcu browser install`"
                } else if !status.pointsAtThisBinary {
                    mark = "  "; detail = "manifest points at \(status.executable ?? "?"), not this binary — run `amcu browser install`"
                } else if !status.allowsThisExtension {
                    mark = "  "; detail = "manifest allows a different extension id — run `amcu browser install`"
                } else {
                    mark = "ok"; detail = "native host registered (\(status.path))"
                }
                lines.append("  [\(mark)] \(status.browser): \(detail)")
            }
            switch onDisk {
            case nil:
                lines.append("  [  ] extension folder: missing — run `amcu browser install`, then Load unpacked from \(BrowserInstall.extensionDirectory.path)")
            case false?:
                lines.append("  [  ] extension folder: outdated — run `amcu browser install`, then Reload the extension in chrome://extensions")
            case true?:
                lines.append("  [ok] extension folder: \(BrowserInstall.extensionDirectory.path) (current)")
            }
            if endpoints.isEmpty {
                lines.append("  [  ] connection: no browser is talking to amcu")
                lines.append("       next: load the extension (chrome://extensions → Developer mode → Load unpacked → the folder above), then click its icon: it says whether the host connected")
                lines.append("       next: if it is loaded and still not connected, click Reload on its card — the manifest is read when the extension starts")
            } else {
                for endpoint in endpoints {
                    let versionNote = endpoint.extensionVersion == ExtensionBundle.version
                        ? "extension \(endpoint.extensionVersion ?? "?")"
                        : "extension \(endpoint.extensionVersion ?? "?") — binary carries \(ExtensionBundle.version); run `amcu browser install` and Reload the extension"
                    lines.append("  [ok] connection: \(endpoint.label) — \(versionNote)")
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    static func status(_ flags: Flags) throws {
                let client = try client(flags)
        let result = try client.request("status", params: try baseParams(flags), timeout: 10)
        emit(client, action: "status", result: result) {
            var lines = ["browser: \(client.endpoint.label) — extension \(result["version"].string ?? "?"), host since \(client.endpoint.since ?? "?")"]
            lines.append("tabs: \(result["tabs"].int ?? 0), debugger attached to: \(result["attached"].array.compactMap { $0.int.map(String.init) }.joined(separator: ", ").ifEmpty("none"))")
            let sessions = result["sessions"].dictionary
            if sessions.isEmpty {
                lines.append("sessions: none (commands use the browser's active tab)")
            } else {
                lines.append("sessions: " + sessions.map { "\($0.key) → tab \($0.value.int ?? 0)" }.sorted().joined(separator: ", "))
            }
            let others = BrowserClient.discover().filter { $0.pid != client.endpoint.pid }
            if !others.isEmpty {
                lines.append("also connected: \(others.map(\.label).joined(separator: ", ")) (choose with --browser)")
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Tabs

    static func tabs(_ flags: Flags) throws {
                let client = try client(flags)
        let result = try client.request("tabs.list", params: try baseParams(flags), timeout: 10)
        emit(client, action: "tabs", result: result) {
            let tabs = result["tabs"].array
            var lines = tabs.map { tab -> String in
                var marks: [String] = []
                if tab["current"].bool == true { marks.append("current") }
                if tab["active"].bool == true { marks.append("active") }
                if tab["attached"].bool == true { marks.append("attached") }
                let suffix = marks.isEmpty ? "" : "  (\(marks.joined(separator: ", ")))"
                return "id=\(tab["id"].int ?? 0)\twin=\(tab["windowId"].int ?? 0):\(tab["index"].int ?? 0)\t\(tab["title"].string ?? "")\t\(tab["url"].string ?? "")\(suffix)"
            }
            if lines.isEmpty { lines.append("(no tabs)") }
            if result["current"].isNull {
                lines.append("(no current tab for this session — commands use the active tab; `amcu browser tab --select ID` pins one)")
            }
            return lines.joined(separator: "\n")
        }
    }

    static func frames(_ flags: Flags) throws {
        let client = try client(flags)
        let result = try client.request("frames", params: try baseParams(flags), timeout: 10)
        emit(client, action: "frames", result: result) {
            var lines = [tabLine(result["tab"])]
            for frame in result["frames"].array {
                let id = frame["frameId"].int ?? 0
                let parent = frame["parentFrameId"].int ?? -1
                lines.append("frame f\(id)\(parent >= 0 ? " (in f\(parent))" : " (main)")\t\(frame["url"].string ?? "")")
            }
            return lines.joined(separator: "\n")
        }
    }

    static func tab(_ flags: Flags) throws {
        var params = try baseParams(flags)
        let client = try client(flags)
        if flags.has("new") {
            if let url = flags.string("url") { params["url"] = url }
            params["activate"] = flags.has("activate")
            params["wait"] = !flags.has("no-wait")
            let result = try client.request("tabs.create", params: params, timeout: try timeout(flags, default: 40))
            emit(client, action: "tab-new", result: result) {
                "opened \(tabLine(result["tab"])) (now current for this session\(flags.has("activate") ? ", shown" : ", in the background"))"
            }
            return
        }
        if let raw = flags.string("select") {
            guard let id = Int(raw) else { throw AmcuError(.invalidArgument, "--select expects a tab id, got '\(raw)'") }
            params["tab"] = id
            params["activate"] = flags.has("activate")
            let result = try client.request("tabs.select", params: params, timeout: 10)
            emit(client, action: "tab-select", result: result) {
                "current \(tabLine(result["tab"]))\(flags.has("activate") ? " (activated in its window)" : "")"
            }
            return
        }
        if flags.has("close") {
            let result = try client.request("tabs.close", params: params, timeout: 10)
            emit(client, action: "tab-close", result: result) { "closed \(tabLine(result["closed"]))" }
            return
        }
        throw AmcuError(.invalidArgument, "tab needs --new, --select ID or --close", nextSteps: [
            "`amcu browser tabs` lists tabs; `amcu browser tab --new --url https://…` opens one in the background."
        ])
    }

    static func navigate(_ flags: Flags) throws {
        var params = try baseParams(flags)
        params["url"] = flags.string("url") ?? flags.positional.dropFirst().first
        guard params["url"] != nil else {
            throw AmcuError(.invalidArgument, "navigate needs --url", nextSteps: ["Example: amcu browser navigate --url https://example.com"])
        }
        params["wait"] = !flags.has("no-wait")
        let client = try client(flags)
        let result = try client.request("navigate", params: params, timeout: try timeout(flags, default: 40))
        emit(client, action: "navigate", result: result) {
            let loading = result["loading"].bool == true ? " (still loading — `amcu browser wait --load` to finish)" : ""
            return "navigate ok: \(tabLine(result["tab"]))\(loading)"
        }
    }

    static func simple(_ flags: Flags, _ method: String, action: String, extra: [String: Any] = [:]) throws {
        var params = try baseParams(flags)
        for (key, value) in extra { params[key] = value }
        let client = try client(flags)
        let result = try client.request(method, params: params, timeout: try timeout(flags, default: 40))
        emit(client, action: action, result: result) { "\(action) ok: \(tabLine(result["tab"]))" }
    }

    // MARK: - Reading

    static func snapshot(_ flags: Flags) throws {
        var params = try baseParams(flags)
        if let selector = flags.string("selector") { params["selector"] = selector }
        if let frame = try flags.int("frame") { params["frame"] = frame }
        if let maxNodes = try flags.boundedInt("max-nodes", min: 1, max: 50_000) { params["maxNodes"] = maxNodes }
        params["allRefs"] = flags.has("all-refs")
        params["interactiveOnly"] = flags.has("interactive")
        let client = try client(flags)
        let result = try client.request("snapshot", params: params, timeout: try timeout(flags, default: 40))
        emit(client, action: "snapshot", result: result) {
            var lines = [tabLine(result["tab"]) + "  [\(client.endpoint.browser)]"]
            var totalNodes = 0
            var rendered = 0
            var hidden = 0
            var truncated = false
            var focused: String?
            for frame in result["frames"].array {
                let isMain = frame["frameId"].int == 0
                if !isMain {
                    if let error = frame["error"].string {
                        lines.append("frame f\(frame["frameId"].int ?? 0) \(frame["url"].string ?? "") — not readable: \(error)")
                        continue
                    }
                    let parent = frame["parentRef"].string.map { " (iframe [ref=\($0)])" } ?? ""
                    lines.append("")
                    lines.append("frame f\(frame["frameId"].int ?? 0) \(frame["url"].string ?? "")\(parent):")
                }
                let text = frame["text"].string ?? ""
                if !text.isEmpty { lines.append(text) } else if isMain { lines.append("(nothing visible in this document)") }
                totalNodes += frame["nodes"].int ?? 0
                rendered += frame["rendered"].int ?? 0
                hidden += frame["hiddenGenerics"].int ?? 0
                if frame["truncated"].bool == true { truncated = true }
                if let ref = frame["focusedRef"].string { focused = ref }
            }
            var notes: [String] = []
            if hidden > 0 { notes.append("\(hidden) plain containers folded into their parents") }
            if truncated { notes.append("truncated at \(rendered) of \(totalNodes) nodes — narrow with --selector CSS or --interactive, or raise --max-nodes") }
            if let focused { notes.append("focus: \(focused)") }
            if !notes.isEmpty { lines.append("(\(notes.joined(separator: "; ")))") }
            return lines.joined(separator: "\n")
        }
    }

    static func screenshot(_ flags: Flags) throws {
        var params = try baseParams(flags)
        if flags.string("ref") != nil { params["ref"] = try requiredRef(flags) }
        params["full"] = flags.has("full")
        let format = flags.string("format") ?? "png"
        guard format == "png" || format == "jpeg" || format == "jpg" else {
            throw AmcuError(.invalidArgument, "--format must be png or jpeg")
        }
        params["format"] = format == "jpg" ? "jpeg" : format
        if let quality = try flags.boundedInt("quality", min: 1, max: 100) { params["quality"] = quality }
        let client = try client(flags)
        let result = try client.request("screenshot", params: params, timeout: try timeout(flags, default: 30))
        guard let base64 = result["data"].string, let data = Data(base64Encoded: base64) else {
            throw AmcuError(.captureFailure, "the extension returned no image data")
        }
        let ext = params["format"] as? String == "jpeg" ? "jpg" : "png"
        let path = flags.string("out") ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("amcu-tab-\(result["tab"]["id"].int ?? 0).\(ext)").path
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        struct Payload: Encodable {
            let ok = true
            let path: String
            let bytes: Int
            let tab: AnyEncodable
        }
        Output.emit(Payload(path: path, bytes: data.count, tab: result["tab"].encodable)) {
            "wrote \(data.count) bytes of \(ext) to \(path) — \(tabLine(result["tab"]))"
        }
    }

    static func evaluate(_ flags: Flags) throws {
        var params = try baseParams(flags)
        params["expression"] = flags.string("js") ?? flags.string("expression") ?? flags.positional.dropFirst().first
        guard params["expression"] != nil else {
            throw AmcuError(.invalidArgument, "eval needs --js EXPR", nextSteps: [
                "Pass an expression (`document.title`) or a function (`() => location.href`); with --ref, the function receives the element."
            ])
        }
        if flags.string("ref") != nil { params["ref"] = try requiredRef(flags) }
        if let frame = try flags.int("frame") { params["frame"] = frame }
        let client = try client(flags)
        let result = try client.request("evaluate", params: params, timeout: try timeout(flags, default: 40))
        emit(client, action: "eval", result: result) {
            let value = result["value"]
            if let string = value.string { return string }
            if value.isNull { return "null" }
            if let data = try? JSONSerialization.data(withJSONObject: value.raw ?? NSNull(), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return String(describing: value.raw ?? "null")
        }
    }

    static func console(_ flags: Flags) throws {
        var params = try baseParams(flags)
        params["clear"] = flags.has("clear")
        if let level = flags.string("level") { params["level"] = level }
        let client = try client(flags)
        let result = try client.request("console", params: params, timeout: 15)
        emit(client, action: "console", result: result) {
            let messages = result["messages"].array
            var lines = messages.map { message -> String in
                let level = message["level"].string ?? "log"
                let text = message["text"].string ?? ""
                var suffix = ""
                if let url = message["url"].string, !url.isEmpty {
                    suffix = "  (\(url.split(separator: "/").last.map(String.init) ?? url)\(message["line"].int.map { ":\($0)" } ?? ""))"
                }
                return "[\(level)] \(text)\(suffix)"
            }
            if lines.isEmpty { lines.append("(no console messages)") }
            if result["replayed"].bool == true {
                lines.append("(debugger attached just now; messages the page logged earlier were replayed where the browser still had them)")
            }
            return lines.joined(separator: "\n")
        }
    }

    static func network(_ flags: Flags) throws {
        var params = try baseParams(flags)
        params["clear"] = flags.has("clear")
        let client = try client(flags)
        let result = try client.request("network", params: params, timeout: 15)
        emit(client, action: "network", result: result) {
            let requests = result["requests"].array
            var lines = requests.map { request -> String in
                let status = request["failed"].string.map { "failed: \($0)" } ?? request["status"].int.map(String.init) ?? "…"
                return "[\(status)] \(request["method"].string ?? "GET") \(request["url"].string ?? "")\(request["type"].string.map { "  (\($0))" } ?? "")"
            }
            if lines.isEmpty { lines.append("(no requests recorded)") }
            if result["fresh"].bool == true {
                lines.append("(recording started just now — the debugger was not attached before; reload the page or act, then run this again)")
            }
            return lines.joined(separator: "\n")
        }
    }

    static func wait(_ flags: Flags) throws {
        var params = try baseParams(flags)
        if let text = flags.string("text") { params["text"] = text }
        if let text = flags.string("text-gone") { params["textGone"] = text }
        if let url = flags.string("url") { params["url"] = url }
        if flags.has("load") { params["load"] = true }
        if let time = try flags.double("time") { params["time"] = time }
        let seconds = try timeout(flags, default: 30)
        params["timeoutMs"] = Int(seconds * 1000)
        let client = try client(flags)
        let result = try client.request("wait", params: params, timeout: seconds + 5)
        emit(client, action: "wait", result: result) {
            "wait ok (\(result["waited"].string ?? "") after \(result["elapsedMs"].int.map { "\($0) ms" } ?? "\(result["seconds"].double ?? 0)s")): \(tabLine(result["tab"]))"
        }
    }

    // MARK: - Acting

    static func click(_ flags: Flags) throws {
        var params = try baseParams(flags)
        params["ref"] = try requiredRef(flags)
        if let button = flags.string("button") {
            guard ["left", "right", "middle"].contains(button) else {
                throw AmcuError(.invalidArgument, "unknown --button '\(button)'", nextSteps: ["Use one of: left, right, middle."])
            }
            params["button"] = button
        }
        if let count = try flags.boundedInt("count", min: 1, max: 5) { params["count"] = count }
        let modifiers = flags.list("mod")
        if !modifiers.isEmpty { params["modifiers"] = modifiers }
        params["force"] = flags.has("force")
        let client = try client(flags)
        let result = try client.request("click", params: params, timeout: try timeout(flags))
        emit(client, action: "click", result: result) {
            var parts = ["click ok on \(result["ref"].string ?? "") (\(result["description"].string ?? ""))"]
            if let point = result["point"]["x"].int, let y = result["point"]["y"].int { parts.append("at \(point),\(y)") }
            parts.append("via \(result["mode"].string ?? "cdp")")
            var line = parts.joined(separator: " ")
            if let note = result["obscuredNote"].string { line += " (\(note))" }
            if result["fromEarlierSnapshot"].bool == true { line += " (ref from an earlier snapshot)" }
            var lines = [line]
            if let after = afterLine(result["after"]) { lines.append(after) }
            return lines.joined(separator: "\n")
        }
    }

    static func hover(_ flags: Flags) throws {
        var params = try baseParams(flags)
        params["ref"] = try requiredRef(flags)
        let client = try client(flags)
        let result = try client.request("hover", params: params, timeout: try timeout(flags))
        emit(client, action: "hover", result: result) {
            "hover ok on \(result["ref"].string ?? "") (\(result["description"].string ?? "")) at \(result["point"]["x"].int ?? 0),\(result["point"]["y"].int ?? 0)"
        }
    }

    static func type(_ flags: Flags) throws {
        var params = try baseParams(flags)
        params["ref"] = try requiredRef(flags)
        params["text"] = try flags.required("text")
        params["submit"] = flags.has("submit")
        params["slowly"] = flags.has("slowly")
        params["replace"] = flags.has("replace")
        let client = try client(flags)
        let result = try client.request("type", params: params, timeout: try timeout(flags, default: 60))
        emit(client, action: "type", result: result) {
            var line = "type ok on \(result["ref"].string ?? "") (\(result["description"].string ?? "")): \(result["typed"].int ?? 0) characters"
            if result["submitted"].bool == true { line += ", then Enter" }
            if let value = result["value"].string { line += " — value now \"\(value.count > 120 ? String(value.prefix(120)) + "…" : value)\"" }
            var lines = [line]
            if let after = afterLine(result["after"]) { lines.append(after) }
            return lines.joined(separator: "\n")
        }
    }

    static func fill(_ flags: Flags) throws {
        var params = try baseParams(flags)
        params["ref"] = try requiredRef(flags)
        params["value"] = try flags.required("value")
        let client = try client(flags)
        let result = try client.request("fill", params: params, timeout: try timeout(flags))
        guard result["verified"].bool == true else {
            throw AmcuError(.valueMismatch, "element \(result["ref"].string ?? "") accepted the write but holds a different value: wrote '\(result["expected"].string ?? "")', read back '\(result["actual"].string ?? "")'", nextSteps: [
                "The page may normalise or reject the input (masks, validation, custom editors); compare the two values and decide whether the result is acceptable.",
                "For editors that need keystrokes, use `amcu browser type --ref … --text … --slowly`."
            ])
        }
        emit(client, action: "fill", result: result) {
            "fill ok on \(result["ref"].string ?? "") (\(result["description"].string ?? "")) via \(result["mode"].string ?? "") (verified)"
        }
    }

    static func selectOption(_ flags: Flags) throws {
        var params = try baseParams(flags)
        params["ref"] = try requiredRef(flags)
        var values = flags.list("values")
        if let single = flags.string("value") { values.append(single) }
        guard !values.isEmpty else {
            throw AmcuError(.invalidArgument, "select-option needs --value V or --values A,B", nextSteps: [
                "Values match an option's value or its visible label."
            ])
        }
        params["values"] = values
        let client = try client(flags)
        let result = try client.request("select-option", params: params, timeout: try timeout(flags))
        emit(client, action: "select-option", result: result) {
            "select-option ok on \(result["ref"].string ?? "") (\(result["description"].string ?? "")): now \(result["selected"].stringArray.map { "\"\($0)\"" }.joined(separator: ", "))"
        }
    }

    static func key(_ flags: Flags) throws {
        var params = try baseParams(flags)
        params["key"] = try flags.required("key", hint: "For example --key Enter, --key Escape, --key ArrowDown, --key a --mod cmd.")
        let modifiers = flags.list("mod")
        if !modifiers.isEmpty { params["modifiers"] = modifiers }
        if flags.string("ref") != nil { params["ref"] = try requiredRef(flags) }
        if let count = try flags.boundedInt("count", min: 1, max: 100) { params["count"] = count }
        let client = try client(flags)
        let result = try client.request("key", params: params, timeout: try timeout(flags))
        emit(client, action: "key", result: result) {
            let combination = (modifiers + [result["key"].string ?? ""]).joined(separator: "+")
            var lines = ["key ok: \(combination)\((result["count"].int ?? 1) > 1 ? " ×\(result["count"].int ?? 1)" : "") to \(tabLine(result["tab"]))"]
            if let after = afterLine(result["after"]) { lines.append(after) }
            return lines.joined(separator: "\n")
        }
    }

    static func scroll(_ flags: Flags) throws {
        var params = try baseParams(flags)
        let dx = try flags.int32("dx", min: -100_000, max: 100_000) ?? 0
        let dy = try flags.int32("dy", min: -100_000, max: 100_000) ?? 0
        guard dx != 0 || dy != 0 else {
            throw AmcuError(.invalidArgument, "scroll needs --dx and/or --dy", nextSteps: ["Positive --dy scrolls up, negative scrolls down (same as `amcu scroll`)."])
        }
        params["dx"] = Int(dx)
        params["dy"] = Int(dy)
        if flags.string("ref") != nil { params["ref"] = try requiredRef(flags) }
        let client = try client(flags)
        let result = try client.request("scroll", params: params, timeout: try timeout(flags))
        emit(client, action: "scroll", result: result) {
            "scroll ok at \(result["at"].string ?? "viewport") (dx=\(dx) dy=\(dy))"
        }
    }

    static func drag(_ flags: Flags) throws {
        var params = try baseParams(flags)
        params["from"] = try requiredRef(flags, "from")
        params["to"] = try requiredRef(flags, "to")
        if let steps = try flags.boundedInt("steps", min: 2, max: 200) { params["steps"] = steps }
        let client = try client(flags)
        let result = try client.request("drag", params: params, timeout: try timeout(flags))
        emit(client, action: "drag", result: result) {
            "drag ok from \(result["from"].string ?? "") to \(result["to"].string ?? "")"
        }
    }

    static func upload(_ flags: Flags) throws {
        var params = try baseParams(flags)
        params["ref"] = try requiredRef(flags)
        let files = flags.list("file").map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard !files.isEmpty else { throw AmcuError(.invalidArgument, "upload needs --file PATH[,PATH]") }
        for file in files where !FileManager.default.fileExists(atPath: file) {
            throw AmcuError(.invalidArgument, "no such file: \(file)")
        }
        params["files"] = files
        let client = try client(flags)
        let result = try client.request("upload", params: params, timeout: try timeout(flags))
        emit(client, action: "upload", result: result) {
            "upload ok on \(result["ref"].string ?? ""): \(files.count) file\(files.count == 1 ? "" : "s")"
        }
    }

    static func dialog(_ flags: Flags) throws {
        var params = try baseParams(flags)
        params["accept"] = !flags.has("dismiss")
        params["dismiss"] = flags.has("dismiss")
        if let text = flags.string("text") { params["text"] = text }
        let client = try client(flags)
        let result = try client.request("dialog", params: params, timeout: 15)
        emit(client, action: "dialog", result: result) {
            guard result["handled"].bool == true else { return "no dialog is open on \(tabLine(result["tab"]))" }
            let dialog = result["dialog"]
            let what = dialog.isNull ? "the dialog" : "\(dialog["type"].string ?? "dialog") \"\(dialog["message"].string ?? "")\""
            return "\(result["accepted"].bool == true ? "accepted" : "dismissed") \(what)"
        }
    }

    static func resize(_ flags: Flags) throws {
        var params = try baseParams(flags)
        if let width = try flags.boundedInt("width", min: 100, max: 20_000) { params["width"] = width }
        if let height = try flags.boundedInt("height", min: 100, max: 20_000) { params["height"] = height }
        let client = try client(flags)
        let result = try client.request("resize", params: params, timeout: 15)
        emit(client, action: "resize", result: result) {
            "resize ok: window \(result["window"]["id"].int ?? 0) is now \(result["window"]["width"].int ?? 0)x\(result["window"]["height"].int ?? 0)"
        }
    }

    static func detach(_ flags: Flags) throws {
        var params = try baseParams(flags)
        params["all"] = flags.has("all")
        let client = try client(flags)
        let result = try client.request("detach", params: params, timeout: 15)
        emit(client, action: "detach", result: result) {
            let ids = result["detached"].array.compactMap { $0.int }
            return ids.isEmpty ? "nothing was attached" : "detached from tab\(ids.count == 1 ? "" : "s") \(ids.map(String.init).joined(separator: ", "))"
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
