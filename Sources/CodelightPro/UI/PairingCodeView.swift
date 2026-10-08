import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The pairing QR code, staged like Apple Watch pairing in one continuous
/// sequence: a slowly turning 3D cloud of monochrome particles forms first,
/// the particles that belong to the code peel off and condense onto a light
/// card, rippling out from the centre, and the rest of the cloud keeps turning
/// behind the card. When `pairedAt` is set every particle — the code's dots
/// and the cloud — is thrown out by a shock wave and springs back into a
/// check mark drawn as an even dot matrix.
///
/// The settled code is still a standard QR code — square finder patterns,
/// dark dots on a light card — because the iPhone scans it with
/// `AVCaptureMetadataOutput`, which does not reliably read inverted codes.
///
/// Only on screen while the phone sync window is open, so it redraws with a
/// SwiftUI Canvas rather than the Core Animation used for always-on effects.
struct PairingCodeView: View {
    let payload: String?
    let pairedAt: Date?
    var side: CGFloat = 300

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scene = PairingScene(code: nil)
    @State private var cloudStart = Date()
    @State private var codeStart = Date()

    var body: some View {
        TimelineView(.animation) { context in
            Canvas(rendersAsynchronously: true) { ctx, size in
                let now = context.date
                let still = reduceMotion
                let frame = PairingCodeArt.Frame(
                    cloud: still ? 60 : now.timeIntervalSince(cloudStart),
                    code: still ? 60 : now.timeIntervalSince(codeStart),
                    clock: still ? 0 : now.timeIntervalSinceReferenceDate,
                    success: pairedAt.map { still ? 60 : now.timeIntervalSince($0) }
                )
                PairingCodeArt.draw(in: &ctx, size: size, scene: scene, frame: frame)
            }
        }
        .frame(width: side, height: side)
        .onAppear {
            cloudStart = Date()
            // Let the cloud turn on its own for a moment before the code forms.
            rebuild(payload, after: 0.5)
        }
        // Use the value handed to the closure: `self.payload` in here still
        // reads the previous render's value, so the code would never form.
        .onChange(of: payload) { newPayload in rebuild(newPayload, after: 0) }
        // After a success preview the cloud re-forms and the code assembles again.
        .onChange(of: pairedAt) { date in
            guard date == nil else { return }
            cloudStart = Date()
            rebuild(payload, after: 0.5)
        }
        .accessibilityLabel(pairedAt == nil ? "配对二维码" : "已连接 iPhone")
    }

    private func rebuild(_ payload: String?, after delay: TimeInterval) {
        scene = PairingScene(code: payload.flatMap(QRMatrix.init(text:)))
        codeStart = Date().addingTimeInterval(delay)
    }
}

// MARK: - QR modules

struct QRMatrix: Equatable {
    /// Modules per side, quiet zone excluded.
    let count: Int
    let dark: [Bool]

    init?(text: String) {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // Round dots cover less of each module than squares; the higher
        // correction level keeps the code easy to read anyway.
        filter.correctionLevel = "Q"
        guard let image = filter.outputImage,
              let cg = CIContext(options: [.useSoftwareRenderer: true])
                .createCGImage(image, from: image.extent.integral) else { return nil }

        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // Trim the generator's quiet zone. Buffer row 0 is the image's top row.
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] < 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxX - minX == maxY - minY else { return nil }
        let n = maxX - minX + 1
        var dark = [Bool](repeating: false, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                dark[y * n + x] = pixels[(minY + y) * width + (minX + x)] < 128
            }
        }
        self.count = n
        self.dark = dark
    }

    func isDark(_ x: Int, _ y: Int) -> Bool { dark[y * count + x] }

    /// Inside one of the three 7×7 finder patterns (drawn separately).
    func isFinder(_ x: Int, _ y: Int) -> Bool {
        let far = count - 7
        return (x < 7 && y < 7) || (x >= far && y < 7) || (x < 7 && y >= far)
    }
}

// MARK: - Particles

