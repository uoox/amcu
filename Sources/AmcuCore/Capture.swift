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
/// captures correctly — the same property that makes the rest of amcu work
/// without disturbing the user.
public enum Capture {
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// ScreenCaptureKit needs the process to hold a window-server connection.
    /// A plain command-line tool has none until AppKit is initialized, and
    /// without it CoreGraphics aborts the process outright rather than
    /// returning an error. Initializing as an accessory keeps amcu out of the
    /// Dock and out of the user's way.
    private static let windowServerReady: Bool = {
        let app = NSApplication.shared
        if app.activationPolicy() != .accessory {
            app.setActivationPolicy(.accessory)
        }
        return true
    }()

    public struct Captured {
        public let image: CGImage
        /// "screencapturekit", or "window-server" for the private fallback.
        public let via: String
    }

    /// ScreenCaptureKit, unless the caller knows the window is on another
    /// desktop: there SCK captured a Chrome window fine on 27.2 but answered
    /// `SCStreamErrorDomain -3811` for a probe's own window, so those go to
    /// the window server's own capture first (`SLSHWCaptureWindowList`, what
    /// cua and AltTab use). That path is private, so the result says which
    /// one was used; an empty answer from it falls through to SCK. A
    /// minimised window gives the same stale, usually blank frame on both
    /// paths (measured: one colour), which the caller reports.
    public static func capture(id windowID: CGWindowID, scale: Bool = true, preferWindowServer: Bool = false) throws -> Captured {
        if preferWindowServer, let image = windowServerCapture(id: windowID) {
            return Captured(image: image, via: "window-server")
        }
        do {
            return Captured(image: try window(id: windowID, scale: scale), via: "screencapturekit")
        } catch let error as AmcuError where error.code == .timeout {
            // On 27.x the window server's capture goes through replayd too
            // (SLSHWCaptureWindowListToIOSurfaceProxying) and would wait just
            // the same.
            throw error
        } catch {
            if !preferWindowServer, let image = windowServerCapture(id: windowID) { return Captured(image: image, via: "window-server") }
            throw error
        }
    }

    private typealias HWCaptureFn = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32, UInt32) -> Unmanaged<CFArray>?
    private static let hwCapture: (connection: Int32, fn: HWCaptureFn)? = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connectionSymbol = dlsym(handle, "SLSMainConnectionID"),
              let captureSymbol = dlsym(handle, "SLSHWCaptureWindowList") else { return nil }
        let connection = unsafeBitCast(connectionSymbol, to: (@convention(c) () -> Int32).self)()
        return (connection, unsafeBitCast(captureSymbol, to: HWCaptureFn.self))
    }()

    public static var hasWindowServerCapture: Bool { hwCapture != nil }

    public static func windowServerCapture(id windowID: CGWindowID) -> CGImage? {
        _ = windowServerReady
        guard let hw = hwCapture else { return nil }
        var id = UInt32(windowID)
        // 1<<11 ignores the global clip shape (a window off its desktop is
        // clipped away entirely), 1<<8 asks for the backing-store resolution.
        guard let images = hw.fn(hw.connection, &id, 1, (1 << 11) | (1 << 8))?.takeRetainedValue() as? [CGImage],
              let image = images.first, image.width > 1, image.height > 1 else { return nil }
        return image
    }

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
                    throw AmcuError(.windowNotFound, "window \(windowID) is not available for capture", nextSteps: [
                        "Run `amcu windows --app <selector>` to list capturable windows.",
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
            } catch let error as AmcuError {
                box.value = .failure(error)
            } catch {
                box.value = .failure(AmcuError(.captureFailure, "screen capture failed: \(error.localizedDescription)", nextSteps: [
                    "Grant Screen Recording to the application running amcu in System Settings > Privacy & Security > Screen Recording.",
                    "Run `amcu doctor` to re-check permissions."
                ]))
            }
            semaphore.signal()
        }

        // replayd can stop answering: it did for a process sharing its
        // executable path with another that held capture streams. Fail
        // rather than hang the command for good.
        guard semaphore.wait(timeout: .now() + 6) == .success else {
            throw AmcuError(.timeout, "screen capture did not answer within 6 seconds", nextSteps: [
                "Retry once; if it keeps timing out, tell the user that screen capture is stuck instead of retrying in a loop."
            ])
        }
        guard let result = box.value else {
            throw AmcuError(.captureFailure, "screen capture produced no result")
        }
        return try result.get()
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AmcuError(.captureFailure, "could not create image file at \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AmcuError(.captureFailure, "could not write PNG to \(url.path)")
        }
    }

    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw AmcuError(.captureFailure, "could not encode PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AmcuError(.captureFailure, "could not encode PNG")
        }
        return data as Data
    }
}
