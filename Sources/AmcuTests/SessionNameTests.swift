import Foundation
import AmcuCore

func runSessionNameTests(_ t: Harness) {
    t.suite("session name")
    do {
        let host = ["AAA_SESSION": "s_35c8d0e9", "CLAUDE_CODE_SESSION_ID": "1995bd27-93da-402a-a0d8-de321c59d063"]

        let explicit = SessionName.resolve(explicit: "mine", environment: host)
        t.expectEqual(explicit.name, "mine", "--session wins over every environment value")
        t.expectEqual(explicit.source, "--session", "the source says the flag decided")

        let override = SessionName.resolve(explicit: nil, environment: host.merging(["AMCU_SESSION": "pinned"]) { a, _ in a })
        t.expectEqual(override.name, "pinned", "AMCU_SESSION wins over the host's session")

        let aaa = SessionName.resolve(explicit: nil, environment: host)
        t.expectEqual(aaa.name, "s_35c8d0e9", "AAA_SESSION wins over the Claude Code session id")
        t.expectEqual(aaa.source, "$AAA_SESSION", "the source names the variable")

        let claude = SessionName.resolve(explicit: nil, environment: ["CLAUDE_CODE_SESSION_ID": "1995bd27-93da-402a-a0d8-de321c59d063"])
        t.expectEqual(claude.name, "1995bd27-93da-402a-a0d8-de321c59d063", "a Claude Code session id is used as it is")

        let none = SessionName.resolve(explicit: nil, environment: [:])
        t.expectEqual(none.name, "default", "with no session anywhere the shared default remains")
        t.expectEqual(none.source, "fallback", "and the source says it is the fallback")

        let blank = SessionName.resolve(explicit: "", environment: ["AAA_SESSION": "   "])
        t.expectEqual(blank.name, "default", "empty flags and blank variables are skipped")

        t.expectEqual(SessionName.sanitize("a/b c"), "a_b_c", "path separators and spaces cannot reach the file name")
        t.expectEqual(SessionName.sanitize("x..y"), "x_y", "a parent-directory sequence cannot survive")
        t.expectEqual(SessionName.sanitize(String(repeating: "z", count: 200)).count, 80, "long values are bounded")
        t.expect((try? SessionStore.url(for: SessionName.sanitize("../../etc/passwd"))) != nil, "a sanitized hostile value is a valid session file name")
    }
}
