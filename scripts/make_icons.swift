#!/usr/bin/env swift
// Original static artwork. AppKit runs on the Mac only; no Swift code is shipped.
import AppKit
import Foundation

let staticLaunch = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--static-ipad12-launch"
guard CommandLine.arguments.count == 2 || staticLaunch else {
    fputs("Usage: make_icons.swift <destination-directory> [--static-ipad12-launch]\n", stderr)
    exit(2)
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let icons: [(String, Int)] = [
        ("Icon-76.png", 76),
        ("Icon-76@2x.png", 152),
        ("Icon-83.5@2x.png", 167)
    ]
    for (name, pixels) in icons {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "MiniStreamIcons", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create icon bitmap."])
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let bounds = NSRect(x: 0, y: 0, width: 1024, height: 1024)
        NSColor(srgbRed: 0.035, green: 0.055, blue: 0.082, alpha: 1).setFill()
        bounds.fill()
        NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.19, blue: 0.25, alpha: 1),
                   ending: NSColor(srgbRed: 0.035, green: 0.055, blue: 0.082, alpha: 1))!
            .draw(in: bounds, angle: -45)

        let screen = NSBezierPath(roundedRect: NSRect(x: 195, y: 250, width: 634, height: 524),
                                  xRadius: 116, yRadius: 116)
        NSColor(srgbRed: 0.29, green: 0.73, blue: 0.76, alpha: 0.17).setFill()
        screen.fill()
        NSColor(srgbRed: 0.45, green: 0.85, blue: 0.83, alpha: 0.65).setStroke()
        screen.lineWidth = 20
        screen.stroke()

        let play = NSBezierPath()
        play.move(to: NSPoint(x: 435, y: 374))
        play.line(to: NSPoint(x: 435, y: 650))
        play.line(to: NSPoint(x: 658, y: 512))
        play.close()
        NSColor(srgbRed: 0.81, green: 0.97, blue: 0.95, alpha: 1).setFill()
        play.fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "MiniStreamIcons", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG."])
        }
        try png.write(to: destination.appendingPathComponent(name), options: .atomic)
        print("Generated \(name) (\(pixels) × \(pixels))")
    }
    if staticLaunch {
        // UILaunchImageSize remains portrait POINTS for either orientation.
        // Actual Retina PNGs use orientation-specific pixel dimensions.
        for (name, width, height) in [
            ("MiniStreamLaunchPortrait@2x.png", 1536, 2048),
            ("MiniStreamLaunchLandscape@2x.png", 2048, 1536)
        ] {
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 24
            ), let pixels = bitmap.bitmapData else {
                throw NSError(domain: "MiniStreamLaunch", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not create launch bitmap."])
            }
            // Fill opaque RGB directly: Core Graphics drawing contexts do not
            // accept every three-channel NSBitmapImageRep configuration.
            for row in 0..<height {
                let rowStart = pixels.advanced(by: row * bitmap.bytesPerRow)
                for column in 0..<width {
                    rowStart[column * 3] = 17
                    rowStart[column * 3 + 1] = 18
                    rowStart[column * 3 + 2] = 23
                }
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "MiniStreamLaunch", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Could not encode launch PNG."])
            }
            try png.write(to: destination.appendingPathComponent(name), options: .atomic)
            print("Generated \(name) (\(width) × \(height))")
        }
        let infoURL = destination.appendingPathComponent("Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        guard var info = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any],
              info["UIDeviceFamily"] as? [Int] == [2],
              info["MinimumOSVersion"] as? String == "12.0" else {
            throw NSError(domain: "MiniStreamLaunch", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Static launch mode requires the prepared iPad/iOS 12 Info.plist."])
        }
        let orientations = ["Portrait", "PortraitUpsideDown", "LandscapeLeft", "LandscapeRight"]
        let expectedOrientations = Set(orientations.map { "UIInterfaceOrientation" + $0 })
        guard Set(info["UISupportedInterfaceOrientations~ipad"] as? [String] ?? []) == expectedOrientations else {
            throw NSError(domain: "MiniStreamLaunch", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Static mode must preserve all four iPad orientations."])
        }
        let entries: [[String: String]] = orientations.map { orientation in
            ["UILaunchImageName": orientation.hasPrefix("Portrait") ? "MiniStreamLaunchPortrait" : "MiniStreamLaunchLandscape",
             "UILaunchImageMinimumOSVersion": "12.0",
             "UILaunchImageSize": "{768, 1024}",
             "UILaunchImageOrientation": orientation]
        }
        info.removeValue(forKey: "UILaunchStoryboardName")
        info.removeValue(forKey: "UILaunchStoryboards")
        info["UILaunchImages"] = entries
        info["UILaunchImages~ipad"] = entries
        // Static images cannot enable iOS 9+ iPad multitasking. This is an
        // explicit, device-only opt-in; orientation support is unchanged.
        info["UIRequiresFullScreen"] = true
        let updated = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try updated.write(to: infoURL, options: .atomic)
        print("Configured legacy iPad launch images: full canvas/all orientations; no Slide Over or Split View.")
    }
} catch {
    fputs("Icon generation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
