import AppKit
import SwiftUI

/// Pixel-cat status faces, ported 1:1 from `pixel_cat_desktop.html`.
///
/// Each cat is drawn as a 64×64 pixel grid with a chromatic-aberration look:
/// three offset monochrome ghosts (blue / yellow / pink) under the real cat,
/// plus sparkles and a small vertical "bob". The question cat alternates
/// between two frames; the resting cat is procedural (ellipse/triangle/rect)
/// with a nod + sleep "Z".
struct PixelCat: View {
    let state: AgentState

    var body: some View {
        PixelCatFramePlayer(state: state)
            .aspectRatio(1, contentMode: .fit)
            .allowsHitTesting(false)
    }
}

/// Renders the exact existing Canvas frames once, then switches the cached
/// images in Core Animation. This preserves the original pixel art and 0.20s
/// cadence without invalidating the whole SwiftUI hierarchy five times a second.
private struct PixelCatFramePlayer: NSViewRepresentable {
    let state: AgentState

    func makeNSView(context: Context) -> PixelCatFramePlayerView {
        PixelCatFramePlayerView()
    }

    func updateNSView(_ view: PixelCatFramePlayerView, context: Context) {
        view.setState(state)
    }
}

@MainActor
private final class PixelCatFramePlayerView: NSView {
    private struct CacheKey: Hashable {
        let state: String
        let widthPixels: Int
        let heightPixels: Int
    }

    private static var frameCache: [CacheKey: [CGImage]] = [:]
    private let imageLayer = CALayer()
    private var state: AgentState = .offline
    private var renderedKey: CacheKey?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .nearest
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setState(_ state: AgentState) {
        guard self.state != state else { return }
        self.state = state
        renderedKey = nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let displayScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        let key = CacheKey(
            state: state.rawValue,
            widthPixels: Int((bounds.width * displayScale).rounded()),
            heightPixels: Int((bounds.height * displayScale).rounded())
        )
        guard renderedKey != key else { return }
        renderedKey = key

        let frames: [CGImage]
        if let cached = Self.frameCache[key] {
            frames = cached
        } else {
            frames = renderFrames(scale: displayScale)
            Self.frameCache[key] = frames
        }
        guard let first = frames.first else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contentsScale = displayScale
        imageLayer.contents = first
        CATransaction.commit()
        imageLayer.removeAnimation(forKey: "frames")

        let framePeriod = animationFramePeriod
        guard framePeriod > 1, frames.count == framePeriod else { return }

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.duration = Double(framePeriod) * 0.20
        animation.repeatCount = .infinity
        animation.calculationMode = .discrete
        animation.isRemovedOnCompletion = false
        let phase = Date().timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: animation.duration)
        animation.beginTime = CACurrentMediaTime() - phase
        imageLayer.add(animation, forKey: "frames")
    }

    private var animationFramePeriod: Int {
        switch state {
        case .working: return 16
        case .completed: return 18
        case .needsApproval, .error: return 72
        case .idle, .offline: return 1
        }
    }

    private func renderFrames(scale: CGFloat) -> [CGImage] {
        (0..<animationFramePeriod).compactMap { tick in
            let renderer = ImageRenderer(
                content: PixelCatFrame(state: state, tick: tick)
                    .frame(width: bounds.width, height: bounds.height)
            )
            renderer.scale = scale
            return renderer.cgImage
        }
    }
}

private struct PixelCatFrame: View {
    let state: AgentState
    let tick: Int

    var body: some View {
        Canvas { ctx, size in
            let scale = size.width / CGFloat(PixelCatArt.size)
            PixelCatArt.draw(state: state, tick: tick, ctx: ctx, scale: scale)
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
    }
}

// MARK: - Renderer

enum PixelCatArt {
    static let size = 64

    // Chromatic / accent colors (mirror COLORS in the HTML).
    static let cBlue = Color(catHex: "#2499f2")
    static let cYellow = Color(catHex: "#fff200")
    static let cPink = Color(catHex: "#c76ccc")
    static let cOrange = Color(catHex: "#ff7b2d")
    static let cWhite = Color(catHex: "#fffefd")
    static let cEye = Color(catHex: "#1f1f1f")
    static let cSleep = cBlue

