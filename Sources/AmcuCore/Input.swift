import CoreGraphics
import Foundation

public enum DeliveryMode: String, Codable, Sendable, CaseIterable {
    /// Route the event to the target process and, for pointer events, to a
    /// specific window. The real cursor never moves and focus is never taken.
    case background
    /// Post to the global HID tap. The cursor moves and whatever is frontmost
    /// receives the event. Only correct when the target is already frontmost.
    case foreground
}

/// Window-routed pointer events.
///
/// Two things must be true for a pointer event posted with `postToPid` to land
/// on the right pixel of a non-frontmost window:
///
///  1. the window id must be written to the two `kCGMouseEventWindowUnderMousePointer`
///     fields (51 and 52), otherwise the event is not associated with a window at all; and
///  2. the window-local location must be set through `CGEventSetWindowLocation`,
///     otherwise WindowServer keeps the window association but collapses the
///     location to the window's top-left corner.
///
/// Setting only the fields is the failure mode that leads people to conclude
/// positioned background clicks are impossible on modern macOS: the click is
/// delivered, but always at (0, 0) of the window. Both halves together deliver
/// an accurate click. `CGEventSetWindowLocation` is not public API, so
/// `SelfCheck` verifies the whole path at runtime before anything relies on it.
public enum PointerInput {
    static let kMouseEventWindowUnderMousePointer = CGEventField(rawValue: 51)!
    static let kMouseEventWindowUnderMousePointerThatCanHandleThisEvent = CGEventField(rawValue: 52)!

    typealias SetWindowLocationFn = @convention(c) (CGEvent, CGPoint) -> Void

    static let setWindowLocation: SetWindowLocationFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: SetWindowLocationFn.self)
    }()

    public static var supportsWindowRouting: Bool { setWindowLocation != nil }

    /// Window-local point (top-left origin) for a global Quartz point.
    public static func windowLocal(global: CGPoint, windowFrame: CGRect) -> CGPoint {
        CGPoint(x: global.x - windowFrame.minX, y: global.y - windowFrame.minY)
    }

    static func makeMouseEvent(
        type: CGEventType,
        global: CGPoint,
        button: CGMouseButton,
        clickState: Int64,
        routing: (windowID: CGWindowID, local: CGPoint)?
    ) throws -> CGEvent {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: global, mouseButton: button) else {
            throw AmcuError(.unsupported, "could not construct mouse event", nextSteps: ["Retry; if this persists the process may lack Accessibility rights."])
        }
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        if let routing {
            event.setIntegerValueField(kMouseEventWindowUnderMousePointer, value: Int64(routing.windowID))
            event.setIntegerValueField(kMouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(routing.windowID))
            setWindowLocation?(event, routing.local)
        }
        return event
    }

    public struct ClickRequest {
        public var pid: pid_t
        public var windowID: CGWindowID?
        public var windowFrame: CGRect?
        public var global: CGPoint
        public var button: CGMouseButton
        public var clickCount: Int
        public var mode: DeliveryMode

        public init(
            pid: pid_t,
            windowID: CGWindowID?,
            windowFrame: CGRect?,
            global: CGPoint,
            button: CGMouseButton = .left,
            clickCount: Int = 1,
            mode: DeliveryMode = .background
        ) {
            self.pid = pid
            self.windowID = windowID
            self.windowFrame = windowFrame
            self.global = global
            self.button = button
            self.clickCount = clickCount
            self.mode = mode
        }
    }

    public static func click(_ request: ClickRequest) throws {
        let downType: CGEventType
        let upType: CGEventType
        switch request.button {
        case .left: downType = .leftMouseDown; upType = .leftMouseUp
        case .right: downType = .rightMouseDown; upType = .rightMouseUp
        default: downType = .otherMouseDown; upType = .otherMouseUp
        }

        var routing: (windowID: CGWindowID, local: CGPoint)?
        if request.mode == .background {
            guard supportsWindowRouting else {
                throw AmcuError(.unsupported, "window-routed events are unavailable on this system", nextSteps: [
                    "Run `amcu doctor` for details.",
                    "Use --mode foreground, or address the element semantically with `amcu click --element N`."
                ])
            }
            guard let windowID = request.windowID, let frame = request.windowFrame else {
                throw AmcuError(.invalidArgument, "background clicks need a resolvable target window", nextSteps: [
                    "Pass --window-id, or use --mode foreground."
                ])
            }
            routing = (windowID, windowLocal(global: request.global, windowFrame: frame))
        }

        for step in 1...max(1, request.clickCount) {
            let down = try makeMouseEvent(type: downType, global: request.global, button: request.button, clickState: Int64(step), routing: routing)
            let up = try makeMouseEvent(type: upType, global: request.global, button: request.button, clickState: Int64(step), routing: routing)
            post(down, to: request.pid, mode: request.mode)
            usleep(20_000)
            post(up, to: request.pid, mode: request.mode)
            if step < request.clickCount { usleep(40_000) }
        }
    }

    public static func scroll(
        pid: pid_t,
        windowID: CGWindowID?,
        windowFrame: CGRect?,
        global: CGPoint,
        deltaX: Int32,
        deltaY: Int32,
        mode: DeliveryMode
    ) throws {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else {
            throw AmcuError(.unsupported, "could not construct scroll event")
        }
        event.location = global
        if mode == .background {
            guard supportsWindowRouting, let windowID, let windowFrame else {
                throw AmcuError(.unsupported, "background scrolling needs window routing and a target window", nextSteps: [
                    "Run `amcu doctor`, pass --window-id, or use --mode foreground."
                ])
            }
            event.setIntegerValueField(kMouseEventWindowUnderMousePointer, value: Int64(windowID))
            event.setIntegerValueField(kMouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
            setWindowLocation?(event, windowLocal(global: global, windowFrame: windowFrame))
        }
        post(event, to: pid, mode: mode)
    }

    public static func drag(
        pid: pid_t,
        windowID: CGWindowID?,
        windowFrame: CGRect?,
        from start: CGPoint,
        to end: CGPoint,
        steps: Int,
        mode: DeliveryMode
    ) throws {
        var routing: (windowID: CGWindowID, local: CGPoint)?
        func routingFor(_ point: CGPoint) throws -> (windowID: CGWindowID, local: CGPoint)? {
            guard mode == .background else { return nil }
            guard supportsWindowRouting, let windowID, let windowFrame else {
                throw AmcuError(.unsupported, "background dragging needs window routing and a target window", nextSteps: [
                    "Run `amcu doctor`, pass --window-id, or use --mode foreground."
                ])
            }
            return (windowID, windowLocal(global: point, windowFrame: windowFrame))
        }

        routing = try routingFor(start)
        post(try makeMouseEvent(type: .leftMouseDown, global: start, button: .left, clickState: 1, routing: routing), to: pid, mode: mode)

        let count = max(1, steps)
        for step in 1...count {
            let t = Double(step) / Double(count)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            routing = try routingFor(point)
            post(try makeMouseEvent(type: .leftMouseDragged, global: point, button: .left, clickState: 1, routing: routing), to: pid, mode: mode)
            usleep(12_000)
        }

        routing = try routingFor(end)
        post(try makeMouseEvent(type: .leftMouseUp, global: end, button: .left, clickState: 1, routing: routing), to: pid, mode: mode)
    }

    static func post(_ event: CGEvent, to pid: pid_t, mode: DeliveryMode) {
        switch mode {
        case .background: event.postToPid(pid)
        case .foreground: event.post(tap: .cghidEventTap)
        }
    }
}

