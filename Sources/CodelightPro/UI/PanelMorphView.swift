import SwiftUI

/// Island ⇄ floating strip transition: one black shell springs between the
/// two frames while its corners reshape (notch ears ⇄ rounded top) and the
/// two headers cross-fade. Both ends match the steady views, so swapping to
/// and from this view is seamless.
struct PanelMorphView: View {
    @ObservedObject var model: AppModel
    let morph: PanelMorph

    static let animation = Animation.spring(response: 0.42, dampingFraction: 0.84)
    /// When the spring has visibly settled and the steady view can take over.
    static let duration: Duration = .milliseconds(520)

    var body: some View {
        let showingTo = morph.atDestination
        let mode = showingTo ? morph.to : morph.from
        let rect = showingTo ? morph.toRect : morph.fromRect
        let shape = PanelShellShape(floatingness: mode == .floating ? 1 : 0)

        ZStack(alignment: .top) {
            header(for: morph.from)
                .opacity(showingTo ? 0 : 1)
                .blur(radius: showingTo ? 4 : 0)
            header(for: morph.to)
                .opacity(showingTo ? 1 : 0)
                .blur(radius: showingTo ? 0 : 4)
        }
        .frame(width: rect.width, height: rect.height, alignment: .top)
        .background(shape.fill(Theme.panelFill))
        .clipShape(shape)
        .offset(x: rect.minX, y: rect.minY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Each header keeps the size it has in its own mode.
    @ViewBuilder
    private func header(for mode: DisplayMode) -> some View {
        let rect = mode == morph.from ? morph.fromRect : morph.toRect
        switch mode {
        case .island:
            IslandTopRow(model: model, metrics: model.islandMetrics)
                .frame(width: rect.width, height: model.islandMetrics.height)
        case .floating:
            StripHeader(model: model)
                .frame(width: rect.width)
        }
    }
}

/// Interpolates between the island outline (`floatingness` 0: flat top with
/// concave ears, small bottom radius — identical to `IslandShape`) and the
/// floating strip (1: all corners `Theme.panelRadius`). The ears retract
/// first, then the top corners round off.
struct PanelShellShape: Shape {
    var floatingness: CGFloat

    var animatableData: CGFloat {
        get { floatingness }
        set { floatingness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(1, max(0, floatingness))
        let e = IslandMetrics.earRadius * max(0, 1 - t / 0.3)
        let limit = min(rect.width / 2, rect.height / 2)
        let tr = min(limit, Theme.panelRadius * max(0, (t - 0.3) / 0.7))
        let br = min(limit, IslandMetrics.bottomRadius + (Theme.panelRadius - IslandMetrics.bottomRadius) * t)

        var path = Path()
        if tr > 0 {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + tr))
        } else {
            path.move(to: CGPoint(x: rect.minX - e, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + e),
                              control: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - br))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX + br, y: rect.maxY), radius: br)
        path.addLine(to: CGPoint(x: rect.maxX - br, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - br), radius: br)
        if tr > 0 {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + tr))
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                        tangent2End: CGPoint(x: rect.maxX - tr, y: rect.minY), radius: tr)
            path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.minY))
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                        tangent2End: CGPoint(x: rect.minX, y: rect.minY + tr), radius: tr)
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + e))
            path.addQuadCurve(to: CGPoint(x: rect.maxX + e, y: rect.minY),
                              control: CGPoint(x: rect.maxX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}