    static func draw(state: AgentState, tick: Int, ctx: GraphicsContext, scale: CGFloat) {
        switch state {
        case .working:
            drawRuns(WorkingCat.runs, WorkingCat.palette, tick: tick, bobPeriod: 16, ctx: ctx, scale: scale)
            sparkle(ctx, 12, 17, cYellow, scale)
            sparkle(ctx, 47, 16, cOrange, scale)
            sparkle(ctx, 14, 48, cBlue, scale)
            sparkle(ctx, 49, 44, cPink, scale)

        case .completed:
            drawRuns(SmileCat.runs, SmileCat.palette, tick: tick, bobPeriod: 18, ctx: ctx, scale: scale)
            sparkle(ctx, 12, 17, cYellow, scale)
            sparkle(ctx, 47, 16, cOrange, scale)
            sparkle(ctx, 14, 48, cBlue, scale)
            sparkle(ctx, 49, 44, cPink, scale)

        case .needsApproval, .error:
            let frame = QuestionCat.frames[(tick / 4) % QuestionCat.frames.count]
            drawRuns(frame.runs, frame.palette, tick: tick, bobPeriod: 18, ctx: ctx, scale: scale)
            sparkle(ctx, 12, 17, cYellow, scale)
            sparkle(ctx, 47, 16, cOrange, scale)
            sparkle(ctx, 14, 48, cBlue, scale)
            sparkle(ctx, 49, 44, cPink, scale)
            sparkle(ctx, 10, 38, cYellow, scale)

        case .idle, .offline:
            drawResting(tick: tick, ctx: ctx, scale: scale)
        }
    }

    // MARK: Run-encoded cats (working / smile / question)

    private static func drawRuns(_ runs: [[Int]], _ palette: [Color],
                                 tick: Int, bobPeriod: Int,
                                 ctx: GraphicsContext, scale: CGFloat) {
        let bob = tick % bobPeriod < bobPeriod / 2 ? 0 : 1
        paintRuns(runs, palette, dx: -2, dy: 1 + bob, override: cBlue, ctx, scale)
        paintRuns(runs, palette, dx: 2, dy: 2 + bob, override: cYellow, ctx, scale)
        paintRuns(runs, palette, dx: -1, dy: 3 + bob, override: cPink, ctx, scale)
        paintRuns(runs, palette, dx: 0, dy: bob, override: nil, ctx, scale)
    }

    private static func paintRuns(_ runs: [[Int]], _ palette: [Color],
                                  dx: Int, dy: Int, override: Color?,
                                  _ ctx: GraphicsContext, _ scale: CGFloat) {
        for run in runs {
            let start = run[0], length = run[1], colorIndex = run[2]
            let color = override ?? palette[colorIndex]
            for offset in 0..<length {
                let index = start + offset
                fillPixel(ctx, index % size + dx, index / size + dy, color, scale)
            }
        }
    }

    // MARK: Resting cat (procedural)

    private static func drawResting(tick: Int, ctx: GraphicsContext, scale: CGFloat) {
        let phase = tick % 42
        let nod = (22...28).contains(phase) ? 3 : (phase == 29 || phase == 30) ? 1 : 0

        var grid = [[Bool]](repeating: [Bool](repeating: false, count: size), count: size)
        fillEllipse(&grid, 32, 34 + nod, 15, 13)
        fillRect(&grid, 22, 25 + nod, 21, 10)
        fillTriangle(&grid, 21, 27 + nod, 22, 17 + nod, 31, 26 + nod)
        fillTriangle(&grid, 34, 26 + nod, 44, 17 + nod, 43, 28 + nod)
        fillRect(&grid, 25, 45 + nod, 14, 1)

        // Chromatic ghosts + white body.
        paintGrid(grid, cBlue, dx: -2, dy: 1, ctx, scale)
        paintGrid(grid, cYellow, dx: 2, dy: 2, ctx, scale)
        paintGrid(grid, cPink, dx: -1, dy: 3, ctx, scale)
        paintGrid(grid, cWhite, dx: 0, dy: 0, ctx, scale)

        // Closed eyes.
        fillRectPx(ctx, 23, 34 + nod, 2, 4, cEye, scale)
        fillRectPx(ctx, 25, 38 + nod, 5, 2, cEye, scale)
        fillRectPx(ctx, 30, 36 + nod, 2, 2, cEye, scale)
        fillRectPx(ctx, 36, 36 + nod, 2, 2, cEye, scale)
        fillRectPx(ctx, 38, 38 + nod, 5, 2, cEye, scale)
        fillRectPx(ctx, 43, 34 + nod, 2, 4, cEye, scale)

        sparkle(ctx, 13, 18, cYellow, scale)
        sparkle(ctx, 47, 18, cPink, scale)
        sparkle(ctx, 15, 46, cOrange, scale)
        sparkle(ctx, 50, 42, cBlue, scale)
        sparkle(ctx, 33, 12, cYellow, scale)

        // Sleep "Z" bubble.
        if (18...30).contains(phase) {
            fillRectPx(ctx, 48, 24, 5, 1, cSleep, scale)
            fillRectPx(ctx, 52, 25, 1, 1, cSleep, scale)
            fillRectPx(ctx, 50, 26, 2, 1, cSleep, scale)
            fillRectPx(ctx, 48, 27, 1, 1, cSleep, scale)
            fillRectPx(ctx, 48, 28, 5, 1, cSleep, scale)
        }
    }