/// Everything about the particles that does not change from frame to frame.
struct PairingScene {
    struct Particle {
        /// Unit direction on the sphere.
        let dir: SIMD3<Double>
        /// Distance from the centre as a fraction of the sphere radius.
        let radius: Double
        /// Glow core diameter in points, before perspective.
        let size: Double
        let tint: Int
        /// 0..<1, staggers per-particle timing and twinkle.
        let seed: Double
        /// Module centre relative to the code's centre, in modules; nil for the halo.
        let target: CGPoint?
        /// Seconds after the code starts assembling that this dot takes off.
        let delay: Double
        /// The check mark dot this particle flies into on success.
        var checkSlot = 0
        /// Exactly one particle per check dot becomes it; the rest dissolve into it.
        var leads = false
    }

    static let haloCount = 900

    let code: QRMatrix?
    let halo: [Particle]
    let dots: [Particle]

    init(code: QRMatrix?) {
        typealias Art = PairingCodeArt
        self.code = code

        // Fibonacci sphere: an even shell, plus some particles scattered
        // inside it so the cloud has volume.
        let golden = Double.pi * (3 - sqrt(5))
        let total = Double(Self.haloCount)
        var halo: [Particle] = (0..<Self.haloCount).map { i in
            let y = 1 - 2 * (Double(i) + 0.5) / total
            let ring = sqrt(max(0, 1 - y * y))
            let phi = Double(i) * golden
            let shell = Art.rand(i, 1) < 0.72
            return Particle(
                dir: SIMD3(cos(phi) * ring, y, sin(phi) * ring),
                radius: shell ? 0.84 + 0.16 * Art.rand(i, 2) : 0.3 + 0.5 * Art.rand(i, 2),
                size: 1.0 + 1.6 * pow(Art.rand(i, 3), 2),
                tint: Int(Art.rand(i, 4) * Double(Art.tintCount)) % Art.tintCount,
                seed: Art.rand(i, 5),
                target: nil,
                delay: 0
            )
        }

        var dots: [Particle] = []
        if let code {
            let n = code.count
            let half = Double(n - 1) / 2
            let maxDistance = hypot(half, half)
            for y in 0..<n {
                for x in 0..<n where code.isDark(x, y) && !code.isFinder(x, y) {
                    let i = 10_000 + y * n + x
                    let z = Art.rand(i, 1) * 2 - 1
                    let phi = Art.rand(i, 2) * 2 * .pi
                    let ring = sqrt(max(0, 1 - z * z))
                    let target = CGPoint(x: Double(x) - half, y: Double(y) - half)
                    // Ripple out from the centre of the code.
                    let distance = hypot(target.x, target.y) / maxDistance
                    dots.append(Particle(
                        dir: SIMD3(cos(phi) * ring, z, sin(phi) * ring),
                        radius: 0.78 + 0.22 * Art.rand(i, 3),
                        size: 1.3 + 1.0 * Art.rand(i, 4),
                        tint: Int(Art.rand(i, 5) * Double(Art.tintCount)) % Art.tintCount,
                        seed: Art.rand(i, 6),
                        target: target,
                        delay: 0.8 + 0.5 * distance + 0.12 * Art.rand(i, 8)
                    ))
                }
            }
        }

        // Deal the check mark's dots out evenly: code dots first (in random
        // order, so the leaders come from all over the code), then the cloud.
        // Every dot gets one leader and the same share of followers.
        let slots = Art.checkSlotCount
        var k = 0
        for i in dots.indices.sorted(by: { dots[$0].seed < dots[$1].seed }) {
            dots[i].checkSlot = (k * 7919) % slots
            dots[i].leads = k < slots
            k += 1
        }
        for i in halo.indices {
            halo[i].checkSlot = (k * 7919) % slots
            halo[i].leads = k < slots
            k += 1
        }
        self.halo = halo
        self.dots = dots
    }
}

// MARK: - Drawing

enum PairingCodeArt {
    struct Frame {
        /// Seconds since the particle cloud started forming.
        let cloud: Double
        /// Seconds since the current code started assembling; negative before.
        let code: Double
        /// Wall clock, drives rotation and twinkle.
        let clock: Double
        /// Seconds since pairing succeeded.
        let success: Double?
    }

