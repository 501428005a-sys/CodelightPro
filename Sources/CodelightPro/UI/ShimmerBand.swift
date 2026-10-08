import AppKit
import SwiftUI

/// A render-server-driven replacement for a `TimelineView` shimmer. SwiftUI
/// still supplies the text mask, so typography and the visible gradient remain
/// unchanged; only the moving band is hosted by Core Animation.
struct ShimmerBand: NSViewRepresentable {
    let period: TimeInterval
    let widthFraction: CGFloat
    var minimumWidth: CGFloat = 28

    func makeNSView(context: Context) -> ShimmerBandView {
        ShimmerBandView()
    }

    func updateNSView(_ view: ShimmerBandView, context: Context) {
        view.configure(
            period: period,
            widthFraction: widthFraction,
            minimumWidth: minimumWidth
        )
    }
}

@MainActor
final class ShimmerBandView: NSView {
    private let band = CAGradientLayer()
    private var period: TimeInterval = 0
    private var widthFraction: CGFloat = 0
    private var minimumWidth: CGFloat = 0
    private var lastSize = CGSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true

        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.colors = [
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(0.18).cgColor,
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(0.18).cgColor,
            NSColor.clear.cgColor,
        ]
        band.locations = [0, 0.25, 0.5, 0.75, 1]
        layer?.addSublayer(band)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(period: TimeInterval, widthFraction: CGFloat, minimumWidth: CGFloat) {
        guard self.period != period
                || self.widthFraction != widthFraction
                || self.minimumWidth != minimumWidth else { return }
        self.period = period
        self.widthFraction = widthFraction
        self.minimumWidth = minimumWidth
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.size != .zero,
              bounds.size != lastSize || band.animation(forKey: "travel") == nil else { return }
        lastSize = bounds.size

        let shimmerWidth = max(bounds.width * widthFraction, minimumWidth)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.frame = CGRect(x: -shimmerWidth, y: -2, width: shimmerWidth, height: bounds.height + 4)
        CATransaction.commit()

        let distance = bounds.width + shimmerWidth * 2
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0
        animation.toValue = distance
        animation.duration = max(0.1, period)
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        let phase = Date().timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: animation.duration)
        animation.beginTime = CACurrentMediaTime() - phase
        band.add(animation, forKey: "travel")
    }
}
