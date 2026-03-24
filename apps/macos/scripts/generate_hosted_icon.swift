#!/usr/bin/swift

import AppKit
import CoreGraphics
import Foundation

struct HostedIconGenerator {
    let outputPath: String

    func run() throws {
        let outputURL = URL(fileURLWithPath: outputPath)
        let fm = FileManager.default

        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }

        let workingDirectory = outputURL.deletingPathExtension()
        let iconsetURL = workingDirectory.appendingPathExtension("iconset")

        if fm.fileExists(atPath: iconsetURL.path) {
            try fm.removeItem(at: iconsetURL)
        }

        try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

        let representations: [(String, CGFloat)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024),
        ]

        for (filename, size) in representations {
            let image = drawIcon(size: size)
            let destination = iconsetURL.appendingPathComponent(filename)
            try savePNG(image: image, to: destination)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "HostedIconGenerator", code: Int(process.terminationStatus))
        }

        try fm.removeItem(at: iconsetURL)
    }

    private func drawIcon(size: CGFloat) -> NSImage {
        let scale: CGFloat = 2
        let pixelSize = Int(size * scale)

        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return NSImage(size: NSSize(width: size, height: size))
        }

        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size)
        context.scaleBy(x: 1, y: -1)

        let cornerRadius = size * 0.23
        let background = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        context.saveGState()
        context.addPath(background)
        context.clip()

        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 0.094, green: 0.094, blue: 0.106, alpha: 1),
                CGColor(red: 0.055, green: 0.055, blue: 0.067, alpha: 1)
            ] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(
            gradient,
            start: .zero,
            end: CGPoint(x: size, y: size),
            options: []
        )
        context.restoreGState()

        context.saveGState()
        context.addPath(background)
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
        context.setLineWidth(max(1.5, size * 0.004))
        context.strokePath()
        context.restoreGState()

        let padding = size * 0.1015
        let markSize = size - padding * 2

        let phoneWidth = markSize * 0.41
        let phoneHeight = markSize * 0.82
        let phoneX = padding + markSize * 0.11
        let phoneY = padding + markSize * 0.07

        let phoneRect = CGRect(x: phoneX, y: phoneY, width: phoneWidth, height: phoneHeight)
        let phoneRadius = phoneWidth * 0.3
        let phonePath = CGPath(
            roundedRect: phoneRect,
            cornerWidth: phoneRadius,
            cornerHeight: phoneRadius,
            transform: nil
        )
        context.setFillColor(CGColor(red: 0.953, green: 0.933, blue: 0.909, alpha: 1))
        context.addPath(phonePath)
        context.fillPath()

        let screenWidth = phoneWidth * 0.65
        let screenHeight = phoneHeight * 0.82
        let screenX = phoneX + phoneWidth * 0.175
        let screenY = phoneY + phoneHeight * 0.09
        let screenRadius = phoneWidth * 0.12
        let screenPath = CGPath(
            roundedRect: CGRect(x: screenX, y: screenY, width: screenWidth, height: screenHeight),
            cornerWidth: screenRadius,
            cornerHeight: screenRadius,
            transform: nil
        )
        context.setFillColor(CGColor(red: 0.078, green: 0.078, blue: 0.094, alpha: 1))
        context.addPath(screenPath)
        context.fillPath()

        let cursorSize = markSize * 0.44
        let cursorX = padding + markSize * 0.45
        let cursorY = padding + markSize * 0.27
        drawCursor(
            in: context,
            rect: CGRect(x: cursorX, y: cursorY, width: cursorSize, height: cursorSize),
            color: CGColor(red: 0.839, green: 0.667, blue: 0.608, alpha: 1)
        )

        guard let cgImage = context.makeImage() else {
            return NSImage(size: NSSize(width: size, height: size))
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    private func drawCursor(in context: CGContext, rect: CGRect, color: CGColor) {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * (x / 24),
                y: rect.minY + rect.height * (y / 24)
            )
        }

        context.beginPath()
        context.move(to: point(4, 3.5))
        context.addCurve(to: point(3.5, 3.8), control1: point(3.8, 3.5), control2: point(3.6, 3.6))
        context.addCurve(to: point(3.5, 4.4), control1: point(3.4, 4), control2: point(3.4, 4.2))
        context.addLine(to: point(10, 19.5))
        context.addCurve(to: point(10.7, 20), control1: point(10.1, 19.8), control2: point(10.4, 20))
        context.addCurve(to: point(11.4, 19.5), control1: point(11, 20), control2: point(11.3, 19.8))
        context.addLine(to: point(13, 13))
        context.addLine(to: point(19.5, 11.4))
        context.addCurve(to: point(20, 10.7), control1: point(19.8, 11.3), control2: point(20, 11))
        context.addCurve(to: point(19.5, 10), control1: point(20, 10.4), control2: point(19.8, 10.1))
        context.addLine(to: point(4.4, 3.5))
        context.addCurve(to: point(4, 3.5), control1: point(4.3, 3.5), control2: point(4.15, 3.5))
        context.closePath()

        context.setFillColor(color)
        context.fillPath()
    }

    private func savePNG(image: NSImage, to url: URL) throws {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            throw NSError(domain: "HostedIconGenerator", code: 2)
        }

        try png.write(to: url)
    }
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_hosted_icon.swift /path/to/RemoteOS.icns\n", stderr)
    exit(64)
}

do {
    try HostedIconGenerator(outputPath: CommandLine.arguments[1]).run()
} catch {
    fputs("failed to generate icon: \(error)\n", stderr)
    exit(1)
}
