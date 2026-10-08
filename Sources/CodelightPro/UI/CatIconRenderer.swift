import AppKit

enum CatIconRenderer {
    private static let gridSize = 64

    static func restingAppIcon(size: CGFloat) -> NSImage {
        drawIcon(size: size, background: .rounded)
    }

    /// Same icon for the iPhone app. iOS masks the corners itself and rejects
    /// transparent icons, so the background fills the whole square.
    static func iOSAppIcon(size: CGFloat) -> NSImage {
        drawIcon(size: size, background: .fullBleed)
    }

    static func restingMenuBarIcon(size: CGFloat = 18) -> NSImage {
        let image = drawIcon(size: size, background: .none)
        image.isTemplate = false
        return image
    }

    private enum Background {
        case none, rounded, fullBleed
    }

    private static func drawIcon(size: CGFloat, background: Background) -> NSImage {
        let includeBackground = background != .none
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .none
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()

        if includeBackground {
            let corner = background == .rounded ? size * 0.22 : 0
            let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                                  xRadius: corner,
                                  yRadius: corner)
            NSColor(calibratedRed: 0.035, green: 0.038, blue: 0.052, alpha: 1).setFill()
            bg.fill()

            let inner = NSBezierPath(roundedRect: NSRect(x: size * 0.075, y: size * 0.075, width: size * 0.85, height: size * 0.85),
                                     xRadius: size * 0.18,
                                     yRadius: size * 0.18)
            NSColor(calibratedRed: 0.09, green: 0.105, blue: 0.14, alpha: 1).setStroke()
            inner.lineWidth = max(1, size * 0.01)
            inner.stroke()
        }

        let inset = includeBackground ? size * 0.11 : 0
        let catSize = size - inset * 2
        let scale = catSize / CGFloat(gridSize)
        let origin = CGPoint(x: inset, y: inset)

        var grid = [[Bool]](repeating: [Bool](repeating: false, count: gridSize), count: gridSize)
        fillEllipse(&grid, 32, 34, 15, 13)
        fillRect(&grid, 22, 25, 21, 10)
        fillTriangle(&grid, 21, 27, 22, 17, 31, 26)
        fillTriangle(&grid, 34, 26, 44, 17, 43, 28)
        fillRect(&grid, 25, 45, 14, 1)

        paintGrid(grid, color: color("#2499f2"), dx: -2, dy: 1, origin: origin, scale: scale)
        paintGrid(grid, color: color("#fff200"), dx: 2, dy: 2, origin: origin, scale: scale)
        paintGrid(grid, color: color("#c76ccc"), dx: -1, dy: 3, origin: origin, scale: scale)
        paintGrid(grid, color: color("#fffefd"), dx: 0, dy: 0, origin: origin, scale: scale)

        let eye = color("#1f1f1f")
        fillRectPx(23, 34, 2, 4, eye, origin: origin, scale: scale)
        fillRectPx(25, 38, 5, 2, eye, origin: origin, scale: scale)
        fillRectPx(30, 36, 2, 2, eye, origin: origin, scale: scale)
        fillRectPx(36, 36, 2, 2, eye, origin: origin, scale: scale)
        fillRectPx(38, 38, 5, 2, eye, origin: origin, scale: scale)
        fillRectPx(43, 34, 2, 4, eye, origin: origin, scale: scale)

        sparkle(13, 18, color("#fff200"), origin: origin, scale: scale)
        sparkle(47, 18, color("#c76ccc"), origin: origin, scale: scale)
        sparkle(15, 46, color("#ff7b2d"), origin: origin, scale: scale)
        sparkle(50, 42, color("#2499f2"), origin: origin, scale: scale)
        sparkle(33, 12, color("#fff200"), origin: origin, scale: scale)

        let sleep = color("#2499f2")
        fillRectPx(48, 24, 5, 1, sleep, origin: origin, scale: scale)
        fillRectPx(52, 25, 1, 1, sleep, origin: origin, scale: scale)
        fillRectPx(50, 26, 2, 1, sleep, origin: origin, scale: scale)
        fillRectPx(48, 27, 1, 1, sleep, origin: origin, scale: scale)
        fillRectPx(48, 28, 5, 1, sleep, origin: origin, scale: scale)

