import CoreGraphics
import Foundation
import AmcuCore

/// Where the stage goes, how windows are carried onto it and back, and where
/// the cursor guard puts the pointer.
func runStageGeometryTests(_ t: Harness) {
    t.suite("stage geometry")

    let main = CGRect(x: 0, y: 0, width: 2560, height: 1080)
    t.expectEqual(StageGeometry.cornerOrigin(of: [main]), CGPoint(x: 2560, y: 1080), "the stage goes off the main display's bottom-right corner")
    let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    t.expectEqual(StageGeometry.cornerOrigin(of: [main, left]), CGPoint(x: 2560, y: 1080), "with several displays, off the corner of their bounding box")
    t.expectEqual(StageGeometry.cornerOrigin(of: []), CGPoint.zero, "no displays: the origin, rather than a crash")

    let corner = CGRect(x: 2560, y: 1080, width: 2560, height: 1080)
    let beside = CGRect(x: 2560, y: 0, width: 2560, height: 1080)
    let far = CGRect(x: 6000, y: 4000, width: 2560, height: 1080)
    t.expectEqual(StageGeometry.sharedBorder(corner, main), 0, "a corner contact shares no border")
    t.expectEqual(StageGeometry.sharedBorder(beside, main), 1080, "a display beside the main one shares its whole height")
    t.expectEqual(StageGeometry.contact(of: corner, with: [main]), .corner, "corner contact is reported as such")
    t.expectEqual(StageGeometry.contact(of: beside, with: [main]), .edge, "an edge contact is reported as such")
    t.expectEqual(StageGeometry.contact(of: far, with: [main]), .apart, "a display that touches nothing is apart")
    t.expectEqual(StageGeometry.contact(of: corner, with: [left, main]), .corner, "contact considers every user display")
    let below = CGRect(x: 1000, y: 1080, width: 2560, height: 1080)
    t.expectEqual(StageGeometry.contact(of: below, with: [main]), .edge, "a display below with horizontal overlap shares an edge")

    t.expectEqual(StageGeometry.nearestPoint(to: CGPoint(x: 2560.4, y: 1080.2), in: [main]), CGPoint(x: 2559, y: 1079), "a cursor that slipped through the corner goes back just inside it")
    t.expectEqual(StageGeometry.nearestPoint(to: CGPoint(x: 3000, y: 500), in: [main]), CGPoint(x: 2559, y: 500), "the pointer comes back level with where it was")
    t.expectEqual(StageGeometry.nearestPoint(to: CGPoint(x: -1950, y: 10), in: [main, left]), CGPoint(x: -1920, y: 10), "the nearest of several displays wins")
    t.expect(StageGeometry.nearestPoint(to: .zero, in: []) == nil, "no displays: nowhere to put the pointer")

    let stageArea = CGRect(x: 2560, y: 1110, width: 2560, height: 1050)
    let window = CGRect(x: 1591, y: 314, width: 230, height: 408)
    t.expectEqual(StageGeometry.carry(window, from: main, to: corner, within: stageArea), CGPoint(x: 4151, y: 1394), "a window keeps its offset from the display's top-left")
    let underMenuBar = CGRect(x: 100, y: 10, width: 400, height: 300)
    t.expectEqual(StageGeometry.carry(underMenuBar, from: main, to: corner, within: stageArea), CGPoint(x: 2660, y: 1110), "a window that would sit under the stage's menu bar is pulled below it")
    let wide = CGRect(x: 0, y: 40, width: 3000, height: 500)
    t.expectEqual(StageGeometry.carry(wide, from: main, to: corner, within: stageArea).x, 2560, "a window wider than the stage starts at its left edge")
    let nearRight = CGRect(x: 2400, y: 500, width: 600, height: 400)
    t.expectEqual(StageGeometry.carry(nearRight, from: main, to: corner, within: stageArea), CGPoint(x: 4520, y: 1580), "a window hanging off the right edge is pulled fully inside")

    t.expectEqual(StageGeometry.overlap(CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 50, y: 0, width: 100, height: 100)), 0.5, "overlap is the shared share of the frame")
    t.expectEqual(StageGeometry.overlap(CGRect(x: 0, y: 0, width: 100, height: 100), far), 0, "no overlap is zero")
    t.expectEqual(StageGeometry.overlap(.zero, main), 0, "an empty frame overlaps nothing")
    t.expect(StageGeometry.isOnStage(CGRect(x: 4151, y: 1394, width: 230, height: 408), stage: corner), "a window whose centre is on the stage is on it")
    t.expect(!StageGeometry.isOnStage(window, stage: corner), "a window on the main display is not")

    let cocoaStage = CGRect(x: 2560, y: -1080, width: 2560, height: 1050)
    t.expectEqual(StageGeometry.quartzRect(fromCocoa: cocoaStage, mainDisplayHeight: 1080), CGRect(x: 2560, y: 1110, width: 2560, height: 1050), "AppKit's visible frame converts to Quartz coordinates below the stage's menu bar")

    t.expectEqual(StageGeometry.parseSize("2560x1080"), CGSize(width: 2560, height: 1080), "WxH parses")
    t.expectEqual(StageGeometry.parseSize("1920×1080"), CGSize(width: 1920, height: 1080), "the multiplication sign parses too")
    t.expect(StageGeometry.parseSize("100x100") == nil, "too small is refused")
    t.expect(StageGeometry.parseSize("9000x1080") == nil, "too large is refused")
    t.expect(StageGeometry.parseSize("wide") == nil, "garbage is refused")

    let calculator = CGRect(x: 4151, y: 1394, width: 230, height: 408)
    t.expectEqual(StageGeometry.point(in: calculator, fraction: CGPoint(x: 0.5, y: 0.25)), CGPoint(x: 4266, y: 1496), "a click halfway across and a quarter down the thumbnail is that point of the window")
    t.expectEqual(StageGeometry.point(in: calculator, fraction: CGPoint(x: 1.2, y: -0.1)), CGPoint(x: 4381, y: 1394), "a click past the thumbnail's edge is held to the window")

    let tab = StageTabs.Tab(id: 1, title: "github.com/example/project/blob/main/docs/release-notes-2026-11.md", url: "", active: true, attached: false)
    t.expect(StageTabs.titled("github.com/example/proj…release-notes-2026-11.md", by: tab), "a browser window title shortened in the middle still matches its active tab")
    t.expect(StageTabs.titled("github.com/example/project/blob/main/docs/release-notes-2026-11.md - Google Chrome - Work", by: tab), "browser and profile after the title still match")
    t.expect(!StageTabs.titled("github.com/example/proj…other.md", by: tab), "a different tail does not match")
    t.expectEqual(StageTabs.host(of: "https://www.example.com/explore?x=1"), "example.com", "a tab's site drops www.")

    t.expectEqual(StageTabLayout.topWidth(count: 3, room: 1100), 240, "a few tabs on top keep their full width")
    t.expectEqual(StageTabLayout.topWidth(count: 8, room: 1100), 134, "more tabs share the strip evenly, gaps included")
    t.expectEqual(StageTabLayout.topWidth(count: 30, room: 1100), 96, "a crowded strip stops shrinking at the minimum")
    t.expect(!StageTabLayout.topScrolls(count: 8, room: 1100), "tabs that fit do not scroll")
    t.expect(StageTabLayout.topScrolls(count: 30, room: 1100), "tabs at the minimum that still do not fit scroll")
    t.expectEqual(StageTabLayout.tabTop(lightsCenter: 19, fullScreen: false), 6, "tabs are centred on the traffic lights")
    t.expectEqual(StageTabLayout.stripHeight(lightsCenter: 19, fullScreen: false), 38, "with as much room below as above")
    t.expectEqual(StageTabLayout.tabTop(lightsCenter: 10, fullScreen: false), 4, "lights high up still leave the tabs a margin")
    t.expectEqual(StageTabLayout.stripHeight(lightsCenter: 19, fullScreen: true), 36, "full screen has no lights to line up with")

    t.expectEqual(StageTabOrder.merged([], present: [5, 3, 9]), [5, 3, 9], "the first tabs come in the order the stage lists them")
    t.expectEqual(StageTabOrder.merged([3, 5, 9], present: [9, 7, 5, 3]), [3, 5, 9, 7], "tabs keep their place and a new window opens a tab at the end")
    t.expectEqual(StageTabOrder.merged([3, 5, 9], present: [9, 3]), [3, 9], "a window that left closes its tab")
    t.expectEqual(StageTabOrder.selection(5, previous: [3, 5, 9], now: [3, 5, 9]), 5, "the selected tab stays selected")
    t.expectEqual(StageTabOrder.selection(5, previous: [3, 5, 9], now: [3, 9]), 9, "when the selected tab closes, the one after it is selected")
    t.expectEqual(StageTabOrder.selection(9, previous: [3, 5, 9], now: [3, 5]), 5, "or the one before it when it was the last")
    t.expectEqual(StageTabOrder.selection(nil, previous: [], now: [4, 2]), 4, "with nothing selected, the first tab is")
    t.expect(StageTabOrder.selection(4, previous: [4], now: []) == nil, "an empty stage selects nothing")

    func browser(_ id: Int, _ active: String) -> StageTabs.BrowserWindow {
        StageTabs.BrowserWindow(id: id, tabs: [StageTabs.Tab(id: id * 10, title: active, url: "", active: true, attached: false)])
    }
    t.expectEqual(StageTabs.pair([(7, "Mail"), (8, "Example Domain")], with: [browser(5, "Example Domain"), browser(3, "Mail")]), [7: 1, 8: 0], "distinct titles pair directly")
    t.expectEqual(StageTabs.pair([(641, "Example Domain"), (640, "Example Domain")], with: [browser(9002, "Example Domain"), browser(9001, "Example Domain")]), [640: 1, 641: 0], "twins (two profiles on one site) pair in creation order on both sides")
    t.expectEqual(StageTabs.pair([(641, "Example Domain")], with: [browser(9002, "Example Domain"), browser(9001, "Example Domain")]), [:], "one window and two candidates is not guessed")
    t.expectEqual(StageTabs.pair([(9, "")], with: [browser(1, "")]), [:], "an untitled window pairs with nothing")

    let staged = CGRect(x: 4151, y: 1394, width: 230, height: 408)
    let mainArea = CGRect(x: 0, y: 30, width: 2500, height: 1050)
    t.expectEqual(StageGeometry.alignedOrigin(window: staged, grabbed: CGPoint(x: 4251, y: 1594), cursor: CGPoint(x: 1300, y: 600), within: mainArea), CGPoint(x: 1200, y: 400), "the clicked spot of the window lands under the cursor")
    t.expectEqual(StageGeometry.alignedOrigin(window: staged, grabbed: CGPoint(x: 4251, y: 1594), cursor: CGPoint(x: 1300, y: 40), within: mainArea), CGPoint(x: 1200, y: 30), "a window that would go under the menu bar is pulled below it")
    t.expectEqual(StageGeometry.alignedOrigin(window: staged, grabbed: CGPoint(x: 4152, y: 1395), cursor: CGPoint(x: 2490, y: 600), within: mainArea), CGPoint(x: 2270, y: 599), "a window that would cross the Dock is pulled clear of it")

    let identity = Stage.identity
    t.expectEqual(identity.vendorID, 0x616D, "the stage's vendor number spells 'am'")
    t.expectEqual(identity.productID, 0x6375, "and its product number 'cu', so any process can recognise it")
}
