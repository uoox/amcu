import CoreGraphics

public enum KeyCodes {
    static let table: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "forwarddelete": 117,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31,
        "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9,
        "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
        "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        "minus": 27, "equal": 24, "comma": 43, "period": 47, "slash": 44,
        "semicolon": 41, "quote": 39, "leftbracket": 33, "rightbracket": 30,
        "backslash": 42, "grave": 50
    ]

    public static var knownNames: [String] { table.keys.sorted() }

    public static func code(for name: String) -> CGKeyCode? {
        table[name.lowercased()]
    }

    public static func modifier(for name: String) -> CGEventFlags? {
        switch name.lowercased() {
        case "cmd", "command", "meta": return .maskCommand
        case "shift": return .maskShift
        case "alt", "option", "opt": return .maskAlternate
        case "ctrl", "control": return .maskControl
        case "fn", "function": return .maskSecondaryFn
        default: return nil
        }
    }
}
