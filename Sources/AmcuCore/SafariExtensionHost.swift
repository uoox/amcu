import Foundation

/// The appex half of the Safari bridge. The container app's extension is a
/// copy of this binary: when it finds itself running from an `.appex`
/// bundle it hands control to Foundation's `NSExtensionMain` — the entry
/// point Xcode links app extensions against — which instantiates the
/// principal class below for every native message.
public enum SafariExtensionHost {
    public static var isRunningAsAppex: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    public static func main() -> Never {
        // Keep the principal class reachable so the linker cannot drop it.
        _ = AmcuSafariWebExtensionHandler.self
        typealias Entry = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "NSExtensionMain") else {
            FileHandle.standardError.write(Data("amcu: NSExtensionMain is unavailable on this system\n".utf8))
            exit(1)
        }
        let entry = unsafeBitCast(symbol, to: Entry.self)
        exit(entry(CommandLine.argc, CommandLine.unsafeArgv))
    }

    /// Forwards one message from the extension to the relay and returns the
    /// relay's answer. Failures come back as messages too, so the extension
    /// can tell "relay not running" from "Safari refused the message".
    static func forward(_ message: [String: Any], config: SafariBridge.RelayConfig?) -> [String: Any] {
        guard let config else {
            return ["type": "error", "code": "not_configured", "message": "the appex carries no relay address; reinstall with `amcu browser install --browser safari`"]
        }
        guard let fd = RelaySockets.connectLoopback(port: config.port, timeout: 2) else {
            return ["type": "error", "code": "relay_unavailable", "message": "the amcu relay is not running (it starts with the next `amcu browser … --browser safari` command)"]
        }
        defer { close(fd) }
        guard RelaySockets.writeLine(fd, ["token": config.token, "message": message]) else {
            return ["type": "error", "code": "relay_unavailable", "message": "could not write to the amcu relay"]
        }
        var buffer = Data()
        let wait = (message["type"] as? String) == "poll" ? SafariBridge.pollWindow + 5 : 15
        guard let line = RelaySockets.readLine(fd, buffer: &buffer, timeout: wait),
              let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return ["type": "error", "code": "relay_unavailable", "message": "the amcu relay closed the connection without answering (wrong token after a reinstall?)"]
        }
        return reply
    }
}

/// Principal class of the appex (`NSExtensionPrincipalClass`). Each
/// `browser.runtime.sendNativeMessage` from the extension becomes one
/// `beginRequest`; the reply goes back through `completeRequest`.
@objc(AmcuSafariWebExtensionHandler)
public final class AmcuSafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let config = SafariBridge.relayConfig(from: Bundle.main.infoDictionary ?? [:])
    // `SFExtensionMessageKey` / `SFExtensionProfileKey` are these literal
    // strings; spelling them out keeps SafariServices out of the binary.
    private static let messageKey = "message"
    private static let profileKey = "profile"

    public func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        var message = item?.userInfo?[Self.messageKey] as? [String: Any] ?? [:]
        if let profile = item?.userInfo?[Self.profileKey] as? UUID {
            message["profile"] = profile.uuidString
        } else if let profile = item?.userInfo?[Self.profileKey] as? String {
            message["profile"] = profile
        }
        // A poll blocks for up to the poll window; never on Safari's thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let reply = SafariExtensionHost.forward(message, config: Self.config)
            let response = NSExtensionItem()
            response.userInfo = [Self.messageKey: reply]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }
}
