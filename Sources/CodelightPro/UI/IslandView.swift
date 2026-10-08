import SwiftUI

/// Dynamic-Island presentation: a black bar flush with the top of the screen
/// that wraps around the notch, with the cat on the left, the tracked state on
/// the right, and the glow ring running around its sides and bottom. Tapping
/// it grows the island downward into the usual detail body.
struct IslandRootView: View {
    @ObservedObject var model: AppModel

    private var metrics: IslandMetrics { model.islandMetrics }

    private var shape: IslandShape {
        IslandShape(
            bottomRadius: model.isExpanded ? IslandMetrics.expandedBottomRadius : IslandMetrics.bottomRadius,
            earRadius: IslandMetrics.earRadius
        )
    }

    var body: some View {
        // The window is already at its final size when expanding (and shrinks
        // only after collapsing), so the island animates its own frame inside
        // it, anchored to the top edge — no window-resize animation to fight.
        let size = metrics.bodySize(expanded: model.isExpanded, extraHeight: model.expandedExtraHeight)

        VStack(spacing: 0) {
            IslandTopRow(model: model, metrics: metrics)
                .frame(height: metrics.height)

            if model.isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(model.currentTrackedStateText)
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundStyle(Theme.trackedStateColor(model.currentTrackedStateText, overall: model.overall))
                            .lineLimit(1)
                        ProjectNameText(
                            name: model.currentTrackedProjectName,
                            isWorking: model.currentTrackedProjectIsWorking
                        )
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                    ExpandedBody(model: model)
                }
                .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(shape.fill(Theme.panelFill))
        .clipShape(shape)
        .overlay {
            PanelActivityGlow(
                isActive: [.working, .completed, .needsApproval, .error].contains(model.overall),
                shape: .island(bottomRadius: shape.bottomRadius),
                color: Theme.glowColor(model.overall),
                brightColor: .white,
                cycleDuration: model.overall == .working ? 2.0 : 4.0,
                // Always full strength: the island sits against the menu bar
                // and is a thin sliver, so a dimmed ring barely reads.
                intensity: 1.0
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The notch-height row: always visible, the whole UI while collapsed.
struct IslandTopRow: View {
    @ObservedObject var model: AppModel
    let metrics: IslandMetrics

    var body: some View {
        HStack(spacing: 0) {
            PixelCat(state: model.overall)
                .frame(width: catSize, height: catSize)

            if metrics.notchWidth > 0 {
                // Nothing can be seen under the camera housing.
                Spacer(minLength: metrics.notchWidth)
            } else {
                ProjectNameText(
                    name: model.currentTrackedProjectName,
                    isWorking: model.currentTrackedProjectIsWorking
                )
                .padding(.horizontal, 8)
                Spacer(minLength: 0)
            }

            Text(shortStateText)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(Theme.trackedStateColor(model.currentTrackedStateText, overall: model.overall))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        // One gesture for both: AppDelegate decides on release whether it was
        // a click (expand / collapse) or a drag (turn into the floating strip).
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in model.onIslandPointer?(.moved) }
                .onEnded { _ in model.onIslandPointer?(.released) }
        )
        .help("Codex: \(model.codex.state.label) · Claude: \(model.claude.state.label)")
    }

    private var catSize: CGFloat { max(16, metrics.height - 8) }

    /// The side of the island is narrow; "NEEDS APPROVAL" doesn't fit.
    private var shortStateText: String {
        model.currentTrackedStateText == "NEEDS APPROVAL" ? "APPROVAL" : model.currentTrackedStateText
    }
}

/// Flat top with small concave "ears" flaring into the screen edge (drawn just
/// outside the rect, like the hardware notch) and rounded bottom corners.
struct IslandShape: Shape {
    var bottomRadius: CGFloat
    var earRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(bottomRadius, rect.width / 2, rect.height)
        let e = earRadius
        var path = Path()
        path.move(to: CGPoint(x: rect.minX - e, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + e),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX + r, y: rect.maxY), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - r), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + e))
        path.addQuadCurve(to: CGPoint(x: rect.maxX + e, y: rect.minY),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
