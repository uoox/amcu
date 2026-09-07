import Foundation
import AmcuCore

/// `amcu lab` — a disposable Chrome with the DevTools protocol exposed.
enum LabCommands {
    static let help = """
    amcu lab — a disposable Chrome of amcu's own, with the DevTools protocol exposed

    WHEN
      Extension development (reload, service-worker console, chrome:// pages),
      performance traces, heap snapshots, network interception, device emulation:
      jobs an extension's chrome.debugger is fenced out of. Not for everyday
      pages — those belong in the user's browser via `amcu browser`. The lab
      never sees the user's profile, cookies or logins.

    VERBS
      start   [--url U] [--chrome PATH] [--port N] [--headless] [--name N]
              launch a throwaway profile with the debugging port on localhost and
              the amcu extension loaded (Chrome for Testing / Chromium; branded
              Chrome cannot load it). Opens a visible window unless --headless.
      status  [--name N]                 pid, port, profile, whether it is alive
      targets [--name N]                 pages, service workers, extensions — ids and urls
      cdp     --method M [--params JSON] [--target T] [--timeout S]
              one raw Chrome DevTools Protocol call; the reply is JSON. Browser-
              level methods (Browser.*, Target.*, Storage.*) go to the browser
              endpoint, everything else to the first page unless --target picks
              one (id prefix or url substring).
      stop    [--name N] [--keep-profile]

    THE LAB IS ALSO A BROWSER
      Its profile carries the bridge manifest, so `amcu browser --browser
      chrome-for-testing …` (or chromium) drives it exactly like the user's own.

    EXAMPLES
      amcu lab start --url chrome://extensions
      amcu lab cdp --method Target.getTargets
      amcu lab cdp --method Runtime.evaluate --params '{"expression":"document.title"}' --target example.com
      amcu lab cdp --method Tracing.start --params '{"categories":"devtools.timeline"}'
    """

    static func run(_ flags: Flags) throws {
        let verb = flags.positional.first ?? "help"
        let name = flags.string("name") ?? "default"
        switch verb {
        case "help": print(help)
        case "start":
            let state = try Lab.start(name: name, chrome: flags.string("chrome"), url: flags.string("url"), port: try flags.int("port"), headless: flags.has("headless"))
            Output.emit(state) {
                var lines = ["lab '\(state.name)' started: pid \(state.pid), devtools http://127.0.0.1:\(state.port), profile \(state.profile)"]
                lines.append(state.extensionLoaded ? "amcu extension loaded (id \(ExtensionBundle.id))" : "extension NOT loaded: branded Chrome refuses --load-extension; use Chrome for Testing for extension work")
                if !state.headless { lines.append("a visible window opened — the lab is not background; tell the user if that matters") }
                return lines.joined(separator: "\n")
            }
        case "status":
            let found = name == "all" ? Lab.all() : [Lab.status(name: name)].compactMap { $0 }
            struct Row: Encodable { let name: String; let alive: Bool; let pid: Int32; let port: Int; let profile: String }
            let rows = found.map { Row(name: $0.state.name, alive: $0.alive, pid: $0.state.pid, port: $0.state.port, profile: $0.state.profile) }
            Output.emit(rows) {
                rows.isEmpty ? "no lab" : rows.map { "\($0.name): \($0.alive ? "running" : "not running") pid \($0.pid) port \($0.port) profile \($0.profile)" }.joined(separator: "\n")
            }
        case "targets":
            let state = try Lab.running(name: name)
            let list = try Lab.targets(port: state.port)
            let data = try JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys])
            if Output.json { print(String(decoding: data, as: UTF8.self)) } else {
                for target in list {
                    print("\(target["id"] as? String ?? "?")  \(target["type"] as? String ?? "?")  \(target["title"] as? String ?? "")  \(target["url"] as? String ?? "")")
                }
            }
        case "cdp":
            let state = try Lab.running(name: name)
            let method = try flags.required("method", hint: "Pass --method with a DevTools Protocol method, e.g. --method Runtime.evaluate.")
            var params: [String: Any] = [:]
            if let raw = flags.string("params") {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
                    throw AmcuError(.invalidArgument, "--params must be a JSON object", nextSteps: ["e.g. --params '{\"expression\":\"1+1\"}'"])
                }
                params = object
            }
            let result = try Lab.call(port: state.port, method: method, params: params, target: flags.string("target"), timeout: try flags.double("timeout") ?? 30)
            let data = try JSONSerialization.data(withJSONObject: result, options: Output.json ? [.sortedKeys] : [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        case "stop":
            guard let state = try Lab.stop(name: name, keepProfile: flags.has("keep-profile")) else {
                print("no lab '\(name)'"); return
            }
            Output.emit(state) { "lab '\(state.name)' stopped\(flags.has("keep-profile") ? " (profile kept at \(state.profile))" : ", profile removed")" }
        default:
            throw AmcuError(.invalidArgument, "unknown lab verb '\(verb)'", nextSteps: ["Run `amcu lab help`."])
        }
    }
}
