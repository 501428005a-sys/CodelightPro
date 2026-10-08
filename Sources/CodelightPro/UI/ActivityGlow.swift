import AppKit
import CoreImage
import SwiftUI

/// The outline the glow ring follows.
enum GlowShape: Equatable {
    case roundedRect(cornerRadius: CGFloat)
    /// Flat top flush with the screen edge and rounded bottom corners. The ring
    /// runs down the sides and along the bottom only, so the moving highlight
    /// appears to slip behind the top edge of the screen.
    case island(bottomRadius: CGFloat)
}

struct PanelActivityGlow: View {
    let isActive: Bool
    let shape: GlowShape
    let color: Color
    let brightColor: Color
    let cycleDuration: TimeInterval
    let intensity: Double

    var body: some View {
        if isActive {
            CompositedActivityGlow(
                shape: shape,
                color: color,
                brightColor: brightColor,
                cycleDuration: cycleDuration,
                intensity: intensity,
                lineWidth: 2.2
            )
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }
}

/// The original SwiftUI implementation rebuilt three angular gradients and two
/// blurred strokes on the main thread for every animation frame. This view
/// keeps exactly the same stops, widths, blur radii, opacity and timing, but
/// lets Core Animation animate the conic-gradient angle in the render server.
private struct CompositedActivityGlow: NSViewRepresentable {
    let shape: GlowShape
    let color: Color
    let brightColor: Color
    let cycleDuration: TimeInterval
    let intensity: Double
    let lineWidth: CGFloat

    func makeNSView(context: Context) -> ActivityGlowView {
        ActivityGlowView()
    }

    func updateNSView(_ view: ActivityGlowView, context: Context) {
        view.configure(
            shape: shape,
            color: NSColor(color),
            brightColor: NSColor(brightColor),
            cycleDuration: cycleDuration,
            intensity: intensity,
            lineWidth: lineWidth
        )
    }
}

@MainActor
private final class ActivityGlowView: NSView {
    private let blackSoftStroke = CALayer()
    private let blackStroke = CALayer()
    // Island outline equivalents of the two black strokes above.
    private let blackSoftPath = CAShapeLayer()
    private let blackPath = CAShapeLayer()
    private let wideGlow = GradientStrokeLayer(blurRadius: 3.5)
    private let mediumGlow = GradientStrokeLayer(blurRadius: 1.8)
    private let sharpGlow = GradientStrokeLayer(blurRadius: 0)

    private var shape: GlowShape = .roundedRect(cornerRadius: 0)
    private var lineWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false

        blackSoftStroke.borderColor = NSColor.black.cgColor
        blackSoftStroke.opacity = 1
        blackSoftStroke.cornerCurve = .continuous
        blackSoftStroke.filters = [Self.blurFilter(radius: 0.55)]

        blackStroke.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
        blackStroke.cornerCurve = .continuous

        blackSoftPath.fillColor = nil
        blackSoftPath.strokeColor = NSColor.black.cgColor
        blackSoftPath.filters = [Self.blurFilter(radius: 0.55)]
        blackPath.fillColor = nil
        blackPath.strokeColor = NSColor.black.withAlphaComponent(0.18).cgColor

        layer?.addSublayer(blackSoftStroke)
        layer?.addSublayer(blackStroke)
        layer?.addSublayer(blackSoftPath)
        layer?.addSublayer(blackPath)
        layer?.addSublayer(wideGlow)
        layer?.addSublayer(mediumGlow)
        layer?.addSublayer(sharpGlow)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let rect = bounds
        let blackSoftWidth = max(1, lineWidth * 0.55)
        let blackHairlineWidth: CGFloat = 0.65

        guard case .roundedRect(let cornerRadius) = shape else {
            layoutIsland(in: rect, blackSoftWidth: blackSoftWidth, blackHairlineWidth: blackHairlineWidth)
            CATransaction.commit()
            return
        }
        blackSoftStroke.isHidden = false
        blackStroke.isHidden = false
        blackSoftPath.isHidden = true
        blackPath.isHidden = true

