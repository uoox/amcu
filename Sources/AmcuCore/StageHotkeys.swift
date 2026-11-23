import Carbon.HIToolbox
import Foundation

/// Global Carbon hotkeys for the stage host. Unlike `CGEventTap`, Carbon hotkeys
/// require no extra Input Monitoring grant and cost zero idle CPU.
public enum StageHotkeys {
    public struct Binding: Equatable, Sendable {
        public let keyCode: UInt32
        public let modifiers: UInt32

        public init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }
    }

    public static func parse(_ spec: String) -> Binding? {
        let parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let keyName = parts.last, let code = KeyCodes.code(for: keyName) else { return nil }
        var modifiers: UInt32 = 0
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "opt", "option", "alt": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default: return nil
            }
        }
        guard modifiers != 0 else { return nil }
        return Binding(keyCode: UInt32(code), modifiers: modifiers)
    }
}

private func stageHotkeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ refcon: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let refcon else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    Unmanaged<StageHotkeyManager>.fromOpaque(refcon).takeUnretainedValue().triggered(id: hotKeyID.id)
    return noErr
}

final class StageHotkeyManager {
    enum Action: UInt32 {
        case putFront = 1
        case toggleWindow = 2
    }

    private static let signature: OSType = 0x414D4355 // "AMCU"

    private let onAction: (Action) -> Void
    private var handlerRef: EventHandlerRef?
    private var registered: [EventHotKeyRef] = []
    private(set) var enabled = false

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
    }

    deinit {
        unregisterAll()
    }

    func setEnabled(_ active: Bool, putFrontSpec: String, toggleWindowSpec: String) {
        unregisterAll()
        enabled = active
        guard active else { return }
        installHandlerIfNeeded()
        if let binding = StageHotkeys.parse(putFrontSpec) {
            register(id: Action.putFront.rawValue, binding: binding)
        }
        if let binding = StageHotkeys.parse(toggleWindowSpec) {
            register(id: Action.toggleWindow.rawValue, binding: binding)
        }
    }

    func unregisterAll() {
        for ref in registered { UnregisterEventHotKey(ref) }
        registered.removeAll()
        if let handler = handlerRef {
            RemoveEventHandler(handler)
            handlerRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), stageHotkeyCallback, 1, &spec, refcon, &handlerRef)
    }

    private func register(id: UInt32, binding: StageHotkeys.Binding) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        if RegisterEventHotKey(binding.keyCode, binding.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            registered.append(ref)
        }
    }

    fileprivate func triggered(id: UInt32) {
        guard let action = Action(rawValue: id) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onAction(action)
        }
    }
}