    /// White to mid grey; the variety reads as depth rather than colour.
    private static let tints: [RGB] = [
        RGB(r: 0.97, g: 0.97, b: 0.98),
        RGB(r: 0.82, g: 0.83, b: 0.85),
        RGB(r: 0.64, g: 0.65, b: 0.67),
        RGB(r: 0.48, g: 0.49, b: 0.51),
    ]
    static var tintCount: Int { tints.count }

    private static let ink = RGB(r: 0.07, g: 0.07, b: 0.08)
    private static let card = Color(red: 0.965, green: 0.965, blue: 0.97)

    /// Pre-rendered glow sprites, one per tint. Blitting a bitmap is far
    /// cheaper than filling a gradient per particle.
    private static let sprites: [CGImage] = tints.compactMap(makeSprite)

    // Code assembly timing, seconds after the code starts.
    private static let dotAppear = 0.45
    private static let dotFlight = 0.65
    private static let cardIn = 0.7...1.15
    private static let finderIn = 0.95...1.4

    /// Pitch and diameter of the finished mark's dots, as fractions of the view side.
    private static let checkPitch = 0.014
    private static let checkDot = checkPitch * 0.3

    // MARK: Check mark

    private struct CheckMark {
        struct Cell {
            /// In units of the view side from the centre.
            let point: CGPoint
            /// Fill order: along the check from the short arm's tip (0) to the
            /// long arm's tip (1), or clockwise from the top around the ring.
            let u: Double
        }

        let cells: [Cell]
    }

    /// The finished mark as an even dot matrix: a check inside a ring.
    /// The check's two strokes are perpendicular, so one square lattice
    /// turned 45° holds both — an L of two seven-row bars — and the ring is
    /// three staggered rows at the same pitch.
    private static let mark: CheckMark = {
        let short = 10, long = 23, lanes = 3
        let shortShare = Double(short) / Double(short + long)
        // The check sits on a finer lattice than the ring, so it stays small
        // inside it without losing dots.
        let r = checkPitch * 0.7 / 2.0.squareRoot()
        // i runs down-right along the short arm, j up-right along the long
        // one; the corner of the check is (0, 0).
        func lattice(_ i: Int, _ j: Int) -> CGPoint { CGPoint(x: Double(i + j) * r, y: Double(i - j) * r) }
        func shortU(_ i: Int) -> Double { Double(i + short) / Double(short + lanes) * shortShare }
        func longU(_ j: Int) -> Double { shortShare + Double(j + lanes) / Double(long + lanes) * (1 - shortShare) }

        var check: [(point: CGPoint, u: Double)] = []
        for i in -short...lanes {
            for j in -lanes...long {
                let onShort = abs(j) <= lanes
                let onLong = abs(i) <= lanes
                guard onShort || onLong else { continue }
                check.append((lattice(i, j), onShort ? shortU(i) : longU(j)))
            }
        }
        // Centre the check's bounding box on the view.
        let xs = check.map(\.point.x), ys = check.map(\.point.y)
        let cx = (xs.min()! + xs.max()!) / 2, cy = (ys.min()! + ys.max()!) / 2
        var cells = check.map { CheckMark.Cell(point: CGPoint(x: $0.point.x - cx, y: $0.point.y - cy), u: $0.u) }

        for row in 0..<3 {
            let radius = 0.285 + Double(row) * checkPitch * 0.87
            let count = Int((2 * .pi * radius / checkPitch).rounded())
            for k in 0..<count {
                // Stagger alternate rows by half a step so the band packs evenly.
                let turn = (Double(k) + (row.isMultiple(of: 2) ? 0 : 0.5)) / Double(count)
                let angle = turn * 2 * .pi - .pi / 2
                cells.append(CheckMark.Cell(point: CGPoint(x: cos(angle) * radius, y: sin(angle) * radius),
                                            u: turn))
            }
        }
        return CheckMark(cells: cells)
    }()
    static var checkSlotCount: Int { mark.cells.count }

