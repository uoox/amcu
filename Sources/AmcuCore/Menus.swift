import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct MenuItem: Codable, Sendable {
    public let path: [String]
    public let enabled: Bool
    public let hasSubmenu: Bool
    /// The item's keyboard equivalent, when it advertises one.
    public let shortcut: String?
    /// Child indices from the menu bar down, for re-resolution.
    public let route: [Int]

    public var displayPath: String { path.joined(separator: " > ") }
}

/// The menu bar, read without opening it.
///
/// An application's menu bar is reachable through the accessibility API whether
/// or not that application is frontmost, and — importantly — the items and their
/// keyboard equivalents can be read *without* pressing anything, so nothing
/// appears on screen while an agent is looking around.
///
/// That matters for how menus get invoked. Pressing a menu item makes the menu
/// visibly open and pulls the application forward. When an item advertises a
/// keyboard equivalent, sending that shortcut to the process achieves the same
/// thing with none of the display: it is the difference between a menu-driven
/// task the user watches happen to them, and one they never notice.
public enum Menus {
    static func menuBar(of app: NSRunningApplication) throws -> AXUIElement {
        let appElement = Target.appElement(app)
        guard let bar = AX.element(appElement, "AXMenuBar") else {
            if !AXIsProcessTrusted() { throw AmcuError.notTrusted() }
            throw AmcuError(.unsupported, "'\(app.localizedName ?? "app")' publishes no menu bar", nextSteps: [
                "Background-only agents and some Electron applications have no menu bar of their own.",
                "Run `amcu apps` to confirm the target is the application you meant."
            ])
        }
        return bar
    }

    /// Reads the menu bar to `maxDepth` levels. Submenu contents are usually
    /// populated without opening the menu; where an application builds items
    /// lazily, the submenu reads as empty and is reported as such rather than
    /// being forced open.
    public static func list(of app: NSRunningApplication, maxDepth: Int = 3) throws -> [MenuItem] {
        let bar = try menuBar(of: app)
        var items: [MenuItem] = []

        func walk(_ element: AXUIElement, path: [String], route: [Int], depth: Int) {
            guard depth <= maxDepth else { return }
            for (index, child) in AX.children(element).enumerated() {
                let role = AX.string(child, kAXRoleAttribute as String) ?? ""
                if role == "AXMenu" {
                    // A menu is a container; its items keep the parent's path.
                    walk(child, path: path, route: route + [index], depth: depth)
                    continue
                }
                let title = AX.string(child, kAXTitleAttribute as String) ?? ""
                // Separators have no title and nothing to invoke.
                guard !title.isEmpty else { continue }
                let childPath = path + [title]
                let childRoute = route + [index]
                let submenus = AX.children(child).filter {
                    (AX.string($0, kAXRoleAttribute as String) ?? "") == "AXMenu"
                }
                let hasChildren = submenus.contains { !AX.children($0).isEmpty }
                items.append(MenuItem(
                    path: childPath,
                    enabled: AX.bool(child, kAXEnabledAttribute as String) ?? true,
                    hasSubmenu: hasChildren,
                    shortcut: shortcut(of: child),
                    route: childRoute
                ))
                if hasChildren {
                    walk(child, path: childPath, route: childRoute, depth: depth + 1)
                }
            }
        }

        walk(bar, path: [], route: [], depth: 1)
        return items
    }

    /// Renders a menu item's keyboard equivalent in the same syntax `amcu key`
    /// accepts, so the shortcut a listing shows can be used directly.
    static func shortcut(of element: AXUIElement) -> String? {
        guard let character = AX.string(element, "AXMenuItemCmdChar"), !character.isEmpty else { return nil }
        let raw = (AX.attribute(element, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue ?? 0
        var modifiers: [String] = []
        // The command flag is present unless bit 3 explicitly clears it.
        if raw & 8 == 0 { modifiers.append("cmd") }
        if raw & 1 != 0 { modifiers.append("shift") }
        if raw & 2 != 0 { modifiers.append("alt") }
        if raw & 4 != 0 { modifiers.append("ctrl") }
        // Normalise the glyph spelling so the printed shortcut is one `amcu
        // key` accepts verbatim.
        let key = KeyCodes.glyphs[character] ?? character.lowercased()
        return (modifiers + [key]).joined(separator: "+")
    }

    public static func find(_ path: [String], in app: NSRunningApplication) throws -> MenuItem {
        let items = try list(of: app, maxDepth: 5)
        let wanted = path.map { $0.lowercased() }
        if let exact = items.first(where: { $0.path.map({ $0.lowercased() }) == wanted }) {
            return exact
        }
        // A trailing-segment match lets callers name just the item when the
        // full path is unambiguous.
        let suffixed = items.filter { item in
            item.path.count >= wanted.count
                && item.path.suffix(wanted.count).map { $0.lowercased() } == wanted
        }
        if suffixed.count == 1 { return suffixed[0] }
        if suffixed.count > 1 {
            throw AmcuError(.invalidArgument, "'\(path.joined(separator: " > "))' matches \(suffixed.count) menu items", nextSteps: [
                "Give the full path, for example --path \"File > Export > PDF\".",
                "Run `amcu menu --app <selector>` to see the available paths."
            ])
        }
        throw AmcuError(.elementNotFound, "no menu item at '\(path.joined(separator: " > "))'", nextSteps: [
            "Run `amcu menu --app <selector>` to list what this application publishes.",
            "Some applications build submenu items only when the menu is opened; those appear empty here."
        ])
    }

    public static func resolve(_ item: MenuItem, in app: NSRunningApplication) throws -> AXUIElement {
        var current = try menuBar(of: app)
        for step in item.route {
            let children = AX.children(current)
            guard step < children.count else {
                throw AmcuError(.staleSnapshot, "menu item '\(item.displayPath)' is no longer at its recorded position", nextSteps: [
                    "Re-run `amcu menu --app <selector>`; the menu changed."
                ])
            }
            current = children[step]
        }
        let title = AX.string(current, kAXTitleAttribute as String) ?? ""
        guard title == item.path.last else {
            throw AmcuError(.staleSnapshot, "menu item changed ('\(item.path.last ?? "")' -> '\(title)')", nextSteps: [
                "Re-run `amcu menu --app <selector>`; the menu changed."
            ])
        }
        return current
    }
}
