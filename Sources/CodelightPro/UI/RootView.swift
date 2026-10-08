import SwiftUI

/// One continuous floating panel. The strip bar is always present at the top;
/// the detail body grows downward from it when expanded — no view switching.
struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let morph = model.morph {
            PanelMorphView(model: model, morph: morph)
        } else {
            steadyView
        }
    }

    @ViewBuilder private var steadyView: some View {
        switch model.displayMode {
        case .floating:
            FloatingRootView(model: model)
        case .island:
            IslandRootView(model: model)
        }
    }
}

private struct FloatingRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            StripHeader(model: model)

            if model.isExpanded {
                ExpandedBody(model: model)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                .fill(Theme.panelFill)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                .strokeBorder(Theme.panelBorder, lineWidth: 1)
        )
        .overlay {
            PanelActivityGlow(
                isActive: [.working, .completed, .needsApproval, .error].contains(model.overall),
                shape: .roundedRect(cornerRadius: Theme.panelRadius),
                color: Theme.glowColor(model.overall),
                brightColor: .white,
                cycleDuration: model.overall == .working ? 2.0 : 4.0,
                intensity: model.overall == .working ? 1.0 : 0.65
            )
        }
        .padding(Theme.panelInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