public enum KeyboardInput {
    /// Types literal text without depending on the current keyboard layout or
    /// input method: the characters ride on the event as a Unicode string rather
    /// than being reconstructed from virtual key codes.
    public static func type(text: String, pid: pid_t, mode: DeliveryMode, chunkDelay: UInt32 = 4_000) throws {
        guard !text.isEmpty else { return }
        // Long strings are split because the per-event Unicode payload is bounded.
        for chunk in TextChunker.split(text, by: 16) {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw AmcuError(.unsupported, "could not construct keyboard event")
            }
            let utf16 = Array(chunk.utf16)
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            PointerInput.post(down, to: pid, mode: mode)
            PointerInput.post(up, to: pid, mode: mode)
            usleep(chunkDelay)
        }
    }

    public static func press(key: String, modifiers: [String], pid: pid_t, mode: DeliveryMode) throws {
        guard let code = KeyCodes.code(for: key) else {
            throw AmcuError(.invalidArgument, "unknown key '\(key)'", nextSteps: [
                "Known keys: \(KeyCodes.knownNames.joined(separator: ", "))",
                "For literal characters use `amcu type` instead."
            ])
        }
        var flags: CGEventFlags = []
        for modifier in modifiers {
            guard let flag = KeyCodes.modifier(for: modifier) else {
                throw AmcuError(.invalidArgument, "unknown modifier '\(modifier)'", nextSteps: [
                    "Known modifiers: cmd, shift, alt (option), ctrl, fn."
                ])
            }
            flags.insert(flag)
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw AmcuError(.unsupported, "could not construct keyboard event")
        }
        down.flags = flags
        up.flags = flags
        PointerInput.post(down, to: pid, mode: mode)
        usleep(15_000)
        PointerInput.post(up, to: pid, mode: mode)
    }
}

/// Splits text into per-event payloads on character boundaries, so a multi-byte
/// character is never torn across two events.
public enum TextChunker {
    public static func split(_ text: String, by size: Int) -> [String] {
        guard text.count > size else { return [text] }
        var result: [String] = []
        var current = text.startIndex
        while current < text.endIndex {
            let next = text.index(current, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[current..<next]))
            current = next
        }
        return result
    }
}
