import CoreGraphics
import Foundation

/// The arithmetic behind the stage, free of system calls so it can be tested.
/// All rectangles are in global Quartz coordinates (origin at the top-left of
/// the main display, y down), the space window frames and display bounds use.
public enum StageGeometry {
    /// How the stage meets the user's displays.
    public enum Contact: String, Codable, Sendable {
        /// Not touching any display — macOS does not allow it (measured: an
        /// origin far away is pulled back next to the main display).
        case apart
        /// One shared point: no edge for the cursor to slide across.
        case corner
        /// A shared border: the cursor guard is the only thing keeping the
        /// pointer out, and a left- or right-hand Dock may move onto the stage.
        case edge
    }

    /// Diagonally off the bottom-right corner of the user's displays, so the
    /// stage touches them at one point at most. Measured on 27.2 with the
    /// Dock on the right: a stage against the main display's right edge took
    /// the Dock; one at the corner left it where it was.
    public static func cornerOrigin(of userDisplays: [CGRect]) -> CGPoint {
        let box = userDisplays.reduce(CGRect.null) { $0.union($1) }
        guard !box.isNull else { return .zero }
        return CGPoint(x: box.maxX, y: box.maxY)
    }

    /// Length of the border two rectangles share: zero when they meet at a
    /// corner or not at all.
    public static func sharedBorder(_ a: CGRect, _ b: CGRect) -> CGFloat {
        var length: CGFloat = 0
        if a.maxX == b.minX || b.maxX == a.minX {
            length = max(length, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        }
        if a.maxY == b.minY || b.maxY == a.minY {
            length = max(length, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        }
        return max(0, length)
    }

    static func meetAtCorner(_ a: CGRect, _ b: CGRect) -> Bool {
        (a.maxX == b.minX || b.maxX == a.minX) && (a.maxY == b.minY || b.maxY == a.minY)
    }

    public static func contact(of stage: CGRect, with userDisplays: [CGRect]) -> Contact {
        var corner = false
        for display in userDisplays {
            if sharedBorder(stage, display) > 0 { return .edge }
            if meetAtCorner(stage, display) { corner = true }
        }
        return corner ? .corner : .apart
    }

    /// The point inside the user's displays nearest to `point` — where the
    /// cursor guard puts the pointer back when it reached the stage.
    public static func nearestPoint(to point: CGPoint, in rects: [CGRect]) -> CGPoint? {
        rects.filter { $0.width >= 1 && $0.height >= 1 }.map { rect in
            CGPoint(x: min(max(point.x, rect.minX), rect.maxX - 1), y: min(max(point.y, rect.minY), rect.maxY - 1))
        }.min { distance($0, point) < distance($1, point) }
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// Where a window lands when it changes display: it keeps its offset from
    /// the top-left of the display it leaves, then is pulled inside the usable
    /// area (below the menu bar, clear of the Dock) of the one it joins.
    public static func carry(_ frame: CGRect, from source: CGRect, to destination: CGRect, within area: CGRect) -> CGPoint {
        let moved = CGRect(
            x: destination.minX + (frame.minX - source.minX),
            y: destination.minY + (frame.minY - source.minY),
            width: frame.width,
            height: frame.height
        )
        return clamp(moved, into: area)
    }

    /// The origin that keeps `frame` inside `area`, or at its top-left when it
    /// is too large to fit.
    public static func clamp(_ frame: CGRect, into area: CGRect) -> CGPoint {
        let x = frame.width >= area.width ? area.minX : min(max(frame.minX, area.minX), area.maxX - frame.width)
        let y = frame.height >= area.height ? area.minY : min(max(frame.minY, area.minY), area.maxY - frame.height)
        return CGPoint(x: x, y: y)
    }

    /// The share of `frame` that lies inside `area`, from 0 to 1.
    public static func overlap(_ frame: CGRect, _ area: CGRect) -> CGFloat {
        guard frame.width > 0, frame.height > 0 else { return 0 }
        let common = frame.intersection(area)
        guard !common.isNull else { return 0 }
        return (common.width * common.height) / (frame.width * frame.height)
    }

    /// The stage point under a click in the panel's live view, which shows
    /// the whole stage aspect-fitted into a view of `viewSize` (AppKit view
    /// coordinates, y up). Nil outside the picture.
    public static func stagePoint(fromPreview point: CGPoint, viewSize: CGSize, stage: CGRect) -> CGPoint? {
        guard viewSize.width > 0, viewSize.height > 0, stage.width > 0, stage.height > 0 else { return nil }
        let scale = min(viewSize.width / stage.width, viewSize.height / stage.height)
        let shown = CGSize(width: stage.width * scale, height: stage.height * scale)
        let inset = CGPoint(x: (viewSize.width - shown.width) / 2, y: (viewSize.height - shown.height) / 2)
        let x = (point.x - inset.x) / scale
        let fromTop = (inset.y + shown.height - point.y) / scale
        guard x >= 0, x < stage.width, fromTop >= 0, fromTop < stage.height else { return nil }
        return CGPoint(x: stage.minX + x, y: stage.minY + fromTop)
    }

    /// Where a window taken over from the live view lands: the point the user
    /// clicked comes to rest under the cursor, then the window is pulled inside
    /// the usable area (and stops lining up exactly when it had to be).
    public static func alignedOrigin(window: CGRect, grabbed: CGPoint, cursor: CGPoint, within area: CGRect) -> CGPoint {
        let origin = CGPoint(x: cursor.x - (grabbed.x - window.minX), y: cursor.y - (grabbed.y - window.minY))
        return clamp(CGRect(origin: origin, size: window.size), into: area)
    }

    /// A window counts as on the stage when its centre is.
    public static func isOnStage(_ frame: CGRect, stage: CGRect) -> Bool {
        stage.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// AppKit's screen rectangles have their origin at the bottom-left of the
    /// main display, y up; Quartz's at the top-left, y down.
    public static func quartzRect(fromCocoa rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// "2560x1080" (or 2560×1080) in points. Bounds keep the request within
    /// what a virtual display mode accepts and what is worth compositing.
    public static func parseSize(_ raw: String) -> CGSize? {
        let parts = raw.lowercased().replacingOccurrences(of: "×", with: "x").split(separator: "x").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
              (640...8192).contains(width), (480...8192).contains(height) else { return nil }
        return CGSize(width: width, height: height)
    }
}
