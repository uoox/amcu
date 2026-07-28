import CoreGraphics
import Foundation
import UmbraCore

/// A self-contained test runner.
///
/// XCTest and swift-testing both need a full Xcode installation to *run*, and
/// umbra's whole premise is that it works on a plain macOS box with the Command
/// Line Tools. Tests that only a subset of users can execute are tests that rot,
/// so the harness is thirty lines of local code and `swift run umbra-tests`
/// works anywhere the tool itself builds.
final class Harness {
    private var failures: [String] = []
    private var passed = 0
    private var suite = ""

    func suite(_ name: String) {
        suite = name
        print("\n\(name)")
    }

    func expect(_ condition: Bool, _ description: String) {
        if condition {
            passed += 1
            print("  ok   \(description)")
        } else {
            failures.append("\(suite): \(description)")
            print("  FAIL \(description)")
        }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ description: String) {
        if actual == expected {
            passed += 1
            print("  ok   \(description)")
        } else {
            failures.append("\(suite): \(description) — expected \(expected), got \(actual)")
            print("  FAIL \(description) — expected \(expected), got \(actual)")
        }
    }

    func expectThrows(_ description: String, _ body: () throws -> Void) {
        do {
            try body()
            failures.append("\(suite): \(description) — expected a thrown error")
            print("  FAIL \(description) — expected a thrown error")
        } catch {
            passed += 1
            print("  ok   \(description)")
        }
    }

    func finish() -> Never {
        print("\n\(passed) passed, \(failures.count) failed")
        for failure in failures { print("  - \(failure)") }
        exit(failures.isEmpty ? 0 : 1)
    }
}

let t = Harness()

// MARK: - Coordinate conversion

t.suite("coordinate conversion")

do {
    let frame = CGRect(x: 100, y: 648, width: 400, height: 332)
    let local = PointerInput.windowLocal(global: CGPoint(x: 300, y: 830), windowFrame: frame)
    t.expectEqual(local.x, 200, "a global point converts to a window-local x")
    t.expectEqual(local.y, 182, "a global point converts to a window-local y")

    let origin = CGRect(x: 40, y: 60, width: 200, height: 200)
    t.expectEqual(PointerInput.windowLocal(global: CGPoint(x: 40, y: 60), windowFrame: origin), .zero, "the window origin maps to the local origin")

    // A display left of or above the primary one has a negative origin.
    let secondary = CGRect(x: -1920, y: -200, width: 800, height: 600)
    let offscreen = PointerInput.windowLocal(global: CGPoint(x: -1900, y: -150), windowFrame: secondary)
    t.expectEqual(offscreen.x, 20, "negative display origins convert correctly in x")
    t.expectEqual(offscreen.y, 50, "negative display origins convert correctly in y")
}

// MARK: - Key codes

t.suite("key codes")

t.expect(KeyCodes.code(for: "Return") == KeyCodes.code(for: "return"), "key names are case insensitive")
t.expectEqual(KeyCodes.code(for: "ESC"), 53, "escape resolves to its virtual key code")
t.expect(KeyCodes.code(for: "nope") == nil, "an unknown key resolves to nil rather than a wrong key")
t.expect(KeyCodes.modifier(for: "cmd") == KeyCodes.modifier(for: "command"), "cmd and command are the same modifier")
t.expect(KeyCodes.modifier(for: "opt") == KeyCodes.modifier(for: "option"), "opt and option are the same modifier")
t.expect(KeyCodes.modifier(for: "hyper") == nil, "an unknown modifier resolves to nil")

// MARK: - Text chunking

t.suite("text chunking")

t.expectEqual(TextChunker.split("hello", by: 16), ["hello"], "a short string is sent as one event")
do {
    let text = String(repeating: "abcde", count: 20)
    let chunks = TextChunker.split(text, by: 16)
    t.expect(chunks.count > 1, "a long string is split across events")
    t.expectEqual(chunks.joined(), text, "chunking preserves the full string")

    let cjk = "世界你好世界你好世界你好世界你好世界你好"
    t.expectEqual(TextChunker.split(cjk, by: 4).joined(), cjk, "chunking splits on characters, not bytes")
}

// MARK: - Snapshots and sessions

t.suite("snapshots and sessions")

func makeNode(index: Int, role: String, label: String?, path: [Int], depth: Int = 0) -> SnapshotNode {
    SnapshotNode(
        index: index,
        role: role,
        subrole: nil,
        label: label,
        value: nil,
        enabled: true,
        focused: false,
        frame: FrameJSON(CGRect(x: 0, y: 0, width: 10, height: 10)),
        actions: ["AXPress"],
        depth: depth,
        path: path
    )
}

func makeSnapshot(nodes: [SnapshotNode], truncated: Bool = false) -> Snapshot {
    Snapshot(
        app: AppInfo(pid: 1, name: "Test", bundleID: "com.example.test", active: false, hasWindows: true),
        window: WindowInfo(
            windowID: 42,
            index: 0,
            title: "Window",
            frame: FrameJSON(CGRect(x: 0, y: 0, width: 100, height: 100)),
            minimized: false,
            main: true
        ),
        nodes: nodes,
        focusedIndex: nil,
        truncated: truncated,
        maxDepthReached: false,
        capturedAt: Date(timeIntervalSince1970: 0)
    )
}

