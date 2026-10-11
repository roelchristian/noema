import AppKit

@main enum IconGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "NoemaIconGenerator", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Usage: icon-generator <output.iconset> <brand-output-directory>"])
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let brand = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
        // SwiftPM's .icns fallback deliberately retains the existing dark identity.
        let palette = NoemaBrandPalette(dark: true)
        let components: [(OrbitComponent, NoemaBrandRole)] = [(.orbit, .orbit), (.satellites, .satellites), (.nucleus, .nucleus)]
        let sizes = [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x")]
        for (size, name) in sizes {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            let context = NSGraphicsContext.current!.cgContext
            let s = CGFloat(size)
            context.translateBy(x: 0, y: s)
            context.scaleBy(x: 1, y: -1)
            let tile = CGRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
            context.setFillColor(color(palette.token(.identityBackground)))
            context.addPath(CGPath(roundedRect: tile, cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil))
            context.fillPath()
            for (component, role) in components {
                context.setFillColor(color(palette.token(role)))
                context.addPath(OrbitGeometry.path(in: CGRect(x: s * 0.12, y: s * 0.12, width: s * 0.76, height: s * 0.76), component: component))
                context.fillPath()
            }
            NSGraphicsContext.restoreGraphicsState()
            let png = bitmap.representation(using: .png, properties: [:])!
            try png.write(to: output.appendingPathComponent(name + ".png"))
            if size == 1024 { try png.write(to: brand.appendingPathComponent("icon-preview.png")) }
        }

        // Filled layers have no baked-in lighting or mask. The composed exports
        // demonstrate the complete identity; the separate layers remain reusable.
        for dark in [false, true] {
            let variant = NoemaBrandPalette(dark: dark)
            let suffix = dark ? "" : "-light"
            let appearance = dark ? "dark" : "light"
            let frame = CGRect(x: 123, y: 123, width: 778, height: 778)
            let paths = components.map { component, role in
                svgPath(path: OrbitGeometry.path(in: frame, component: component), fill: variant.token(role).hexString)
            }.joined()
            let title = "Noema \(dark ? "Midnight Iris" : "Porcelain Iris") identity"
            let foreground = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\"><title>\(title) foreground</title>\(paths)</svg>\n"
            try foreground.write(to: brand.appendingPathComponent("orbit" + suffix + ".svg"), atomically: true, encoding: .utf8)
            let backgroundRect = "<rect width=\"1024\" height=\"1024\" fill=\"\(variant.token(.identityBackground).hexString)\"/>"
            let background = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\">\(backgroundRect)</svg>\n"
            try background.write(to: brand.appendingPathComponent("background" + suffix + ".svg"), atomically: true, encoding: .utf8)
            let identity = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\"><title>\(title)</title>\(backgroundRect)\(paths)</svg>\n"
            try identity.write(to: brand.appendingPathComponent("identity-" + appearance + ".svg"), atomically: true, encoding: .utf8)

            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            let context = NSGraphicsContext.current!.cgContext
            context.translateBy(x: 0, y: 1024)
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(color(variant.token(.identityBackground)))
            context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
            for (component, role) in components {
                context.setFillColor(color(variant.token(role)))
                context.addPath(OrbitGeometry.path(in: frame, component: component))
                context.fillPath()
            }
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!
                .write(to: brand.appendingPathComponent("identity-" + appearance + ".png"))
        }
    }

    static func color(_ rgb: ThemeRGB) -> CGColor {
        NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1).cgColor
    }

    static func svgPath(path: CGPath, fill: String) -> String {
        var commands: [String] = []
        func point(_ p: CGPoint) -> String {
            String(format: "%.3f %.3f", locale: Locale(identifier: "en_US_POSIX"), Double(p.x), Double(p.y))
        }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint: commands.append("M" + point(e.points[0]))
            case .addLineToPoint: commands.append("L" + point(e.points[0]))
            case .addQuadCurveToPoint: commands.append("Q" + point(e.points[0]) + " " + point(e.points[1]))
            case .addCurveToPoint: commands.append("C" + point(e.points[0]) + " " + point(e.points[1]) + " " + point(e.points[2]))
            case .closeSubpath: commands.append("Z")
            @unknown default: break
            }
        }
        return "<path fill=\"\(fill)\" d=\"\(commands.joined(separator: " "))\"/>"
    }
}