        blackSoftStroke.frame = rect.insetBy(
            dx: -blackSoftWidth / 2,
            dy: -blackSoftWidth / 2
        )
        blackSoftStroke.cornerRadius = cornerRadius + blackSoftWidth / 2
        blackSoftStroke.borderWidth = blackSoftWidth

        blackStroke.frame = rect.insetBy(
            dx: -blackHairlineWidth / 2,
            dy: -blackHairlineWidth / 2
        )
        blackStroke.cornerRadius = cornerRadius + blackHairlineWidth / 2
        blackStroke.borderWidth = blackHairlineWidth

        // All three strokes in the original SwiftUI ZStack share one path.
        // CALayer borders draw inward, so give each mask a different frame to
        // keep their visual centre line aligned instead of producing rings.
        let sharedCenterInset: CGFloat = 0
        wideGlow.layout(
            in: rect, cornerRadius: cornerRadius,
            lineWidth: lineWidth + 7, centerInset: sharedCenterInset
        )
        mediumGlow.layout(
            in: rect, cornerRadius: cornerRadius,
            lineWidth: lineWidth + 3, centerInset: sharedCenterInset
        )
        sharpGlow.layout(
            in: rect, cornerRadius: cornerRadius,
            lineWidth: lineWidth, centerInset: sharedCenterInset
        )

        CATransaction.commit()
    }

    private func layoutIsland(in rect: CGRect, blackSoftWidth: CGFloat, blackHairlineWidth: CGFloat) {
        guard case .island(let bottomRadius) = shape else { return }
        blackSoftStroke.isHidden = true
        blackStroke.isHidden = true
        blackSoftPath.isHidden = false
        blackPath.isHidden = false

        let path = Self.islandOutline(in: rect, bottomRadius: bottomRadius)
        for (layer, width) in [(blackSoftPath, blackSoftWidth), (blackPath, blackHairlineWidth)] {
            layer.frame = rect
            layer.path = path
            layer.lineWidth = width
        }

        wideGlow.layout(in: rect, outline: path, lineWidth: lineWidth + 7)
        mediumGlow.layout(in: rect, outline: path, lineWidth: lineWidth + 3)
        sharpGlow.layout(in: rect, outline: path, lineWidth: lineWidth)
    }

    /// Left side, bottom and right side of the island; no top edge. The layer
    /// isn't flipped, so the top of the island is `rect.maxY`.
    static func islandOutline(in rect: CGRect, bottomRadius: CGFloat) -> CGPath {
        let r = min(bottomRadius, rect.width / 2, rect.height)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }

    func configure(
        shape: GlowShape,
        color: NSColor,
        brightColor: NSColor,
        cycleDuration: TimeInterval,
        intensity: Double,
        lineWidth: CGFloat
    ) {
        self.shape = shape
        self.lineWidth = lineWidth

        let level = min(1, max(0, intensity))
        let stops: [(NSColor, NSNumber)] = [
            (.clear, 0.00),
            (color.withAlphaComponent(0.30 * level), 0.10),
            (color.withAlphaComponent(level), 0.20),
            (brightColor.withAlphaComponent(level), 0.30),
            (color.withAlphaComponent(level), 0.40),
            (color.withAlphaComponent(0.30 * level), 0.50),
            (.clear, 0.60),
            (.clear, 1.00),
        ]

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wideGlow.opacity = Float(0.22 * level)
        mediumGlow.opacity = Float(0.40 * level)
        sharpGlow.opacity = Float(0.95 * level)
        for glow in [wideGlow, mediumGlow, sharpGlow] {
            glow.updateGradient(stops: stops, cycleDuration: max(0.1, cycleDuration))
        }
        CATransaction.commit()
        needsLayout = true
    }

    fileprivate static func blurFilter(radius: CGFloat) -> CIFilter {
        let filter = CIFilter(name: "CIGaussianBlur")!
        filter.name = "codelight.blur.\(radius)"
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        return filter
    }
}