        return image
    }

    private static func fillPixel(_ x: Int, _ y: Int, _ color: NSColor, origin: CGPoint, scale: CGFloat) {
        guard x >= 0, x < gridSize, y >= 0, y < gridSize else { return }
        color.setFill()
        let rect = NSRect(
            x: origin.x + CGFloat(x) * scale,
            y: origin.y + CGFloat(gridSize - y - 1) * scale,
            width: ceil(scale),
            height: ceil(scale)
        )
        rect.fill()
    }

    private static func fillRectPx(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: NSColor, origin: CGPoint, scale: CGFloat) {
        for yy in y..<(y + h) {
            for xx in x..<(x + w) {
                fillPixel(xx, yy, color, origin: origin, scale: scale)
            }
        }
    }

    private static func sparkle(_ x: Int, _ y: Int, _ color: NSColor, origin: CGPoint, scale: CGFloat) {
        fillPixel(x + 1, y, color, origin: origin, scale: scale)
        fillPixel(x, y + 1, color, origin: origin, scale: scale)
        fillPixel(x + 1, y + 1, color, origin: origin, scale: scale)
        fillPixel(x + 2, y + 1, color, origin: origin, scale: scale)
        fillPixel(x + 1, y + 2, color, origin: origin, scale: scale)
    }

    private static func paintGrid(_ grid: [[Bool]], color: NSColor, dx: Int, dy: Int, origin: CGPoint, scale: CGFloat) {
        for y in 0..<gridSize {
            for x in 0..<gridSize where grid[y][x] {
                fillPixel(x + dx, y + dy, color, origin: origin, scale: scale)
            }
        }
    }

    private static func fillRect(_ grid: inout [[Bool]], _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        for yy in max(0, y)..<min(gridSize, y + h) {
            for xx in max(0, x)..<min(gridSize, x + w) {
                grid[yy][xx] = true
            }
        }
    }

    private static func fillEllipse(_ grid: inout [[Bool]], _ cx: Int, _ cy: Int, _ rx: Int, _ ry: Int) {
        let fcx = Double(cx), fcy = Double(cy), frx = Double(rx), fry = Double(ry)
        for y in Int(floor(fcy - fry))...Int(ceil(fcy + fry)) {
            for x in Int(floor(fcx - frx))...Int(ceil(fcx + frx)) {
                let dx = (Double(x) - fcx) / frx
                let dy = (Double(y) - fcy) / fry
                if dx * dx + dy * dy <= 1, y >= 0, y < gridSize, x >= 0, x < gridSize {
                    grid[y][x] = true
                }
            }
        }
    }

    private static func fillTriangle(_ grid: inout [[Bool]], _ ax: Int, _ ay: Int, _ bx: Int, _ by: Int, _ cx: Int, _ cy: Int) {
        let minX = max(0, min(ax, bx, cx)), maxX = min(gridSize - 1, max(ax, bx, cx))
        let minY = max(0, min(ay, by, cy)), maxY = min(gridSize - 1, max(ay, by, cy))
        let area = edge(Double(ax), Double(ay), Double(bx), Double(by), Double(cx), Double(cy))
        for y in minY...maxY {
            for x in minX...maxX {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let a = edge(Double(bx), Double(by), Double(cx), Double(cy), px, py)
                let b = edge(Double(cx), Double(cy), Double(ax), Double(ay), px, py)
                let c = edge(Double(ax), Double(ay), Double(bx), Double(by), px, py)
                if (area >= 0 && a >= 0 && b >= 0 && c >= 0) || (area < 0 && a <= 0 && b <= 0 && c <= 0) {
                    grid[y][x] = true
                }
            }
        }
    }

    private static func edge(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ px: Double, _ py: Double) -> Double {
        (px - ax) * (by - ay) - (py - ay) * (bx - ax)
    }

    private static func color(_ hex: String) -> NSColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}