    static func draw(in ctx: inout GraphicsContext, size: CGSize, scene: PairingScene, frame: Frame) {
        guard sprites.count == tints.count else { return }
        let side = Double(min(size.width, size.height))
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let space = Space(center: center, side: side, angle: frame.clock * 0.42, tilt: -0.38)
        let glows = sprites.map { ctx.resolve(Image(decorative: $0, scale: 1)) }
        let layout = scene.code.map { CodeLayout(center: center, side: side, count: $0.count) }

        drawBackdrop(&ctx, center: center, side: side)
        if let t = frame.success {
            let moment = Moment(t: t, clock: frame.clock, space: space, glows: glows, layout: layout)
            drawSuccess(&ctx, makeMovers(scene: scene, frame: frame, space: space, layout: layout), moment)
            ctx.blendMode = .normal
            ctx.opacity = 1
            return
        }
        drawHalo(&ctx, scene: scene, frame: frame, space: space, glows: glows)
        if let layout {
            drawCard(&ctx, layout: layout, frame: frame)
            drawFinders(&ctx, layout: layout, frame: frame)
            drawDots(&ctx, scene: scene, layout: layout, frame: frame, space: space, glows: glows)
        }
    }

    // MARK: Geometry

    /// Camera for the particle sphere: turn about the vertical axis, tilt
    /// towards the viewer, then a gentle perspective.
    private struct Space {
        let center: CGPoint
        let side: Double
        let radius: Double
        let focal: Double
        let cosY, sinY, cosX, sinX: Double

        init(center: CGPoint, side: Double, angle: Double, tilt: Double) {
            self.center = center
            self.side = side
            // Small enough that the nearest particles stay inside the frame.
            radius = side * 0.39
            focal = radius * 5
            cosY = cos(angle); sinY = sin(angle)
            cosX = cos(tilt); sinX = sin(tilt)
        }

        func rotate(_ v: SIMD3<Double>) -> SIMD3<Double> {
            let x = v.x * cosY + v.z * sinY
            let z0 = -v.x * sinY + v.z * cosY
            return SIMD3(x, v.y * cosX - z0 * sinX, v.y * sinX + z0 * cosX)
        }

        func project(_ v: SIMD3<Double>) -> (point: CGPoint, scale: Double) {
            let s = focal / (focal - v.z)
            return (CGPoint(x: center.x + v.x * s, y: center.y + v.y * s), s)
        }

        /// 0 at the back of the sphere, 1 at the front.
        func depth(_ v: SIMD3<Double>) -> Double { clamp((v.z / radius + 1) / 2) }
    }

    private struct CodeLayout {
        let center: CGPoint
        let count: Int
        let cardSide: Double
        let module: Double
        let origin: CGPoint

        init(center: CGPoint, side: Double, count: Int) {
            self.center = center
            self.count = count
            cardSide = side * 0.64
            // Three modules of quiet zone on each side.
            module = cardSide / Double(count + 6)
            origin = CGPoint(x: center.x - module * Double(count) / 2,
                             y: center.y - module * Double(count) / 2)
        }

        /// Centres of the three finder patterns, relative to the card's centre.
        var finders: [CGPoint] {
            let n = count, half = Double(count) / 2
            return [(0, 0), (n - 7, 0), (0, n - 7)].map {
                CGPoint(x: (Double($0.0) + 3.5 - half) * module, y: (Double($0.1) + 3.5 - half) * module)
            }
        }
    }

    /// A particle's camera-space position in the turning cloud.
    private static func cloudPosition(_ p: PairingScene.Particle, expand: Double,
                                      space: Space, clock: Double) -> SIMD3<Double> {
        let wobble = 1 + 0.045 * sin(clock * 1.3 + p.seed * 6.283 + p.dir.y * 5)
        return space.rotate(p.dir * (p.radius * space.radius * wobble * expand))
    }

    // MARK: Cloud