    // MARK: Pixel primitives

    private static func fillPixel(_ ctx: GraphicsContext, _ x: Int, _ y: Int, _ color: Color, _ scale: CGFloat) {
        guard x >= 0, x < size, y >= 0, y < size else { return }
        let step = ceil(scale)
        let rect = CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: step, height: step)
        ctx.fill(Path(rect), with: .color(color))
    }

    private static func fillRectPx(_ ctx: GraphicsContext, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: Color, _ scale: CGFloat) {
        for yy in y..<(y + h) {
            for xx in x..<(x + w) {
                fillPixel(ctx, xx, yy, color, scale)
            }
        }
    }

    private static func sparkle(_ ctx: GraphicsContext, _ x: Int, _ y: Int, _ color: Color, _ scale: CGFloat) {
        fillPixel(ctx, x + 1, y, color, scale)
        fillPixel(ctx, x, y + 1, color, scale)
        fillPixel(ctx, x + 1, y + 1, color, scale)
        fillPixel(ctx, x + 2, y + 1, color, scale)
        fillPixel(ctx, x + 1, y + 2, color, scale)
    }

    private static func paintGrid(_ grid: [[Bool]], _ color: Color, dx: Int, dy: Int, _ ctx: GraphicsContext, _ scale: CGFloat) {
        for y in 0..<size {
            for x in 0..<size where grid[y][x] {
                fillPixel(ctx, x + dx, y + dy, color, scale)
            }
        }
    }

    // MARK: Grid shape primitives (for the resting cat)

    private static func fillRect(_ grid: inout [[Bool]], _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        for yy in max(0, y)..<min(size, y + h) {
            for xx in max(0, x)..<min(size, x + w) {
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
                if dx * dx + dy * dy <= 1, y >= 0, y < size, x >= 0, x < size {
                    grid[y][x] = true
                }
            }
        }
    }

