import Foundation
import AmcuCore

/// The dotenv loader and the output masking behind `--secrets`.
func runSecretStoreTests(_ t: Harness) {
    t.suite("secret store")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("amcu-secret-tests-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    func write(_ name: String, _ contents: String) -> String {
        let url = dir.appendingPathComponent(name)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    do {
        let path = write("good.env", """
        # comment
        DB_PASSWORD=hunter2secret
        export API_KEY="sk-live-abcdef123456"
        QUOTED='single quoted value'
        SHORT=ab
        EMPTY=

        NOEQUALS LINE
        """)
        try SecretStore.load(path: path)
        t.expectEqual(SecretStore.values.count, 4, "loads KEY=VALUE lines; skips comments, empties and non-entries")
        t.expectEqual(try SecretStore.value(forKey: "DB_PASSWORD"), "hunter2secret", "plain value survives")
        t.expectEqual(try SecretStore.value(forKey: "API_KEY"), "sk-live-abcdef123456", "export prefix and double quotes are stripped")
        t.expectEqual(try SecretStore.value(forKey: "QUOTED"), "single quoted value", "single quotes are stripped")
        t.expect((try? SecretStore.value(forKey: "MISSING")) == nil, "an unknown key is an error, not an empty string")
    } catch {
        t.expect(false, "loading a valid secrets file must not throw (\(error))")
    }

    t.expectEqual(SecretStore.mask("password is hunter2secret."), "password is [secret:DB_PASSWORD].", "known values are masked with their key")
    t.expectEqual(
        SecretStore.mask("{\"auth\":\"sk-live-abcdef123456\"}"),
        "{\"auth\":\"[secret:API_KEY]\"}",
        "masking applies inside JSON output too"
    )
    t.expectEqual(SecretStore.mask("short ab stays"), "short ab stays", "values under 4 characters are never masked")
    t.expectEqual(SecretStore.mask("nothing secret here"), "nothing secret here", "text without secrets passes through unchanged")

    t.suite("secret store: JSON masking")
    do {
        let path = write("json.env", """
        PIN=123456
        TRICKY=pa"ss\\word
        WEIRD"KEY=plainvalue99
        """)
        try SecretStore.load(path: path)
        let escapedForm = SecretStore.maskJSON("{\"value\":\"pa\\\"ss\\\\word\"}")
        t.expectEqual(escapedForm, "{\"value\":\"[secret:TRICKY]\"}", "a secret with quote/backslash is caught in its JSON-escaped spelling")
        let bareNumber = SecretStore.maskJSON("{\"tab\": 123456}")
        t.expectEqual(bareNumber, "{\"tab\": \"[secret:PIN]\"}", "a numeric secret as a bare JSON number becomes a quoted token")
        t.expect((try? JSONSerialization.jsonObject(with: Data(bareNumber.utf8))) != nil, "the masked document is still valid JSON")
        t.expectEqual(SecretStore.maskJSON("{\"note\":\"code 123456 sent\"}"), "{\"note\":\"code [secret:PIN] sent\"}", "a numeric secret inside a string is masked in place")
        t.expectEqual(SecretStore.maskJSON("{\"id\": 91234567}"), "{\"id\": 91234567}", "a longer number containing the secret is left alone")
        t.expectEqual(SecretStore.maskJSON("{\"pin\":\"123456\"}"), "{\"pin\":\"[secret:PIN]\"}", "a numeric secret as a whole string value is masked")
        t.expectEqual(SecretStore.mask("value plainvalue99 here"), "value [secret:WEIRDKEY] here", "a token never carries characters that could break the output")
    } catch {
        t.expect(false, "loading the JSON-masking fixtures must not throw (\(error))")
    }

    t.expect((try? SecretStore.load(path: dir.appendingPathComponent("missing.env").path)) == nil, "a missing file is an error")
    let emptyPath = write("empty.env", "# only a comment\n")
    t.expect((try? SecretStore.load(path: emptyPath)) == nil, "a file with no entries is an error")
    t.expectEqual(try? SecretStore.value(forKey: "PIN"), "123456", "a failed load leaves the previous store intact")
}