do {
    let text = makeSnapshot(nodes: [
        makeNode(index: 0, role: "AXWindow", label: "Window", path: []),
        makeNode(index: 1, role: "AXButton", label: "Save", path: [0], depth: 1)
    ]).renderText()
    t.expect(text.contains("1 Button"), "rendered text carries each element's index and role")
    t.expect(text.contains("\"Save\""), "rendered text carries each element's label")
    // The AX prefix is stripped to keep the tree cheap to read.
    t.expect(!text.contains("AXButton"), "the AX role prefix is stripped")

    t.expect(makeSnapshot(nodes: []).renderText().contains("no element currently focused"), "focus state is stated explicitly when nothing is focused")
    // Silent truncation would read as "this is the whole interface".
    t.expect(makeSnapshot(nodes: [], truncated: true).renderText().contains("truncated"), "truncation is announced rather than silent")
}

do {
    let name = "selftest-\(UUID().uuidString.prefix(8))"
    do {
        try SessionStore.save(makeSnapshot(nodes: [makeNode(index: 0, role: "AXWindow", label: "Window", path: [])]), session: name)
        let (loaded, first) = try SessionStore.node(index: 0, session: name)
        t.expectEqual(loaded.window.windowID, 42, "a snapshot round-trips through the session store")
        t.expectEqual(first.role, "AXWindow", "recorded nodes survive the round trip")
        try? FileManager.default.removeItem(at: SessionStore.url(for: name))
    } catch {
        t.expect(false, "session round trip threw: \(error)")
    }
}

do {
    let name = "selftest-\(UUID().uuidString.prefix(8))"
    try? SessionStore.save(makeSnapshot(nodes: []), session: name)
    do {
        _ = try SessionStore.node(index: 7, session: name)
        t.expect(false, "an out-of-range index is refused")
    } catch let error as UmbraError {
        t.expectEqual(error.code, .elementNotFound, "an out-of-range index is refused with a specific code")
        t.expect(!error.nextSteps.isEmpty, "an out-of-range index comes with guidance")
    } catch {
        t.expect(false, "an out-of-range index threw the wrong error type")
    }
    try? FileManager.default.removeItem(at: SessionStore.url(for: name))
}

do {
    // Snapshots written before AXIdentifier was recorded must still load, or an
    // upgrade would strand every session cached on disk.
    let legacy = """
    {"app":{"pid":1,"name":"Test","active":false,"hasWindows":true},
     "window":{"index":0,"frame":{"x":0,"y":0,"width":100,"height":100},"minimized":false,"main":true},
     "nodes":[{"index":0,"role":"AXWindow","enabled":true,"focused":false,"actions":[],"depth":0,"path":[]}],
     "truncated":false,"maxDepthReached":false,"capturedAt":"1970-01-01T00:00:00Z"}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
        let decoded = try decoder.decode(Snapshot.self, from: Data(legacy.utf8))
        t.expectEqual(decoded.nodes.count, 1, "a snapshot without an identifier field still decodes")
        t.expect(decoded.nodes[0].identifier == nil, "a missing identifier decodes as nil rather than failing")
    } catch {
        t.expect(false, "legacy snapshot failed to decode: \(error)")
    }
}

t.expectThrows("a session name cannot escape the cache directory") { _ = try SessionStore.url(for: "../../etc/passwd") }
t.expectThrows("an empty session name is refused") { _ = try SessionStore.url(for: "") }

// MARK: - Errors

t.suite("errors")

do {
    let error = UmbraError.appNotFound("Finder")
    t.expectEqual(error.code, .appNotFound, "a missing application reports app_not_found")
    // The guidance exists so an agent stops retrying the same failing call.
    t.expect(error.nextSteps.contains { $0.contains("Do not retry") }, "a missing application tells the caller not to retry unchanged")
    t.expect(UmbraError(.timeout, "took too long").description.hasPrefix("timeout:"), "descriptions lead with the machine-readable code")
}

// MARK: - Self-check verdicts

t.suite("self-check verdicts")

for verdict in [SelfCheckResult.Verdict.mislocated, .undelivered, .unavailable] {
    let result = SelfCheckResult(
        verdict: verdict,
        symbolPresent: verdict != .unavailable,
        expected: nil,
        measured: nil,
        osBuild: "test",
        checkedAt: Date()
    )
    t.expect(!result.usable, "'\(verdict.rawValue)' is not treated as usable")
    t.expect(!result.summary.isEmpty, "'\(verdict.rawValue)' explains itself")
}

do {
    let accurate = SelfCheckResult(
        verdict: .accurate,
        symbolPresent: true,
        expected: PointJSON(CGPoint(x: 20, y: 15)),
        measured: PointJSON(CGPoint(x: 20, y: 15)),
        osBuild: "test",
        checkedAt: Date()
    )
    t.expect(accurate.usable, "an accurate verdict is usable")

    let mislocated = SelfCheckResult(
        verdict: .mislocated,
        symbolPresent: true,
        expected: PointJSON(CGPoint(x: 20, y: 15)),
        measured: PointJSON(CGPoint(x: 0, y: 60)),
        osBuild: "test",
        checkedAt: Date()
    )
    t.expect(mislocated.summary.contains("(20,15)"), "a mislocated verdict reports where the click aimed")
    t.expect(mislocated.summary.contains("(0,60)"), "a mislocated verdict reports where the click landed")
    t.expect(!SelfCheck.osBuild.isEmpty, "the OS build is recorded so a cached verdict expires with the system")
}

t.finish()