    private static func fillTriangle(_ grid: inout [[Bool]], _ ax: Int, _ ay: Int, _ bx: Int, _ by: Int, _ cx: Int, _ cy: Int) {
        let minX = max(0, min(ax, bx, cx)), maxX = min(size - 1, max(ax, bx, cx))
        let minY = max(0, min(ay, by, cy)), maxY = min(size - 1, max(ay, by, cy))
        let area = edge(ax, ay, bx, by, cx, cy)
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

    private static func edge(_ ax: Int, _ ay: Int, _ bx: Int, _ by: Int, _ cx: Int, _ cy: Int) -> Double {
        edge(Double(ax), Double(ay), Double(bx), Double(by), Double(cx), Double(cy))
    }

    private static func edge(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ px: Double, _ py: Double) -> Double {
        (px - ax) * (by - ay) - (py - ay) * (bx - ax)
    }
}

// MARK: - Pixel data

private struct CatFrame {
    let palette: [Color]
    let runs: [[Int]]
}

private enum WorkingCat {
    static let palette = ["#fffefd", "#2499f2", "#8198a3", "#b9ccd6", "#dff1f7", "#bee2ee", "#b5e3f2"].map(Color.init(catHex:))
    static let runs: [[Int]] = [[790,2,0],[854,3,0],[870,1,0],[917,4,0],[933,2,0],[981,5,0],[996,3,0],[1045,7,0],[1059,4,0],[1109,18,0],[1173,18,0],[1237,19,0],[1300,20,0],[1364,20,0],[1428,21,0],[1492,21,0],[1556,21,0],[1620,5,0],[1625,2,1],[1627,6,0],[1633,2,1],[1635,6,0],[1684,5,0],[1689,2,1],[1691,6,0],[1697,2,1],[1699,7,0],[1747,6,0],[1753,2,1],[1755,6,0],[1761,2,1],[1763,7,0],[1811,6,0],[1817,2,1],[1819,6,0],[1825,2,1],[1827,7,0],[1875,24,0],[1939,11,0],[1950,1,1],[1951,13,0],[2003,10,0],[2013,3,1],[2016,13,0],[2067,28,0],[2131,29,0],[2195,29,0],[2259,29,0],[2321,24,2],[2345,8,0],[2385,1,2],[2386,22,3],[2408,1,2],[2409,8,0],[2449,1,2],[2450,1,3],[2451,18,4],[2469,3,3],[2472,1,2],[2473,9,0],[2513,1,2],[2514,22,3],[2536,1,2],[2537,9,0],[2577,1,2],[2578,22,3],[2600,1,2],[2601,9,0],[2641,1,2],[2642,1,3],[2643,1,4],[2644,9,3],[2653,1,5],[2654,10,3],[2664,1,2],[2665,8,0],[2705,1,2],[2706,1,3],[2707,1,4],[2708,8,3],[2716,1,5],[2717,11,3],[2728,9,2],[2769,1,2],[2770,1,3],[2771,1,4],[2772,6,3],[2778,5,5],[2783,9,3],[2792,1,2],[2793,6,3],[2799,2,2],[2833,1,2],[2834,1,3],[2835,1,4],[2836,6,3],[2842,2,5],[2844,1,6],[2845,1,5],[2846,10,3],[2856,1,2],[2857,1,4],[2858,1,3],[2859,1,4],[2860,2,3],[2862,2,2],[2897,1,2],[2898,1,3],[2899,1,4],[2900,6,3],[2906,3,5],[2909,1,6],[2910,1,5],[2911,9,3],[2920,1,2],[2921,1,3],[2922,1,4],[2923,2,3],[2925,2,2],[2961,1,2],[2962,9,3],[2971,3,5],[2974,10,3],[2984,1,2],[2985,1,4],[2986,2,3],[2988,2,2],[3025,1,2],[3026,22,3],[3048,1,2],[3049,2,3],[3051,2,2],[3089,1,2],[3090,22,3],[3112,1,2],[3113,1,3],[3114,2,2],[3153,1,2],[3154,22,3],[3176,3,2],[3217,25,2]]
}

private enum SmileCat {
    static let palette = ["#fffefd", "#1f1f1f"].map(Color.init(catHex:))
    static let runs: [[Int]] = [[1196,1,0],[1236,1,0],[1259,2,0],[1300,3,0],[1322,3,0],[1364,4,0],[1372,9,0],[1385,4,0],[1428,5,0],[1434,13,0],[1448,5,0],[1492,25,0],[1556,25,0],[1620,25,0],[1684,26,0],[1748,26,0],[1811,27,0],[1875,28,0],[1938,5,0],[1943,4,1],[1947,10,0],[1957,4,1],[1961,6,0],[2002,4,0],[2006,6,1],[2012,8,0],[2020,6,1],[2026,5,0],[2066,3,0],[2069,3,1],[2072,2,0],[2074,3,1],[2077,6,0],[2083,3,1],[2086,2,0],[2088,3,1],[2091,4,0],[2130,3,0],[2133,2,1],[2135,4,0],[2139,2,1],[2141,6,0],[2147,2,1],[2149,4,0],[2153,2,1],[2155,4,0],[2193,4,0],[2197,2,1],[2199,4,0],[2203,2,1],[2205,6,0],[2211,2,1],[2213,4,0],[2217,2,1],[2219,4,0],[2258,3,0],[2261,2,1],[2263,4,0],[2267,2,1],[2269,6,0],[2275,2,1],[2277,4,0],[2281,2,1],[2283,4,0],[2322,29,0],[2386,29,0],[2450,29,0],[2515,27,0],[2579,27,0],[2644,26,0],[2709,23,0],[2774,21,0],[2839,19,0],[2905,15,0],[2972,9,0]]
}

private enum QuestionCat {
    static let frames: [CatFrame] = [
        CatFrame(
            palette: ["#fffefd", "#ff3b30", "#2499f2", "#1f1f1f"].map(Color.init(catHex:)),
            runs: [[1196,1,0],[1236,1,0],[1259,2,0],[1300,3,0],[1322,3,0],[1364,4,0],[1372,9,0],[1385,1,0],[1386,2,1],[1388,1,0],[1428,5,0],[1434,13,0],[1448,1,0],[1449,1,1],[1450,2,0],[1452,1,1],[1492,24,0],[1516,1,1],[1556,23,0],[1579,1,1],[1580,1,0],[1620,25,0],[1684,23,0],[1707,1,1],[1708,2,0],[1748,26,0],[1811,27,0],[1875,4,0],[1879,2,2],[1881,2,3],[1883,10,0],[1893,2,2],[1895,2,3],[1897,6,0],[1938,4,0],[1942,2,2],[1944,4,3],[1948,8,0],[1956,2,2],[1958,4,3],[1962,5,0],[2002,3,0],[2005,2,2],[2007,6,3],[2013,6,0],[2019,2,2],[2021,6,3],[2027,4,0],[2066,3,0],[2069,2,2],[2071,2,3],[2073,1,0],[2074,3,3],[2077,6,0],[2083,2,2],[2085,2,3],[2087,1,0],[2088,3,3],[2091,4,0],[2130,3,0],[2133,2,2],[2135,2,3],[2137,1,0],[2138,3,3],[2141,6,0],[2147,2,2],[2149,2,3],[2151,1,0],[2152,3,3],[2155,4,0],[2193,4,0],[2197,2,2],[2199,6,3],[2205,6,0],[2211,2,2],[2213,6,3],[2219,4,0],[2258,3,0],[2261,2,2],[2263,6,3],[2269,6,0],[2275,2,2],[2277,6,3],[2283,4,0],[2322,4,0],[2326,2,2],[2328,4,3],[2332,8,0],[2340,2,2],[2342,4,3],[2346,5,0],[2386,5,0],[2391,2,2],[2393,2,3],[2395,10,0],[2405,2,2],[2407,2,3],[2409,6,0],[2450,29,0],[2515,27,0],[2579,27,0],[2644,26,0],[2709,23,0],[2774,21,0],[2839,19,0],[2905,15,0],[2972,9,0]]
        ),
        CatFrame(
            palette: ["#fffefd", "#ff3b30", "#1f1f1f", "#2499f2"].map(Color.init(catHex:)),
            runs: [[1196,1,0],[1236,1,0],[1259,2,0],[1300,3,0],[1322,3,0],[1364,4,0],[1372,9,0],[1385,4,0],[1428,5,0],[1434,13,0],[1448,2,0],[1450,2,1],[1452,1,0],[1492,21,0],[1513,1,1],[1514,2,0],[1516,1,1],[1556,21,0],[1577,1,1],[1578,2,0],[1580,1,1],[1620,23,0],[1643,1,1],[1644,1,0],[1684,26,0],[1748,23,0],[1771,1,1],[1772,2,0],[1811,27,0],[1875,4,0],[1879,2,2],[1881,2,3],[1883,10,0],[1893,2,2],[1895,2,3],[1897,6,0],[1938,4,0],[1942,4,2],[1946,2,3],[1948,8,0],[1956,4,2],[1960,2,3],[1962,5,0],[2002,3,0],[2005,6,2],[2011,2,3],[2013,6,0],[2019,6,2],[2025,2,3],[2027,4,0],[2066,3,0],[2069,4,2],[2073,1,0],[2074,1,2],[2075,2,3],[2077,6,0],[2083,4,2],[2087,1,0],[2088,1,2],[2089,2,3],[2091,4,0],[2130,3,0],[2133,4,2],[2137,1,0],[2138,1,2],[2139,2,3],[2141,6,0],[2147,4,2],[2151,1,0],[2152,1,2],[2153,2,3],[2155,4,0],[2193,4,0],[2197,6,2],[2203,2,3],[2205,6,0],[2211,6,2],[2217,2,3],[2219,4,0],[2258,3,0],[2261,6,2],[2267,2,3],[2269,6,0],[2275,6,2],[2281,2,3],[2283,4,0],[2322,4,0],[2326,4,2],[2330,2,3],[2332,8,0],[2340,4,2],[2344,2,3],[2346,5,0],[2386,5,0],[2391,2,2],[2393,2,3],[2395,10,0],[2405,2,2],[2407,2,3],[2409,6,0],[2450,29,0],[2515,27,0],[2579,27,0],[2644,26,0],[2709,23,0],[2774,21,0],[2839,19,0],[2905,15,0],[2972,9,0]]
        )
    ]
}

private extension Color {
    /// Parse a `#rrggbb` string into a Color.
    init(catHex hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        self = Color(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
