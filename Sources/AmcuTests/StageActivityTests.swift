import CoreGraphics
import Foundation
import AmcuCore

/// What the stage window says an agent did, and what an older host's status
/// still decodes to.
func runStageActivityTests(_ t: Harness) {
    t.suite("stage activity")

    let click = StageActivity(kind: .click, session: "xhs-comments", pid: 1, windowID: 7, target: "发布")
    t.expectEqual(click.summary(chinese: true), "点击「发布」", "a click names what it pressed")
    t.expectEqual(click.summary(chinese: false), "Clicked “发布”", "in English too")
    t.expectEqual(StageActivity(kind: .click, session: "s", pid: 1).summary(chinese: true), "点击", "a click on nothing named says just that")
    t.expectEqual(StageActivity(kind: .click, session: "s", pid: 1, target: "button \"发送\"").summary(chinese: true), "点击「发送」", "a page element is named by its text, not its role")
    t.expectEqual(StageActivity(kind: .click, session: "s", pid: 1, target: "link \"\"").summary(chinese: true), "点击「link」", "with no text, by its role")

    let typed = StageActivity(kind: .type, session: "s", pid: 1, count: 12)
    t.expectEqual(typed.summary(chinese: true), "输入 12 个字", "typing says how much, never what")
    t.expectEqual(StageActivity(kind: .type, session: "s", pid: 1, count: 1).summary(chinese: false), "Typed 1 character", "one character is singular")
    t.expectEqual(StageActivity(kind: .fill, session: "s", pid: 1, target: "密码").summary(chinese: true), "在「密码」填入内容", "a fill from a secret has no count to give")
    t.expectEqual(StageActivity(kind: .setValue, session: "s", pid: 1, target: "Name", count: 3).summary(chinese: false), "Filled in 3 characters in “Name”", "a set value names its field")

    t.expectEqual(StageActivity(kind: .key, session: "s", pid: 1, keys: "cmd+shift+v").summary(chinese: true), "按 ⌘⇧V", "keys read as the keyboard shows them")
    t.expectEqual(StageActivity.keyLabel("return"), "↩", "return is an arrow")
    t.expectEqual(StageActivity.keyLabel("ctrl+tab"), "⌃⇥", "modifiers and named keys combine")
    t.expectEqual(StageActivity(kind: .scroll, session: "s", pid: 1, detail: "down").summary(chinese: true), "向下滚动", "scrolling says which way")
    t.expectEqual(StageActivity(kind: .window, session: "s", pid: 1, detail: "move,resize").summary(chinese: true), "窗口移动、改大小", "window changes list what changed")
    t.expectEqual(StageActivity(kind: .navigate, session: "s", pid: 1, detail: "xiaohongshu.com").summary(chinese: true), "打开 xiaohongshu.com", "navigation names only the site")
    t.expectEqual(StageActivity(kind: .handBack, session: "s", pid: 1).summary(chinese: true), "把你接管的窗口收回舞台", "taking a held window back is said plainly")

    let long = StageActivity(kind: .click, session: "s", pid: 1, target: String(repeating: "很长的按钮名字", count: 10))
    t.expect(long.summary(chinese: true).count <= 24 + 4, "a long name is shortened for the card")
    t.expect((long.target ?? "").count <= 60, "and kept short on the wire")
    t.expectEqual(StageActivity(kind: .click, session: "s", pid: 1, target: "a\nb").target, "a b", "line breaks in a name flatten")

    var polled = StageActivity(kind: .script, session: "xhs-BunnyGleam", pid: 1, windowID: 3)
    t.expect(polled.repeated(by: StageActivity(kind: .script, session: "xhs-BunnyGleam", pid: 1, windowID: 3)), "the same script again is a repeat")
    t.expect(!polled.repeated(by: StageActivity(kind: .script, session: "xhs-CherisJewelry", pid: 1, windowID: 3)), "another session's is not")
    t.expect(!polled.repeated(by: StageActivity(kind: .type, session: "s", pid: 1, windowID: 3, count: 4)), "nor is another kind")
    polled.repeats = 12
    t.expectEqual(polled.summary(chinese: true), "运行脚本 ×12", "repeats are counted on one line")
    t.expectEqual(StageActivity.sessionLabel("0b2c6f3e-8d1a-4c7e-9f00-123456789abc"), "0b2c6f3e", "a session id shows its first block")
    t.expectEqual(StageActivity.sessionLabel("xhs-comments"), "xhs-comments", "a session name shows whole")
    t.expectEqual(StageActivity.sessionLabel(String(repeating: "x", count: 40)).count, 24, "a long session name is shortened")

    let frame = CGRect(x: 2560, y: 1110, width: 1250, height: 1000)
    t.expectEqual(StagePoint(CGPoint(x: 3185, y: 1610), in: frame), StagePoint(x: 0.5, y: 0.5), "a point in a window becomes its fraction")
    t.expect(StagePoint(CGPoint(x: 100, y: 100), in: frame) == nil, "a point outside the window has none")
    t.expectEqual(StagePoint(CGPoint(x: 2560, y: 1110), in: frame), StagePoint(x: 0, y: 0), "the top-left corner is zero")

    t.suite("stage status from an older host")
    let older = """
    {"version":"0.12.1","hostPID":99591,"displayID":41,"bounds":{"x":2560,"y":1080,"width":2560,"height":1080},"scale":2,"contact":"corner","since":"2026-11-08T15:39:56Z","answersFor":"aaa-daemon","accessibility":true,"screenRecording":true,"cursorPullbacks":2,"windows":[],"takenOver":[],"following":[],"notes":[]}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let status = try? decoder.decode(StageStatus.self, from: Data(older.utf8)) {
        t.expect(status.activity.isEmpty, "no activity from a host that did not report any")
        t.expect(status.holderPID == nil, "no holder: that host keeps its display itself")
    } else {
        t.expect(false, "a 0.12.1 status decodes")
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let entry = StageActivity(kind: .key, session: "s", pid: 3, windowID: 9, keys: "cmd+v", fraction: StagePoint(x: 0.25, y: 0.75), at: Date(timeIntervalSince1970: 1_800_000_000), seq: 4)
    let round = (try? encoder.encode(entry)).flatMap { try? decoder.decode(StageActivity.self, from: $0) }
    t.expectEqual(round, entry, "an activity survives the wire")
}
