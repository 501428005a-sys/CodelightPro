import SwiftUI

/// The persistent floating strip (长条). Collapsed it's the whole UI; expanded
/// it becomes the header. Tapping it toggles the panel open/closed.
struct StripHeader: View {
    @ObservedObject var model: AppModel

    private var overall: AgentState { model.overall }

    var body: some View {
        trackedHeader
        .padding(.horizontal, 12)
        .frame(height: 58)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                model.isExpanded.toggle()
            }
        }
        .help("Codex: \(model.codex.state.label) · Claude: \(model.claude.state.label)")
    }

    private var trackedHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            statusChip

            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentTrackedStateText)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(stateTextColor)
                    .lineLimit(1)

                ProjectNameText(
                    name: model.currentTrackedProjectName,
                    isWorking: model.currentTrackedProjectIsWorking
                )
            }
            .offset(y: -1)

            Spacer(minLength: 0)
        }
    }

    private var stateTextColor: Color {
        Theme.trackedStateColor(model.currentTrackedStateText, overall: overall)
    }

    private var statusChip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.color(overall).opacity(0.14))
            PixelCat(state: overall)
                .padding(1)
        }
        .frame(width: 40, height: 40)
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Theme.color(overall).opacity(0.22), lineWidth: 0.8)
        )
    }

}

struct ProjectNameText: View {
    let name: String
    let isWorking: Bool

    private let titleFont = Font.system(size: 11, weight: .semibold)

    var body: some View {
        Text(name)
            .font(titleFont)
            .foregroundStyle(isWorking ? Theme.textPrimary.opacity(0.48) : Theme.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .overlay {
                if isWorking {
                    ShimmerBand(period: 1.55, widthFraction: 0.42)
                        .blendMode(.screen)
                        .mask(
                            Text(name)
                                .font(titleFont)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        )
                        .allowsHitTesting(false)
                }
            }
    }
}
