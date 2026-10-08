import AppKit
import Foundation

@main
struct RenderAppIcon {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: render_app_icon <output-dir>\n", stderr)
            Foundation.exit(2)
        }

        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let entries: [(String, CGFloat)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024)
        ]

        for (name, size) in entries {
            let image = CatIconRenderer.restingAppIcon(size: size)
            try writePNG(image, to: output.appendingPathComponent(name))
        }
    }

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw NSError(domain: "RenderAppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode \(url.lastPathComponent)"])
        }

        try png.write(to: url)
    }
}
