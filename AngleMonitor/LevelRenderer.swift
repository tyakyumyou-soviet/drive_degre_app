import AVFoundation
import CoreVideo
import CoreGraphics
import Foundation
import UIKit
import CoreText
import CoreImage

enum HUDDesign: String, CaseIterable, Identifiable {
    case b = "B"
    case c = "C"
    var id: String { rawValue }
}

struct AngleSnapshot {
    let degrees: Double
    let sensorTime: Date?
    let appState: String
}

/// Renders the HUD into a landscape frame so the PiP window presents a wide instrument panel.
final class LevelRenderer {
    static let frameRate: Int32 = 30
    let width = 640
    let height = 360
    private var formatDescription: CMVideoFormatDescription?
    private var lastPTS = CMTime.zero
    private var bufferPool: CVPixelBufferPool?

    init() {
        let pixelAttributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary
        let result = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes, pixelAttributes as CFDictionary, &bufferPool)
        if result != kCVReturnSuccess { print("[AngleMonitor] buffer pool creation failed: \(result)") }
    }

    func makeSample(angle: Double, timestamp: CMTime, appState: String, design: HUDDesign = .b) -> CMSampleBuffer? {
        var buffer: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary
        guard let bufferPool,
              CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, bufferPool, limits, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        draw(in: context, angle: angle, appState: appState, design: design)

        if formatDescription == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
        }
        guard let formatDescription else { return nil }
        let pts = CMTimeCompare(timestamp, lastPTS) > 0 ? timestamp : CMTimeAdd(lastPTS, CMTime(value: 1, timescale: Self.frameRate))
        lastPTS = pts
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Self.frameRate), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                       formatDescription: formatDescription, sampleTiming: &timing, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    private func draw(in c: CGContext, angle: Double, appState: String, design: HUDDesign) {
        // Pixel buffers use Quartz's bottom-up axes; the shared HUD uses UIKit's
        // top-down axes. Flip the entire frame once, including ticks and text.
        c.saveGState()
        defer { c.restoreGState() }
        c.translateBy(x: 0, y: CGFloat(height))
        c.scaleBy(x: 1, y: -1)
        Self.drawHUD(in: c, size: CGSize(width: width, height: height), angle: angle, appState: appState, design: design)
    }

    /// Portrait and PiP share the same renderer and design selection.
    static func drawHUD(in c: CGContext, size: CGSize, angle: Double, appState: String, design: HUDDesign = .b) {
        let w = size.width, h = size.height
        let portrait = h > w
        let centre = CGPoint(x: w / 2, y: h / 2)
        let pixelsPerDegree = h * 0.34 / 30
        let background = UIColor(red: 0.018, green: 0.032, blue: 0.045, alpha: 1)
        let cyan = UIColor.systemCyan
        let majorWidth: CGFloat = portrait ? 3 : 4
        c.saveGState()
        defer { c.restoreGState() }
        c.setFillColor(background.cgColor)
        c.fill(CGRect(origin: .zero, size: size))

        c.setStrokeColor(cyan.withAlphaComponent(0.6).cgColor)
        c.setLineWidth(1)
        c.stroke(CGRect(x: 12, y: 12, width: w - 24, height: h - 24))
        c.setLineWidth(3)
        for (x, y, sx, sy) in [(CGFloat(20), CGFloat(20), CGFloat(1), CGFloat(1)), (w - 20, 20, -1, 1), (20, h - 20, 1, -1), (w - 20, h - 20, -1, -1)] {
            c.move(to: CGPoint(x: x, y: y + sy * 14))
            c.addLine(to: CGPoint(x: x, y: y))
            c.addLine(to: CGPoint(x: x + sx * 14, y: y))
        }
        c.strokePath()
        drawText("ANGLE / PITCH", rect: CGRect(x: 25, y: 28, width: w * 0.42, height: 22), font: .systemFont(ofSize: portrait ? 12 : 15, weight: .semibold), color: cyan, context: c)
        drawText("LIVE", rect: CGRect(x: w - 86, y: 28, width: 60, height: 22), font: .systemFont(ofSize: 13, weight: .bold), color: .systemGreen, context: c)

        if design == .c {
            drawDesignC(in: c, size: size, angle: angle)
            drawText(appState.uppercased(), rect: CGRect(x: 25, y: h - 44, width: w - 50, height: 20), font: .systemFont(ofSize: 11, weight: .medium), color: .white.withAlphaComponent(0.4), context: c)
            return
        }

        // Fixed red zero wings never move. Cyan zero uses the same centre.y above.
        let inner = w * (portrait ? 0.18 : 0.23)
        c.setStrokeColor(referenceRed.cgColor)
        c.setLineWidth(portrait ? 7.5 : 10.5)
        c.move(to: CGPoint(x: w * 0.035, y: centre.y)); c.addLine(to: CGPoint(x: inner, y: centre.y))
        c.move(to: CGPoint(x: w - inner, y: centre.y)); c.addLine(to: CGPoint(x: w * 0.965, y: centre.y))
        c.strokePath()
        drawText("0", rect: CGRect(x: w * 0.04, y: centre.y - 28, width: 25, height: 22), font: .systemFont(ofSize: 16, weight: .bold), color: referenceRed, context: c)
        drawText("0", rect: CGRect(x: w * 0.96 - 25, y: centre.y - 28, width: 25, height: 22), font: .systemFont(ofSize: 16, weight: .bold), color: referenceRed, context: c)


        // Large static readout sits behind the moving HUD ladder.
        let fontSize = w * (portrait ? 0.3271752 : 0.2020788)
        let numberRect = CGRect(x: w * 0.11, y: centre.y - fontSize * 0.65, width: w * 0.78, height: fontSize * 1.3)
        drawText(String(format: "%+.1f°", angle), rect: numberRect,
                 font: .monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
                 color: numberColor(for: angle), context: c, compressHorizontally: true)

        c.saveGState()
        c.clip(to: CGRect(x: 22, y: h * 0.12, width: w - 44, height: h * 0.76))
        for degree in stride(from: -210, through: 210, by: 2) {
            let y = centre.y + CGFloat(angle - Double(degree)) * pixelsPerDegree
            guard y >= h * 0.16 - 10, y <= h * 0.84 + 10 else { continue }
            let major = degree.isMultiple(of: 10)
            let halfLength = degree == 0 ? w * (portrait ? 0.36 : 0.305) : w * (major ? 0.05 : 0.025)
            c.setStrokeColor(cyan.withAlphaComponent(major ? 1 : 0.45).cgColor)
            c.setLineWidth(degree == 0 ? majorWidth * 1.5 : (major ? majorWidth : 1))
            // The moving zero is drawn above the number as one continuous line.
            c.move(to: CGPoint(x: centre.x - halfLength, y: y))
            c.addLine(to: CGPoint(x: centre.x + halfLength, y: y))
            c.strokePath()
            if major && (degree == 0 || abs(y - centre.y) > fontSize * 0.42) {
                drawText(degree == 0 ? "0°" : String(format: "%+d", degree),
                         rect: CGRect(x: centre.x + halfLength + 6, y: y - (degree == 0 ? 26 : 11), width: 42, height: 22),
                         font: .monospacedDigitSystemFont(ofSize: portrait ? 11 : 14, weight: .medium), color: cyan, context: c)
            }
        }
        c.restoreGState()


        drawText(appState.uppercased(), rect: CGRect(x: 25, y: h - 44, width: w - 50, height: 20), font: .systemFont(ofSize: 11, weight: .medium), color: .white.withAlphaComponent(0.4), context: c)
    }

    private static func drawDesignC(in c: CGContext, size: CGSize, angle: Double) {
        let w = size.width, h = size.height
        let portrait = h > w
        let middleY = h / 2
        let left = w * 0.16, right = w * 0.84
        let limit = 20
        let pointsPerDegree = h * 0.32 / CGFloat(limit)
        let majorLength = w * 0.035, minorLength = w * 0.018
        let cyan = UIColor.systemCyan
        let majorWidth: CGFloat = portrait ? 3 : 4

        // White zero reference is fixed, and drawn behind the numeric readout.
        c.setStrokeColor(UIColor.white.cgColor)
        c.setLineWidth(portrait ? 4.5 : 6)
        c.move(to: CGPoint(x: left, y: middleY))
        c.addLine(to: CGPoint(x: right, y: middleY))
        c.strokePath()

        // Both rulers remain anchored at the outer edges, regardless of angle.
        c.setStrokeColor(cyan.withAlphaComponent(0.45).cgColor)
        c.setLineWidth(1)
        for x in [left, right] {
            c.move(to: CGPoint(x: x, y: middleY - CGFloat(limit) * pointsPerDegree))
            c.addLine(to: CGPoint(x: x, y: middleY + CGFloat(limit) * pointsPerDegree))
        }
        c.strokePath()
        let labelWidth: CGFloat = portrait ? 30 : 38
        for degree in stride(from: -limit, through: limit, by: 2) {
            let y = middleY - CGFloat(degree) * pointsPerDegree
            let major = degree.isMultiple(of: 10)
            let length = major ? majorLength : minorLength
            c.setStrokeColor(cyan.withAlphaComponent(major ? 1 : 0.55).cgColor)
            c.setLineWidth(major ? majorWidth : 1)
            c.move(to: CGPoint(x: left, y: y)); c.addLine(to: CGPoint(x: left + length, y: y))
            c.move(to: CGPoint(x: right - length, y: y)); c.addLine(to: CGPoint(x: right, y: y))
            c.strokePath()
            if major {
                let label = degree == 0 ? "0" : String(format: "%+d", degree)
                let font = UIFont.monospacedDigitSystemFont(ofSize: portrait ? 11 : 14, weight: .semibold)
                drawText(label, rect: CGRect(x: left - labelWidth - 8, y: y - 11, width: labelWidth, height: 22), font: font, color: .white, context: c)
                drawText(label, rect: CGRect(x: right + 8, y: y - 11, width: labelWidth, height: 22), font: font, color: .white, context: c)
            }
        }

        // Positive goes up. Zero is exactly the fixed white reference's Y.
        let y = middleY - CGFloat(max(-Double(limit), min(Double(limit), angle))) * pointsPerDegree
        let leftTip = left - w * 0.025, rightTip = right + w * 0.025
        c.setStrokeColor(referenceRed.cgColor)
        c.setFillColor(referenceRed.cgColor)
        c.setLineWidth(majorWidth * 2.5875)
        c.move(to: CGPoint(x: leftTip, y: y)); c.addLine(to: CGPoint(x: rightTip, y: y))
        c.strokePath()
        let arrowSize: CGFloat = portrait ? 7 : 10
        for (x, direction) in [(leftTip, CGFloat(1)), (rightTip, CGFloat(-1))] {
            c.move(to: CGPoint(x: x, y: y))
            c.addLine(to: CGPoint(x: x + direction * arrowSize, y: y - arrowSize * 0.65))
            c.addLine(to: CGPoint(x: x + direction * arrowSize, y: y + arrowSize * 0.65))
            c.closePath(); c.fillPath()
        }
        // Keep the true number visible beyond the fixed ±20° ruler, with a
        // chevron indicating the pointer is off scale rather than silently lying.
        if abs(angle) > Double(limit) {
            let direction: CGFloat = angle > 0 ? -1 : 1
            c.setLineWidth(2)
            c.move(to: CGPoint(x: w / 2 - 7, y: y + direction * 5))
            c.addLine(to: CGPoint(x: w / 2, y: y + direction * 12))
            c.addLine(to: CGPoint(x: w / 2 + 7, y: y + direction * 5))
            c.strokePath()
        }

        // Draw only the glyphs over the pointer: their counters and gaps remain transparent.
        let fontSize = w * (portrait ? 0.3271752 : 0.2020788)
        drawText(String(format: "%+.1f°", angle),
                 rect: CGRect(x: w * 0.188, y: middleY - fontSize * 0.65, width: w * 0.624, height: fontSize * 1.3),
                 font: .monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
                 color: numberColor(for: angle), context: c, compressHorizontally: true)
    }

    private static let referenceRed = UIColor(red: 1, green: 0.45, blue: 0.43, alpha: 1)

    private static func numberColor(for angle: Double) -> UIColor {
        if abs(angle) < 1 { return .systemGreen }
        return angle > 0 ? UIColor(red: 1, green: 0.72, blue: 0.25, alpha: 1) : .systemCyan
    }

    private static func drawText(_ text: String, rect: CGRect, font: UIFont, color: UIColor, context: CGContext, compressHorizontally: Bool = false) {
        // Core Text draws directly into this pixel-buffer context. UIKit string.draw
        // previously had no current UIGraphics context and never reached the video.
        func line(for font: UIFont) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        var textLine = line(for: font)
        let width = CGFloat(CTLineGetTypographicBounds(textLine, nil, nil, nil))
        var horizontalScale: CGFloat = 1
        if width > rect.width {
            if compressHorizontally {
                // Preserve the larger digit height in narrow portrait layouts;
                // only condense width enough to keep C's outer rulers clear.
                horizontalScale = rect.width / width
            } else {
                textLine = line(for: font.withSize(font.pointSize * rect.width / width))
            }
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let fittedWidth = CGFloat(CTLineGetTypographicBounds(textLine, &ascent, &descent, nil))
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: rect.midX - fittedWidth * horizontalScale / 2, y: rect.midY + (ascent - descent) / 2)
        context.scaleBy(x: horizontalScale, y: -1)
        CTLineDraw(textLine, context)
        context.restoreGState()
    }

    #if DEBUG
    func exportDiagnosticFrames() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let imageContext = CIContext()
        let angles = [0.0, 12.4, -12.4, 45.0]
        for (designIndex, design) in HUDDesign.allCases.enumerated() {
            for (index, angle) in angles.enumerated() {
                let timestamp = CMTime(value: Int64(designIndex * angles.count + index + 1), timescale: 1)
                guard let sample = makeSample(angle: angle, timestamp: timestamp, appState: "foreground", design: design),
                      let buffer = CMSampleBufferGetImageBuffer(sample),
                      let image = imageContext.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: width, height: height)),
                      let data = UIImage(cgImage: image).pngData() else { continue }
                let url = directory.appendingPathComponent("hud-\(design.rawValue)-\(index).png")
                do { try data.write(to: url); print("[AngleMonitor] exported \(url.lastPathComponent), angle=\(angle)") }
                catch { print("[AngleMonitor] export failed: \(error)") }
            }
            let image = UIGraphicsImageRenderer(size: CGSize(width: 345, height: 420)).image { context in
                Self.drawHUD(in: context.cgContext, size: CGSize(width: 345, height: 420), angle: 12.4, appState: "", design: design)
            }
            if let data = image.pngData() {
                try? data.write(to: directory.appendingPathComponent("hud-\(design.rawValue)-portrait.png"))
            }
        }
    }
    #endif
}
