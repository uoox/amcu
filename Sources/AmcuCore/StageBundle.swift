import AppKit
import ImageIO

public enum StageBundle {
    public static var appURL: URL { Stage.cacheDirectory.appendingPathComponent("stage-host/amcu.app", isDirectory: true) }
    /// Standalone user-facing app bundle in `~/Applications` so macOS Spotlight,
    /// Finder and Chrome's native host can launch the stage with its own stable
    /// signature and TCC grants.
    public static var installedAppURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/amcu Stage.app", isDirectory: true)
    }
    static var executableURL: URL { appURL.appendingPathComponent("Contents/MacOS/amcu") }
    private static var legacyExecutableURL: URL { Stage.cacheDirectory.appendingPathComponent("stage-host/amcu") }
    private static let iconRevision = "1"

    public static var identifier: String {
        Stage.identity.serial == 1 ? "cc.uoox.amcu.stage" : "cc.uoox.amcu.stage.\(Stage.identity.serial)"
    }

    public static var isCurrentProcessInside: Bool {
        let current = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        if current == appURL.resolvingSymlinksInPath().standardizedFileURL.path { return true }
        if Stage.identity.serial == 1 && current == installedAppURL.resolvingSymlinksInPath().standardizedFileURL.path { return true }
        return false
    }

    static func infoPlist(version: String) -> [String: Any] {
        [
            "CFBundleIdentifier": identifier,
            "CFBundleName": "amcu",
            "CFBundleDisplayName": "amcu",
            "CFBundleExecutable": "amcu",
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleSignature": "????",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleLocalizations": ["en", "zh-Hans"],
            "CFBundleAllowMixedLocalizations": true,
            "LSMinimumSystemVersion": "14.0",
            "LSApplicationCategoryType": "public.app-category.developer-tools",
            "NSHighResolutionCapable": true,
            "NSSupportsAutomaticGraphicsSwitching": true,
            "NSPrincipalClass": "NSApplication",
            "AmcuIconRevision": iconRevision
        ]
    }

    @discardableResult
    static func install(from source: URL, to bundleURL: URL = appURL) throws -> String {
        let manager = FileManager.default
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resources = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let targetExecutable = contentsURL.appendingPathComponent("MacOS/amcu")
        let iconURL = resources.appendingPathComponent("AppIcon.icns")
        do {
            try manager.createDirectory(at: resources, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.createDirectory(at: targetExecutable.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw AmcuError(.stageUnavailable, "could not make the stage app at \(bundleURL.path): \(error.localizedDescription)")
        }
        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        let previous = (try? Data(contentsOf: infoURL)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let info = infoPlist(version: AmcuVersion.string)
        if previous?["CFBundleVersion"] as? String != AmcuVersion.string || previous?["CFBundleIdentifier"] as? String != identifier
            || previous?["AmcuIconRevision"] as? String != iconRevision {
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: infoURL, options: .atomic)
            try Data("APPL????".utf8).write(to: contentsURL.appendingPathComponent("PkgInfo"), options: .atomic)
        }
        if previous?["AmcuIconRevision"] as? String != iconRevision || !manager.fileExists(atPath: iconURL.path), let icns = StageIcon.icns() {
            try? icns.write(to: iconURL, options: .atomic)
        }
        let executable = try Stage.cloneExecutable(from: source, to: targetExecutable)
        if bundleURL == appURL, manager.fileExists(atPath: legacyExecutableURL.path) {
            try? manager.removeItem(at: legacyExecutableURL)
        }
        return executable
    }

    /// Installs and signs `~/Applications/amcu Stage.app`, then registers it
    /// with Launch Services so Finder, Spotlight and browser extensions can
    /// start the stage with its own TCC grants.
    public static func installStandaloneApp(signIdentity: String? = nil) throws -> (appPath: String, signedWith: String) {
        let source = URL(fileURLWithPath: Responsibility.executablePath).resolvingSymlinksInPath()
        _ = try install(from: source, to: installedAppURL)
        let listing = (try? SafariInstall.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]).output) ?? ""
        let requested = signIdentity ?? ProcessInfo.processInfo.environment["AMCU_SIGN_IDENTITY"]
        let signer = SafariInstall.chooseSigner(identityListing: listing, requested: requested)
        let result = try SafariInstall.run("/usr/bin/codesign", ["--force", "--deep", "--sign", signer.codesignArgument, installedAppURL.path])
        guard result.status == 0 else {
            throw AmcuError(.stageUnavailable, "codesign failed for \(installedAppURL.path): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        _ = try? SafariInstall.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", installedAppURL.path])
        return (installedAppURL.path, signer.description)
    }
}

enum StageIcon {
    static func image(side: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            draw(in: rect)
            return true
        }
    }

    static func draw(in rect: NSRect) {
        let side = rect.width
        let body = rect.insetBy(dx: side * 0.098, dy: side * 0.098)
        let radius = body.width * 0.225
        let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = side * 0.022
        shadow.shadowOffset = NSSize(width: 0, height: -side * 0.009)
        shadow.set()
        NSColor(srgbRed: 0.93, green: 0.36, blue: 0.20, alpha: 1).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(colors: [
            NSColor(srgbRed: 1.00, green: 0.66, blue: 0.30, alpha: 1),
            NSColor(srgbRed: 0.95, green: 0.42, blue: 0.22, alpha: 1),
            NSColor(srgbRed: 0.80, green: 0.22, blue: 0.24, alpha: 1)
        ])?.draw(in: body, angle: -90)
        let floor = NSRect(x: body.minX, y: body.minY, width: body.width, height: body.height * 0.2)
        NSColor.black.withAlphaComponent(0.10).setFill()
        floor.fill()
        NSGraphicsContext.restoreGraphicsState()
        let configuration = NSImage.SymbolConfiguration(pointSize: body.width * 0.42, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "theatermasks.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            let size = symbol.size
            let origin = NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2 + body.height * 0.035)
            NSGraphicsContext.saveGraphicsState()
            let glyphShadow = NSShadow()
            glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            glyphShadow.shadowBlurRadius = side * 0.012
            glyphShadow.shadowOffset = NSSize(width: 0, height: -side * 0.006)
            glyphShadow.set()
            symbol.draw(in: NSRect(origin: origin, size: size))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func cgImage(pixels: Int) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        context.flushGraphics()
        return rep.cgImage
    }

    static func icns() -> Data? {
        let data = NSMutableData()
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        guard let destination = CGImageDestinationCreateWithData(data, "com.apple.icns" as CFString, sizes.count, nil) else { return nil }
        for pixels in sizes {
            guard let image = cgImage(pixels: pixels) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