    private static func drawBackdrop(_ ctx: inout GraphicsContext, center: CGPoint, side: Double) {
        let radius = side * 0.5
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [Color.white.opacity(0.04), Color.white.opacity(0)]),
            center: center, startRadius: 0, endRadius: radius))
    }

    /// A cloud particle's position and glow brightness while the cloud forms and turns.
    private static func haloState(_ p: PairingScene.Particle, scene: PairingScene, frame: Frame,
                                  space: Space) -> (position: SIMD3<Double>, alpha: Double) {
        // Once the card is up the cloud widens so it still frames the card.
        let widen = scene.code == nil ? 0 : 0.12 * easeInOut(clamp((frame.code - cardIn.lowerBound) / 0.8))
        // The cloud grows out of the centre, outer particles last.
        let intro = easeOut(clamp((frame.cloud - p.seed * 0.4) / 0.9))
        let position = cloudPosition(p, expand: (0.15 + 0.85 * intro) * (1 + widen), space: space, clock: frame.clock)
        let twinkle = 0.8 + 0.2 * sin(frame.clock * (1.2 + 2 * p.seed) + p.seed * 40)
        return (position, intro * twinkle * (0.15 + 0.7 * space.depth(position)))
    }

    private static func drawHalo(_ ctx: inout GraphicsContext, scene: PairingScene, frame: Frame,
                                 space: Space, glows: [GraphicsContext.ResolvedImage]) {
        ctx.blendMode = .plusLighter
        for p in scene.halo {
            let (cloud, alpha) = haloState(p, scene: scene, frame: frame, space: space)
            let (point, scale) = space.project(cloud)
            glow(&ctx, glows[p.tint], at: point, diameter: p.size * scale, alpha: alpha)
        }
        ctx.blendMode = .normal
        ctx.opacity = 1
    }

    private static func glow(_ ctx: inout GraphicsContext, _ sprite: GraphicsContext.ResolvedImage,
                             at point: CGPoint, diameter: Double, alpha: Double) {
        guard alpha > 0.01 else { return }
        let d = diameter * 2.1
        ctx.opacity = min(1, alpha)
        ctx.draw(sprite, in: CGRect(x: point.x - d / 2, y: point.y - d / 2, width: d, height: d))
    }

    // MARK: The code

    private static func drawCard(_ ctx: inout GraphicsContext, layout: CodeLayout, frame: Frame) {
        let t = clamp((frame.code - cardIn.lowerBound) / (cardIn.upperBound - cardIn.lowerBound))
        guard t > 0 else { return }
        fillCard(&ctx, layout: layout, scale: 0.86 + 0.14 * easeOutBack(t), alpha: easeOut(t))
    }

    private static func fillCard(_ ctx: inout GraphicsContext, layout: CodeLayout, scale: Double, alpha: Double) {
        guard alpha > 0.01 else { return }
        let w = layout.cardSide * scale
        let rect = CGRect(x: layout.center.x - w / 2, y: layout.center.y - w / 2, width: w, height: w)
        let path = Path(roundedRect: rect, cornerRadius: w * 0.1, style: .continuous)
        ctx.drawLayer { layer in
            layer.opacity = alpha
            layer.addFilter(.shadow(color: Color.white.opacity(0.12), radius: 18))
            layer.fill(path, with: .color(card))
        }
    }

    /// Finder patterns stay solid rounded squares so scanners lock on; they
    /// pop in as the first dots land.
    private static func drawFinders(_ ctx: inout GraphicsContext, layout: CodeLayout, frame: Frame) {
        let t = clamp((frame.code - finderIn.lowerBound) / (finderIn.upperBound - finderIn.lowerBound))
        guard t > 0 else { return }
        let alpha = clamp(t * 2.5)
        fillFinders(&ctx, layout: layout, size: easeOutBack(t), alphas: [alpha, alpha, alpha])
    }

    /// `size` scales each pattern about its own centre; `spread` scales their
    /// positions about the card's centre, so they follow a scaling card.
    private static func fillFinders(_ ctx: inout GraphicsContext, layout: CodeLayout, size: Double,
                                    spread: Double = 1, alphas: [Double]) {
        let m = layout.module * size
        for (k, offset) in layout.finders.enumerated() where alphas[k] > 0.01 {
            let c = CGPoint(x: layout.center.x + offset.x * spread, y: layout.center.y + offset.y * spread)
            let color = ink.color.opacity(min(1, alphas[k]))
            let outer = CGRect(x: c.x - m * 3.5, y: c.y - m * 3.5, width: m * 7, height: m * 7)
            var ring = Path(roundedRect: outer, cornerRadius: m * 1.6, style: .continuous)
            ring.addPath(Path(roundedRect: outer.insetBy(dx: m, dy: m), cornerRadius: m * 0.9, style: .continuous))
            let core = Path(roundedRect: outer.insetBy(dx: m * 2, dy: m * 2), cornerRadius: m * 0.7, style: .continuous)
            ctx.fill(ring, with: .color(color), style: FillStyle(eoFill: true))
            ctx.fill(core, with: .color(color))
        }
    }

    private static func drawDots(_ ctx: inout GraphicsContext, scene: PairingScene, layout: CodeLayout,
                                 frame: Frame, space: Space, glows: [GraphicsContext.ResolvedImage]) {
        let module = layout.module
        let dotSize = module * 0.86
        var landed = Path()

        for p in scene.dots {
            guard let target = p.target else { continue }
            let flat = SIMD3(target.x * module, target.y * module, 0)

            let appear = clamp(frame.code / dotAppear)
            guard appear > 0 else { continue }
            let fly = clamp((frame.code - p.delay) / dotFlight)
            if fly >= 1 {
                landed.addEllipse(in: CGRect(x: layout.center.x + flat.x - dotSize / 2,
                                             y: layout.center.y + flat.y - dotSize / 2,
                                             width: dotSize, height: dotSize))
                continue
            }

            let e = easeInOut(fly)
            let cloud = cloudPosition(p, expand: 0.55 + 0.45 * easeOut(appear), space: space, clock: frame.clock)
            let v = cloud + (flat - cloud) * e
            let (point, scale) = space.project(v)

            // Glowing particle, fading as it settles.
            ctx.blendMode = .plusLighter
            let alpha = appear * (1 - e) * (0.2 + 0.65 * space.depth(cloud))
            glow(&ctx, glows[p.tint], at: point, diameter: p.size * scale, alpha: alpha)
            ctx.blendMode = .normal
            ctx.opacity = 1

            // Solid dot that darkens from the particle's grey into ink early,
            // so it reads against the light card.
            if fly > 0 {
                let color = tints[p.tint].mixed(with: ink, clamp(fly * 2.5))
                let d = p.size * scale * 0.9 + (dotSize - p.size * scale * 0.9) * e
                ctx.fill(circle(point, d), with: .color(color.color.opacity(clamp(fly * 3))))
            }
        }

        if !landed.isEmpty {
            ctx.fill(landed, with: .color(ink.color))
        }
    }

    // MARK: Success

    /// One particle as the success animation takes it over.
    private struct Mover {
        let p: PairingScene.Particle
        /// Camera-space position when the animation takes it: on the card or in the turning cloud.
        let start: SIMD3<Double>
        /// Glow brightness in the cloud; code dots start as dark ink on the card.
        let alpha: Double
        let onCard: Bool
    }

    private struct Moment {
        /// Seconds since pairing succeeded.
        let t: Double
        let clock: Double
        let space: Space
        let glows: [GraphicsContext.ResolvedImage]
        let layout: CodeLayout?

        var side: Double { space.side }
        var center: CGPoint { space.center }
        /// Diameter of a finished dot of the mark.
        var dot: Double { PairingCodeArt.checkDot * space.side }
        /// Diameter of a code dot on the card.
        var inkDot: Double { (layout?.module ?? 0) * 0.86 }

        func cell(_ p: PairingScene.Particle) -> CheckMark.Cell { PairingCodeArt.mark.cells[p.checkSlot] }
        func end(_ cell: CheckMark.Cell) -> SIMD3<Double> { SIMD3(cell.point.x * side, cell.point.y * side, 0) }
    }

    private static func makeMovers(scene: PairingScene, frame: Frame, space: Space, layout: CodeLayout?) -> [Mover] {
        var movers: [Mover] = []
        movers.reserveCapacity(scene.halo.count + scene.dots.count)
        if let layout {
            for p in scene.dots {
                guard let target = p.target else { continue }
                let start = SIMD3(target.x * layout.module, target.y * layout.module, 0)
                movers.append(Mover(p: p, start: start, alpha: 0.7, onCard: true))
            }
        }
        for p in scene.halo {
            let (position, alpha) = haloState(p, scene: scene, frame: frame, space: space)
            movers.append(Mover(p: p, start: position, alpha: alpha, onCard: false))
        }
        return movers
    }

    /// A crisp dot of the finished mark.
    private static func fillMarkDot(_ ctx: inout GraphicsContext, at point: CGPoint, diameter: Double, alpha: Double) {
        guard alpha > 0.01, diameter > 0.1 else { return }
        ctx.opacity = 1
        ctx.fill(circle(point, diameter), with: .color(Color.white.opacity(min(1, alpha))))
    }

    /// A code dot still on the card, fading out as it lights up.
    private static func fillInk(_ ctx: inout GraphicsContext, at point: CGPoint, diameter: Double, alpha: Double) {
        guard alpha > 0.01 else { return }
        ctx.blendMode = .normal
        ctx.opacity = 1
        ctx.fill(circle(point, diameter), with: .color(ink.color.opacity(min(1, alpha))))
        ctx.blendMode = .plusLighter
    }

    /// The finished mark breathes as one.
    private static func breathe(_ clock: Double) -> Double { 0.9 + 0.1 * sin(clock * 2.4) }

    // MARK: Ripple

    private enum Ripple {
        /// The card pops and a shock wave runs out through the particles.
        static let pop = 0.14
        /// In view sides per second.
        static let shockSpeed = 1.6
        /// A single wave of light runs out through the finished mark.
        static let shimmer = 1.35
    }

    /// The card squashes and pops like a bubble; the shock wave throws the
    /// dots and the cloud outwards, they drift to a stop, then spring into
    /// the mark — overshooting and wobbling into place, each dot popping as
    /// it lands. One soft wave of light then runs out through the mark.
    private static func drawSuccess(_ ctx: inout GraphicsContext, _ movers: [Mover], _ m: Moment) {
        let t = m.t, side = m.side, center = m.center
        let squash = 1 - 0.05 * easeInOut(clamp(t / Ripple.pop))
        if let layout = m.layout {
            let burst = easeOut(clamp((t - Ripple.pop) / 0.22))
            fillCard(&ctx, layout: layout, scale: squash + 0.13 * burst,
                     alpha: 1 - smoothstep(Ripple.pop, Ripple.pop + 0.2, t))
            let fade = 1 - smoothstep(Ripple.pop - 0.04, Ripple.pop + 0.12, t)
            fillFinders(&ctx, layout: layout, size: squash + 0.3 * burst, spread: squash + 0.13 * burst,
                        alphas: [fade, fade, fade])
        }

        ctx.blendMode = .plusLighter
        let st = t - Ripple.pop
        if st > 0, st < 0.45 {
            ctx.opacity = 1
            ctx.stroke(circle(center, side * Ripple.shockSpeed * st * 2),
                       with: .color(Color.white.opacity(0.3 * pow(1 - st / 0.45, 2))), lineWidth: 1.5)
        }

        let lit = clamp(t / Ripple.pop)
        for mover in movers {
            let p = mover.p
            let cell = m.cell(p)
            let start = mover.onCard ? mover.start * squash : mover.start
            // Thrown outwards and towards the viewer as the wave passes, then slowed by drag.
            let reach = hypot(start.x, start.y)
            let kt = t - Ripple.pop - reach / (side * Ripple.shockSpeed)
            let drift = kt > 0 ? 1 - exp(-7 * kt) : 0
            let out = reach > 0.5 ? SIMD3(start.x / reach, start.y / reach, 0) : SIMD3(p.dir.x, p.dir.y, 0)
            let r1 = fract(p.seed * 7.31)
            let push = side * (mover.onCard ? 0.05 + 0.09 * r1 : 0.04 + 0.03 * r1)
            let kicked = start + (out * push + SIMD3(0, 0, m.space.radius * 0.4 * r1)) * drift

            // Then springs into the mark, curving on the way, around the ring
            // and along the check.
            let gt = t - (0.48 + 0.22 * cell.u + 0.18 * p.seed)
            let s = spring(gt, response: 0.42, damping: 0.48)
            let d = m.end(cell) - kicked
            let arc = SIMD3(-d.y, d.x, 0) * (0.18 * sin(.pi * clamp(s)))
            let (point, scale) = m.space.project(kicked + d * s + arc)

            if mover.onCard {
                fillInk(&ctx, at: point, diameter: m.inkDot * squash, alpha: 1 - lit)
            }
            let glowAlpha = mover.onCard ? 0.75 * lit : mover.alpha
            guard p.leads else {
                // Followers dissolve into their dot as they arrive.
                glow(&ctx, m.glows[p.tint], at: point, diameter: p.size * scale,
                     alpha: glowAlpha * (1 - smoothstep(0.15, 0.4, gt)))
                continue
            }
            let settle = smoothstep(0.08, 0.3, gt)
            let pop = exp(-pow((gt - 0.2) / 0.07, 2))
            let wt = t - Ripple.shimmer
            let front = 0.36 * wt / 0.6
            let lift = wt > 0 ? exp(-pow((hypot(cell.point.x, cell.point.y) - front) / 0.04, 2)) : 0
            let rippled = CGPoint(x: center.x + (point.x - center.x) * (1 + 0.03 * lift),
                                  y: center.y + (point.y - center.y) * (1 + 0.03 * lift))
            glow(&ctx, m.glows[0], at: rippled, diameter: m.dot * 2.2, alpha: 0.25 * lift)
            glow(&ctx, m.glows[p.tint], at: point, diameter: p.size * scale * 1.3,
                 alpha: max(glowAlpha * (1 - settle), 0.7 * pop))
            fillMarkDot(&ctx, at: rippled, diameter: m.dot * settle * (1 + 0.9 * pop + 0.25 * lift),
                        alpha: settle * min(1, breathe(m.clock) * 0.85 + 0.25 * lift))
        }
    }

    // MARK: Helpers

    private static func circle(_ center: CGPoint, _ diameter: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                               width: diameter, height: diameter))
    }

    /// A small hot core with a short, faint falloff.
    private static func makeSprite(_ tint: RGB) -> CGImage? {
        let px = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let core = tint.mixed(with: RGB(r: 1, g: 1, b: 1), 0.4)
        let colors = [
            CGColor(srgbRed: core.r, green: core.g, blue: core.b, alpha: 1),
            CGColor(srgbRed: tint.r, green: tint.g, blue: tint.b, alpha: 0.9),
            CGColor(srgbRed: tint.r, green: tint.g, blue: tint.b, alpha: 0.08),
            CGColor(srgbRed: tint.r, green: tint.g, blue: tint.b, alpha: 0),
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.3, 0.5, 1])
        else { return nil }
        let mid = CGPoint(x: Double(px) / 2, y: Double(px) / 2)
        ctx.drawRadialGradient(gradient, startCenter: mid, startRadius: 0,
                               endCenter: mid, endRadius: Double(px) / 2, options: [])
        return ctx.makeImage()
    }

    /// Stable pseudo-random value in 0..<1 per (index, salt).
    static func rand(_ index: Int, _ salt: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: index &* 2_654_435_761 &+ salt &* 40_503 &+ 0x9E37)
        x ^= x >> 33; x &*= 0xff51afd7ed558ccd
        x ^= x >> 33; x &*= 0xc4ceb9fe1a85ec53
        x ^= x >> 33
        return Double(x % 1_000_000) / 1_000_000
    }

    /// An underdamped spring from 0 to 1 that overshoots and settles; `response`
    /// is the period of its oscillation in seconds.
    private static func spring(_ t: Double, response: Double, damping: Double) -> Double {
        guard t > 0 else { return 0 }
        let w = 2 * .pi / response
        let wd = w * (1 - damping * damping).squareRoot()
        return 1 - exp(-damping * w * t) * (cos(wd * t) + damping * w / wd * sin(wd * t))
    }

    private static func fract(_ v: Double) -> Double { v - v.rounded(.down) }
    private static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
    private static func smoothstep(_ a: Double, _ b: Double, _ v: Double) -> Double {
        let t = clamp((v - a) / (b - a))
        return t * t * (3 - 2 * t)
    }
    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    private static func easeIn(_ t: Double) -> Double { t * t * t }
    private static func easeInOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    private static func easeOutBack(_ t: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }

    fileprivate struct RGB {
        let r, g, b: CGFloat

        init(r: CGFloat, g: CGFloat, b: CGFloat) {
            self.r = r; self.g = g; self.b = b
        }

        func mixed(with other: RGB, _ t: CGFloat) -> RGB {
            let t = min(1, max(0, t))
            return RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
        }

        var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    }
}
