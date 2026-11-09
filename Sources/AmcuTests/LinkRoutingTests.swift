import CoreGraphics
import Foundation
import AmcuCore

func runLinkRoutingTests(_ t: Harness) {
    t.suite("links the user opens")

    let stage = CGRect(x: 2560, y: 1080, width: 2560, height: 1080)
    let area = CGRect(x: 0, y: 30, width: 2560, height: 1050)
    let staged = CGRect(x: 3000, y: 1200, width: 1200, height: 900)
    func window(_ id: Int, _ at: Double, _ frame: CGRect, minimized: Bool = false) -> LinkRouting.Candidate {
        LinkRouting.Candidate(windowID: id, focusedAt: at, frame: frame, minimized: minimized)
    }
    let mine = window(11, 100, CGRect(x: 0, y: 30, width: 1200, height: 900))
    let otherStaged = window(12, 300, CGRect(x: 3100, y: 1300, width: 1000, height: 800))
    let hidden = window(13, 400, CGRect(x: 200, y: 200, width: 1000, height: 800), minimized: true)

    t.expectEqual(LinkRouting.decide(window: CGRect(x: 100, y: 100, width: 900, height: 700), stage: stage, own: [mine], others: [], area: area), .stay, "a link that opened on the user's screen stays")
    t.expectEqual(LinkRouting.decide(window: staged, stage: nil, own: [mine], others: [], area: area), .stay, "without a stage nothing moves")
    t.expectEqual(LinkRouting.decide(window: staged, stage: stage, own: [mine, otherStaged, hidden], others: [], area: area), .own(windowID: 11), "it goes to the profile's window the user focused last, not one on the stage or minimised")
    t.expectEqual(LinkRouting.decide(window: staged, stage: stage, own: [mine], others: [[window(21, 200, CGRect(x: 100, y: 100, width: 1000, height: 800))]], area: area), .other(peer: 0, windowID: 21), "another profile's window focused more recently wins")
    t.expectEqual(LinkRouting.decide(window: staged, stage: stage, own: [mine], others: [[window(21, 50, CGRect(x: 100, y: 100, width: 1000, height: 800))]], area: area), .own(windowID: 11), "an older focus elsewhere does not")
    t.expectEqual(LinkRouting.decide(window: staged, stage: stage, own: [], others: [[window(21, 0, CGRect(x: 100, y: 100, width: 1000, height: 800))]], area: area), .newWindow(CGRect(x: 512, y: 109, width: 1536, height: 893)), "a profile never seen focused is not guessed at; a new window opens on the user's screen")
    t.expectEqual(LinkRouting.decide(window: staged, stage: stage, own: [otherStaged], others: [[window(31, 900, CGRect(x: 3200, y: 1200, width: 900, height: 700))]], area: area), .newWindow(CGRect(x: 512, y: 109, width: 1536, height: 893)), "windows on the stage are never a destination")
    t.expectEqual(LinkRouting.decide(window: staged, stage: stage, own: [window(41, 0, CGRect(x: 0, y: 30, width: 900, height: 700)), window(42, 0, CGRect(x: 50, y: 60, width: 900, height: 700))], others: [], area: area), .own(windowID: 42), "with no focus known, the newest window of the same profile")
    t.expectEqual(LinkRouting.newWindowFrame(in: CGRect(x: 0, y: 25, width: 1440, height: 875)), CGRect(x: 220, y: 91, width: 1000, height: 744), "a small screen still gets a usable window")
}
