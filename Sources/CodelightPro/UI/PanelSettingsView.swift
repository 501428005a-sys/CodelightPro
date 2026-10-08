import SwiftUI

/// Settings for the panel itself (floating strip / island), opened from the
/// gear popover and the menu bar control center.
struct PanelSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            screensCard
            Spacer(minLength: 0)
            footer
        }
        .padding(22)
        .frame(width: 390, height: 460, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.05, blue: 0.07),
                    Color(red: 0.02, green: 0.02, blue: 0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("悬浮窗设置")
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("选择悬浮窗和灵动岛优先显示在哪块屏幕上。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var screensCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("显示器", systemImage: "display.2")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("已连接 \(model.screens.count) 台")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ScreenOptionRow(
                        icon: "hand.draw",
                        title: "跟随拖动位置",
                        subtitle: "拖到哪块屏幕就留在哪块",
                        isSelected: model.preferredScreenID == nil
                    ) {
                        model.preferredScreenID = nil
                    }

                    ForEach(model.screens) { screen in
                        ScreenOptionRow(
                            icon: screen.isBuiltin ? "laptopcomputer" : "display",
                            title: screen.name,
                            subtitle: "\(screen.kindLabel) · \(Int(screen.pixelSize.width))×\(Int(screen.pixelSize.height))",
                            badge: model.currentScreenID == screen.id ? "当前" : nil,
                            isSelected: model.preferredScreenID == screen.id
                        ) {
                            model.preferredScreenID = screen.id
                        }
                    }

                    if let id = model.preferredScreenID, !model.screens.contains(where: { $0.id == id }) {
                        ScreenOptionRow(
                            icon: "display.trianglebadge.exclamationmark",
                            title: model.preferredScreenName ?? "未知显示器",
                            subtitle: "未连接 · 连接后会自动回到这块屏幕",
                            isSelected: true,
                            isDimmed: true
                        ) {}
                    }
                }
            }
        }
        .cardStyle()
    }

    private var footer: some View {
        Text("选定的显示器连接时，面板会自动移到它上面；未连接时暂时显示在主屏。临时拖到其他屏幕后，重新启动或重新接入该显示器时会回来。")
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ScreenOptionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var badge: String?
    let isSelected: Bool
    var isDimmed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 24)
                    .foregroundStyle(isSelected ? Theme.accentBlue : Theme.textSecondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.accentMint)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Theme.accentMint.opacity(0.15)))
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? Theme.accentBlue : Theme.stroke, lineWidth: 1.2)
                    if isSelected {
                        Circle()
                            .fill(Theme.accentBlue)
                            .padding(4)
                    }
                }
                .frame(width: 16, height: 16)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Theme.surfaceRaised : Theme.surfacePressed)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accentBlue.opacity(0.5) : Theme.strokeSoft, lineWidth: 0.8)
            )
            .opacity(isDimmed ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
