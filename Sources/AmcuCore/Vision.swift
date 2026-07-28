import CoreGraphics
import CoreText
import Foundation
import Vision

/// Text recognised in a window capture, expressed in the same window-relative
/// point space as accessibility elements so both can be clicked the same way.
public struct VisionMark: Sendable {
    public let text: String
    public let confidence: Float
    public let frame: CGRect

    public init(text: String, confidence: Float, frame: CGRect) {
        self.text = text
        self.confidence = confidence
        self.frame = frame
    }
}

/// Optical fallback for windows that publish no usable accessibility tree.
///
/// This deliberately stops at *addressable* vision: it returns text and where
/// that text is, and leaves interpretation to the caller's model. amcu does
/// not embed a vision model of its own — the agent driving it already has one,
/// and what that agent lacks is a way to turn a point in a screenshot into an
/// accurate click on a window it is not looking at. That part amcu does have.
///
/// The trade-off against the accessibility tree is real and worth stating:
/// recognised text carries no role, no state, and no actions. A disabled button
/// and a caption look identical here. Marks are therefore a fallback, never a
/// replacement.
public enum VisionScan {
    public static func recognizeText(
        in image: CGImage,
        windowSize: CGSize,
        languages: [String] = ["zh-Hans", "en-US"],
        minimumConfidence: Float = 0.3
    ) throws -> [VisionMark] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw AmcuError(.captureFailure, "text recognition failed: \(error.localizedDescription)", nextSteps: [
                "Confirm the window is still on screen and re-run.",
                "If this keeps happening, capture with `amcu screenshot` and inspect the image."
            ])
        }

        guard let observations = request.results else { return [] }

        // Vision reports normalized coordinates with a bottom-left origin; the
        // rest of amcu speaks window-relative points with a top-left origin.
        let scaleX = windowSize.width
        let scaleY = windowSize.height

        return observations.compactMap { observation -> VisionMark? in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= minimumConfidence else { return nil }
            let box = observation.boundingBox
            let frame = CGRect(
                x: box.minX * scaleX,
                y: (1 - box.maxY) * scaleY,
                width: box.width * scaleX,
                height: box.height * scaleY
            )
            return VisionMark(text: candidate.string, confidence: candidate.confidence, frame: frame)
        }
        .sorted { lhs, rhs in
            // Reading order, so indices are stable enough to talk about.
            if abs(lhs.frame.minY - rhs.frame.minY) > 8 { return lhs.frame.minY < rhs.frame.minY }
            return lhs.frame.minX < rhs.frame.minX
        }
    }

    /// Draws numbered boxes over the capture so a model looking at the image can
    /// name a target by the same index the CLI accepts.
    public static func annotate(_ image: CGImage, marks: [VisionMark], windowSize: CGSize) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scaleX = CGFloat(width) / max(windowSize.width, 1)
        let scaleY = CGFloat(height) / max(windowSize.height, 1)
        context.setLineWidth(max(1, scaleX))

        for (index, mark) in marks.enumerated() {
            // Back to the image's bottom-left origin for drawing.
            let rect = CGRect(
                x: mark.frame.minX * scaleX,
                y: CGFloat(height) - (mark.frame.maxY * scaleY),
                width: mark.frame.width * scaleX,
                height: mark.frame.height * scaleY
            )
            context.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.9))
            context.stroke(rect)

            let label = "\(index)"
            let badgeSide = 14 * scaleX
            let badge = CGRect(x: rect.minX, y: rect.maxY, width: badgeSide * CGFloat(label.count), height: badgeSide)
            context.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.9))
            context.fill(badge)

            let attributes: [NSAttributedString.Key: Any] = [
                .font: CTFontCreateWithName("Helvetica-Bold" as CFString, badgeSide * 0.8, nil),
                .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
            context.textPosition = CGPoint(x: badge.minX + badgeSide * 0.15, y: badge.minY + badgeSide * 0.2)
            CTLineDraw(line, context)
        }

        return context.makeImage()
    }
}
