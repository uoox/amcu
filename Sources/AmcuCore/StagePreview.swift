import AppKit
import SwiftUI

/// The stage window drawn with made-up windows, held windows and activity,
/// captured to a PNG (`amcu stage preview`): for checking how it looks
/// without anyone's real windows in the picture. The window is shown on the
/// stage display, where the user cannot see it, for the moment it takes.
public enum StagePreview {
    public static func render(to url: URL, size: CGSize, dark: Bool, tabsOnLeft: Bool = false, selected: Int = 0) throws {
        guard let stage = Stage.display() else {
            throw AmcuError(.stageUnavailable, "the preview is drawn on the stage display, and no stage is running", nextSteps: ["`amcu stage start` starts an empty one."])
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = StageViewModel(tabsOnLeft: tabsOnLeft)
        let thumbnails = StageThumbnails()
        let now = Date()
        func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> FrameJSON { FrameJSON(CGRect(x: x, y: y, width: w, height: h)) }
        let windows = [
            StageWindow(windowID: 9001, pid: 9001, app: "Google Chrome", bundleID: "com.google.Chrome", title: "小红书 - 你的生活兴趣社区", frame: frame(3810, 1110, 1250, 1050), home: frame(1250, 30, 1250, 1050), origin: .put),
            StageWindow(windowID: 9002, pid: 9001, app: "Google Chrome", bundleID: "com.google.Chrome", title: "示例商品详情 - 闲鱼", frame: frame(3137, 1110, 1353, 1050), home: frame(577, 30, 1353, 1050), origin: .put),
            StageWindow(windowID: 9004, pid: 9004, app: "TextEdit", bundleID: "com.apple.TextEdit", title: "未命名", frame: frame(2700, 1200, 900, 700), home: nil, origin: .found)
        ]
        let held = [StageTakeover(windowID: 9003, pid: 9003, app: "计算器", bundleID: "com.apple.calculator", title: "计算器", since: now.addingTimeInterval(-180), stageFrame: frame(4151, 1394, 230, 408))]
        let status = StageStatus(
            version: AmcuVersion.string, hostPID: getpid(), displayID: stage.id, bounds: FrameJSON(stage.bounds), scale: 2,
            contact: .corner, since: now.addingTimeInterval(-3600), answersFor: "aaa-daemon", accessibility: true, screenRecording: true,
            cursorPullbacks: 2, windows: windows, takenOver: held, following: [], notes: []
        )
        model.setBrowser([
            9001: StageTabs.Paired(profile: "bunny", tabs: [
                StageTabs.Tab(id: 1, title: "小红书 - 你的生活兴趣社区", url: "https://www.xiaohongshu.com/explore", active: true, attached: true),
                StageTabs.Tab(id: 2, title: "创作服务平台", url: "https://creator.xiaohongshu.com/", active: false, attached: false)
            ]),
            9002: StageTabs.Paired(profile: "jtf", tabs: [
                StageTabs.Tab(id: 3, title: "示例商品详情 - 闲鱼", url: "https://www.goofish.com/item", active: true, attached: false)
            ])
        ])
        model.load([
            StageActivity(kind: .navigate, session: "xhs-comments", pid: 9001, windowID: 9001, detail: "xiaohongshu.com", at: now.addingTimeInterval(-41), seq: 1),
            StageActivity(kind: .type, session: "xhs-comments", pid: 9001, windowID: 9001, count: 12, at: now.addingTimeInterval(-9), seq: 2),
            StageActivity(kind: .click, session: "xhs-comments", pid: 9001, windowID: 9001, target: "button \"发送\"", fraction: StagePoint(x: 0.82, y: 0.88), at: now.addingTimeInterval(-1), seq: 3),
            StageActivity(kind: .scroll, session: "xhs-comments", pid: 9001, windowID: 9001, detail: "down", at: now.addingTimeInterval(-70), seq: 5),
            StageActivity(kind: .script, session: "xhs-comments", pid: 9001, windowID: 9001, at: now.addingTimeInterval(-95), seq: 6),
            StageActivity(kind: .key, session: "0b2c6f3e-8d1a-4c7e-9f00-123456789abc", pid: 9001, windowID: 9002, keys: "cmd+f", at: now.addingTimeInterval(-300), seq: 4)
        ])
        for (id, size, dark) in [(CGWindowID(9001), CGSize(width: 1250, height: 1050), false), (9002, CGSize(width: 1353, height: 1050), false), (9003, CGSize(width: 230, height: 408), true), (9004, CGSize(width: 900, height: 700), false)] {
            if let image = sample(size: size, dark: dark, seed: Int(id)) { thumbnails.still(image, for: id) }
        }

        let order = [CGWindowID(9001), 9002, 9004, 9003]
        model.restore(order: order, selected: order[min(max(0, selected), order.count - 1)])
        model.apply(status)
        let content = StageHostingView(rootView: StageView(model: model, thumbnails: thumbnails))
        let window = StageWindowController(content: content)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == stage.id }
        let origin = screen.map { NSPoint(x: $0.frame.minX + 40, y: $0.frame.maxY - 60 - size.height) } ?? .zero
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.orderFrontRegardless()
        model.adopt(window.chrome)
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        defer { window.orderOut(nil) }
        let captured = try Capture.capture(id: CGWindowID(window.windowNumber)).image
        try Capture.writePNG(captured, to: url)
    }

    /// A made-up window: a toolbar, a sidebar and some lines of content.
    private static func sample(size: CGSize, dark: Bool, seed: Int) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let base: CGFloat = dark ? 0.16 : 0.98
        context.setFillColor(CGColor(gray: base, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if dark {
            let keys = CGColor(gray: 0.32, alpha: 1), accent = CGColor(red: 1, green: 0.6, blue: 0.1, alpha: 1)
            for row in 0..<5 {
                for column in 0..<4 {
                    context.setFillColor(column == 3 ? accent : keys)
                    let side = size.width / 4 - 10
                    context.fillEllipse(in: CGRect(x: CGFloat(column) * size.width / 4 + 5, y: CGFloat(row) * (side + 8) + 8, width: side, height: side))
                }
            }
            return context.makeImage()
        }
        let hue = CGFloat(seed % 7) / 7
        let color = NSColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1).cgColor
        context.setFillColor(CGColor(gray: 0.93, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 80, width: width, height: 80))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width / 5, height: height - 80))
        context.setFillColor(CGColor(gray: 0.85, alpha: 1))
        for line in 0..<12 {
            let y = CGFloat(height - 130 - line * 70)
            context.fill(CGRect(x: CGFloat(width / 5 + 40), y: y, width: CGFloat(width) * (line % 3 == 0 ? 0.5 : 0.65), height: 24))
        }
        context.setFillColor(color.copy(alpha: 0.85) ?? color)
        context.fill(CGRect(x: CGFloat(width) * 0.72, y: 80, width: CGFloat(width) * 0.2, height: 60))
        return context.makeImage()
    }
}
