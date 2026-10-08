import SwiftUI

/// The oldest pending permission request, at the top of the expanded panel.
/// The same request is on the paired iPhone; whichever side answers first
/// wins and the card disappears on both.
struct ApprovalStack: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let request = model.approvals.first {
            ApprovalCard(request: request, remaining: model.approvals.count - 1) { decision in
                withAnimation(.easeOut(duration: 0.2)) {
                    model.decideApproval(request.id, decision)
                }
            }
            .id(request.id)
            .transition(.opacity)
        }
    }
}

private struct ApprovalCard: View {
    let request: ApprovalRequest
    let remaining: Int
    let decide: (ApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accentAmber)
                Text("\(request.tool.displayName) 请求权限")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if remaining > 0 {
                    Text("还有 \(remaining) 个")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Text([request.toolName, request.project].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)

            if !request.summary.isEmpty {
                Text(request.summary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(5)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfacePressed))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.strokeSoft, lineWidth: 0.8))
            }

            HStack(spacing: 8) {
                actionButton("拒绝", foreground: Theme.accentRed, background: Theme.surfaceRaised) {
                    decide(.deny)
                }
                actionButton("允许", foreground: Color.black.opacity(0.85), background: Theme.accentLime) {
                    decide(.allow)
                }
            }

            Button {
                decide(.terminal)
            } label: {
                Text("在终端处理")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("交给 \(request.tool.displayName) 自己的确认框")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.accentAmber.opacity(0.45), lineWidth: 0.8)
        )
    }

    private func actionButton(_ title: String, foreground: Color, background: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
