import AppKit
import SwiftUI

enum RemoteOSBranding {
    @MainActor
    static func applyDockIcon() {
        let size: CGFloat = 512
        let scale: CGFloat = 2
        let px = Int(size * scale)

        guard let ctx = CGContext(
            data: nil,
            width: px, height: px,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }

        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size)
        ctx.scaleBy(x: 1, y: -1)

        drawDockIcon(in: ctx, size: size)

        guard let cgImage = ctx.makeImage() else { return }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
        NSApplication.shared.applicationIconImage = nsImage
    }

    private static func drawDockIcon(in ctx: CGContext, size: CGFloat) {
        let cornerRadius: CGFloat = 118

        let bgPath = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
            cornerWidth: cornerRadius, cornerHeight: cornerRadius,
            transform: nil
        )
        ctx.saveGState()
        ctx.addPath(bgPath)
        ctx.clip()

        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 0.094, green: 0.094, blue: 0.106, alpha: 1),
                CGColor(red: 0.055, green: 0.055, blue: 0.067, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawLinearGradient(
            gradient,
            start: .zero,
            end: CGPoint(x: size, y: size),
            options: []
        )
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(bgPath)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
        ctx.setLineWidth(2)
        ctx.strokePath()
        ctx.restoreGState()

        let padding: CGFloat = 52
        let markSize = size - padding * 2

        let phoneWidth = markSize * 0.41
        let phoneHeight = markSize * 0.82
        let phoneX = padding + markSize * 0.11
        let phoneY = padding + markSize * 0.07

        let phoneRect = CGRect(x: phoneX, y: phoneY, width: phoneWidth, height: phoneHeight)
        let phoneRadius = phoneWidth * 0.3
        let phonePath = CGPath(
            roundedRect: phoneRect,
            cornerWidth: phoneRadius, cornerHeight: phoneRadius,
            transform: nil
        )
        ctx.setFillColor(CGColor(red: 0.953, green: 0.933, blue: 0.909, alpha: 1))
        ctx.addPath(phonePath)
        ctx.fillPath()

        let screenWidth = phoneWidth * 0.65
        let screenHeight = phoneHeight * 0.82
        let screenX = phoneX + phoneWidth * 0.175
        let screenY = phoneY + phoneHeight * 0.09
        let screenRadius = phoneWidth * 0.12
        let screenPath = CGPath(
            roundedRect: CGRect(x: screenX, y: screenY, width: screenWidth, height: screenHeight),
            cornerWidth: screenRadius, cornerHeight: screenRadius,
            transform: nil
        )
        ctx.setFillColor(CGColor(red: 0.078, green: 0.078, blue: 0.094, alpha: 1))
        ctx.addPath(screenPath)
        ctx.fillPath()

        let cursorSize = markSize * 0.44
        let cursorX = padding + markSize * 0.45
        let cursorY = padding + markSize * 0.27
        drawCursor(
            in: ctx,
            rect: CGRect(x: cursorX, y: cursorY, width: cursorSize, height: cursorSize),
            color: CGColor(red: 0.839, green: 0.667, blue: 0.608, alpha: 1)
        )
    }

    /// Draws the cursor mark matching the SVG logo path (24x24 coordinate space with bezier curves).
    static func drawCursor(in ctx: CGContext, rect: CGRect, color: CGColor) {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * (x / 24),
                y: rect.minY + rect.height * (y / 24)
            )
        }

        ctx.beginPath()
        ctx.move(to: pt(4, 3.5))
        ctx.addCurve(to: pt(3.5, 3.8), control1: pt(3.8, 3.5), control2: pt(3.6, 3.6))
        ctx.addCurve(to: pt(3.5, 4.4), control1: pt(3.4, 4), control2: pt(3.4, 4.2))
        ctx.addLine(to: pt(10, 19.5))
        ctx.addCurve(to: pt(10.7, 20), control1: pt(10.1, 19.8), control2: pt(10.4, 20))
        ctx.addCurve(to: pt(11.4, 19.5), control1: pt(11, 20), control2: pt(11.3, 19.8))
        ctx.addLine(to: pt(13, 13))
        ctx.addLine(to: pt(19.5, 11.4))
        ctx.addCurve(to: pt(20, 10.7), control1: pt(19.8, 11.3), control2: pt(20, 11))
        ctx.addCurve(to: pt(19.5, 10), control1: pt(20, 10.4), control2: pt(19.8, 10.1))
        ctx.addLine(to: pt(4.4, 3.5))
        ctx.addCurve(to: pt(4, 3.5), control1: pt(4.3, 3.5), control2: pt(4.15, 3.5))
        ctx.closePath()

        ctx.setFillColor(color)
        ctx.fillPath()
    }
}

// MARK: - Menu Bar Icon

struct RemoteOSMenuBarIcon: View {
    private static let cachedImage: NSImage = {
        let size: CGFloat = 18
        let scale: CGFloat = 2
        let px = Int(size * scale)

        guard let ctx = CGContext(
            data: nil,
            width: px, height: px,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            let fallback = NSImage(size: NSSize(width: size, height: size))
            fallback.isTemplate = true
            return fallback
        }

        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size)
        ctx.scaleBy(x: 1, y: -1)

        let fillColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        let phoneWidth = size * 0.38
        let phoneHeight = size * 0.78
        let phoneX = size * 0.04
        let phoneY = size * 0.06
        let phonePath = CGPath(
            roundedRect: CGRect(x: phoneX, y: phoneY, width: phoneWidth, height: phoneHeight),
            cornerWidth: phoneWidth * 0.3, cornerHeight: phoneWidth * 0.3,
            transform: nil
        )
        ctx.setStrokeColor(fillColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(phonePath)
        ctx.strokePath()

        let cursorSize = size * 0.62
        let cursorX = size * 0.34
        let cursorY = size * 0.18
        RemoteOSBranding.drawCursor(
            in: ctx,
            rect: CGRect(x: cursorX, y: cursorY, width: cursorSize, height: cursorSize),
            color: fillColor
        )

        guard let cgImage = ctx.makeImage() else {
            let fallback = NSImage(size: NSSize(width: size, height: size))
            fallback.isTemplate = true
            return fallback
        }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.cachedImage)
            .accessibilityLabel("RemoteOS")
    }
}
