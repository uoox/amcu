import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Per-window capture through ScreenCaptureKit.
///
/// A window filter is used rather than a display filter so that a window which
/// is occluded, or belongs to an application that is not frontmost, still
/// captures correctly — the same property that makes the rest of umbra work
/// without disturbing the user.
public enum Capture {
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// ScreenCaptureKit needs the process to hold a window-server connection.
    /// A plain command-line tool has none until AppKit is initialized, and
    /// without it CoreGraphics aborts the process outright rather than
    /// returning an error. Initializing as an accessory keeps umbra out of the
    /// Dock and out of the user's way.
    private static let windowServerReady: Bool = {
        let app = NSApplication.shared
        if app.activationPolicy() != .accessory {
            app.setActivationPolicy(.accessory)
        }
        return true
    }()

    public static func window(id windowID: CGWindowID, scale: Bool = true) throws -> CGImage {
        _ = windowServerReady
        // A one-shot CLI has no event loop to return to, so the async capture is
        // bridged by blocking the calling thread. This is only safe because
        // nothing awaited below is main-actor-isolated; if that ever changes,
        // this command needs to become async rather than gain another hop.
        let box = Box<Result<CGImage, Error>?>(nil)
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let target = content.windows.first(where: { $0.windowID == windowID }) else {
                    throw UmbraError(.windowNotFound, "window \(windowID) is not available for capture", nextSteps: [
                        "Run `umbra windows --app <selector>` to list capturable windows.",
                        "Minimised windows cannot be captured; restore the window first."
                    ])
                }
                let filter = SCContentFilter(desktopIndependentWindow: target)
                let configuration = SCStreamConfiguration()
                let pixelScale = scale ? filter.pointPixelScale : 1
                configuration.width = Int(filter.contentRect.width * CGFloat(pixelScale))
                configuration.height = Int(filter.contentRect.height * CGFloat(pixelScale))
                configuration.showsCursor = false
                configuration.captureResolution = .best
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                box.value = .success(image)
            } catch let error as UmbraError {
                box.value = .failure(error)
            } catch {
                box.value = .failure(UmbraError(.captureFailure, "screen capture failed: \(error.localizedDescription)", nextSteps: [
                    "Grant Screen Recording to the application running umbra in System Settings > Privacy & Security > Screen Recording.",
                    "Run `umbra doctor` to re-check permissions."
                ]))
            }
            semaphore.signal()
        }

        semaphore.wait()
        guard let result = box.value else {
            throw UmbraError(.captureFailure, "screen capture produced no result")
        }
        return try result.get()
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw UmbraError(.captureFailure, "could not create image file at \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw UmbraError(.captureFailure, "could not write PNG to \(url.path)")
        }
    }

    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw UmbraError(.captureFailure, "could not encode PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw UmbraError(.captureFailure, "could not encode PNG")
        }
        return data as Data
    }
}