/// A fixed rounded-rectangle stroke mask with a conic gradient underneath it.
/// Only `endPoint` is animated, so the app no longer wakes up for each frame.
@MainActor
private final class GradientStrokeLayer: CALayer {
    private let gradient = CAGradientLayer()
    private let clippedGradient = CALayer()
    private let strokeMask = CALayer()
    private let pathMask = CAShapeLayer()
    private let blurRadius: CGFloat
    private var currentDuration: TimeInterval = 0

    init(blurRadius: CGFloat) {
        self.blurRadius = blurRadius
        super.init()

        masksToBounds = false
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1.0, y: 0.5)
        clippedGradient.masksToBounds = false
        clippedGradient.addSublayer(gradient)
        addSublayer(clippedGradient)

        strokeMask.borderColor = NSColor.white.cgColor
        strokeMask.backgroundColor = NSColor.clear.cgColor
        strokeMask.cornerCurve = .continuous
        clippedGradient.mask = strokeMask

        pathMask.fillColor = nil
        pathMask.strokeColor = NSColor.white.cgColor

        if blurRadius > 0 {
            // Blur the already-masked gradient in this outer layer. Putting the
            // filter on the masked layer clips the blur back to a hard border.
            filters = [ActivityGlowView.blurFilter(radius: blurRadius)]
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func layout(
        in rect: CGRect,
        cornerRadius: CGFloat,
        lineWidth: CGFloat,
        centerInset: CGFloat
    ) {
        // SwiftUI's Shape.stroke is centred on the shape boundary. Give the
        // Core Animation layer room outside the NSView so the coloured light
        // sits on the panel perimeter instead of being pushed inward.
        let effectOutset = layoutFrames(in: rect, lineWidth: lineWidth)
        clippedGradient.mask = strokeMask

        let panelRect = bounds.insetBy(dx: effectOutset, dy: effectOutset)
        let maskInset = centerInset - lineWidth / 2
        strokeMask.frame = panelRect.insetBy(dx: maskInset, dy: maskInset)
        strokeMask.cornerRadius = max(0, cornerRadius - maskInset)
        strokeMask.borderWidth = lineWidth
    }

    /// Path-based variant used by the island, whose outline isn't a closed
    /// rounded rectangle. `outline` is in the glow view's coordinates.
    func layout(in rect: CGRect, outline: CGPath, lineWidth: CGFloat) {
        let effectOutset = layoutFrames(in: rect, lineWidth: lineWidth)
        var shift = CGAffineTransform(translationX: effectOutset, y: effectOutset)
        pathMask.frame = bounds
        pathMask.path = outline.copy(using: &shift)
        pathMask.lineWidth = lineWidth
        clippedGradient.mask = pathMask
    }

    private func layoutFrames(in rect: CGRect, lineWidth: CGFloat) -> CGFloat {
        let effectOutset = max(10, lineWidth / 2 + blurRadius * 2)
        frame = rect.insetBy(dx: -effectOutset, dy: -effectOutset)
        clippedGradient.frame = bounds
        gradient.frame = bounds
        return effectOutset
    }

    func updateGradient(stops: [(NSColor, NSNumber)], cycleDuration: TimeInterval) {
        gradient.colors = stops.map { $0.0.cgColor }
        gradient.locations = stops.map(\.1)

        guard currentDuration != cycleDuration || gradient.animation(forKey: "angle") == nil else {
            return
        }
        currentDuration = cycleDuration

        // A dense endpoint path produces the same continuous angular rotation
        // as changing AngularGradient's start/end angles, but runs out of process.
        let samples = 121
        let points: [NSValue] = (0..<samples).map { index in
            let phase = CGFloat(index) / CGFloat(samples - 1)
            let angle = phase * 2 * .pi
            return NSValue(point: CGPoint(
                x: 0.5 + cos(angle) * 0.5,
                y: 0.5 + sin(angle) * 0.5
            ))
        }

        let animation = CAKeyframeAnimation(keyPath: "endPoint")
        animation.values = points
        animation.duration = cycleDuration
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.isRemovedOnCompletion = false
        let phase = Date().timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycleDuration)
        animation.beginTime = CACurrentMediaTime() - phase
        gradient.add(animation, forKey: "angle")
    }
}
