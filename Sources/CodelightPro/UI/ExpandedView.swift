import SwiftUI

/// The detail body that grows downward from the strip when expanded:
/// a divider, one card per agent, and a footer. The surrounding shape, black
/// fill, and glow are owned by `RootView`.
struct ExpandedBody: View {
    @ObservedObject var model: AppModel
    @State private var showingSettings = false
    @State private var showingInfo = false
    /// The cards' height before the phone switches started to drop down.
    @State private var agentsHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(Theme.strokeSoft)
                .frame(height: 0.8)

            ApprovalStack(model: model)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    AgentCard(status: model.codex)
                    DividerLine()
                    AgentCard(
                        status: model.claude,
                        isAuthorizingClaude: model.isAuthorizingClaude,
                        claudeAuthorizationMessage: model.claudeAuthorizationMessage,
                        authorizeClaude: { model.authorizeClaudeUsage() }
                    )
                }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.strokeSoft, lineWidth: 0.8)
                )
            }
            .frame(maxWidth: .infinity)
            .frame(height: model.isPhoneOptionsResizing ? agentsHeight : nil)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { agentsHeight = geo.size.height }
                        .onChange(of: geo.size.height) { height in
                            if !model.isPhoneOptionsResizing { agentsHeight = height }
                        }
                }
            )

            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 13)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            PhoneLinkRow(model: model)

            HStack(alignment: .center, spacing: 10) {
                footerIconButton("info.circle", help: "更新时间") {
                    showingInfo.toggle()
                }
                .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
                    UpdateInfoPopover(model: model)
                }

                Spacer()

                footerIconButton("gearshape.fill", help: "设置") {
                    showingSettings.toggle()
                }
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                    SettingsPopover(model: model)
                }

                footerIconButton("power", help: "退出") {
                    NSApp.terminate(nil)
                }
            }
        }
        // Either popover keeps the panel from auto-collapsing under it.
        .onChange(of: showingSettings || showingInfo) { isPresented in
            model.isSettingsPopoverPresented = isPresented
        }
    }

    private func footerIconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
        .background(Circle().fill(Theme.surfacePressed))
        .help(help)
    }
}

/// Link light + label. Once a phone is connected the row drops down the
/// phone's switches (the panel grows downward for them, see
/// `AppDelegate.setPhoneOptionsOpen`); otherwise it opens the pairing window.
private struct PhoneLinkRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let link = model.phoneLink
        let color = Theme.phoneLinkColor(link)
        let connected = isConnected(link)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                if connected {
                    model.setPhoneOptionsOpen(!model.isPhoneOptionsVisible)
                } else {
                    model.openSettings()
                }
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                        .shadow(color: color.opacity(connected ? 0.9 : 0), radius: 3)

                    Text(link.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(model.isPhoneOptionsVisible ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(connected ? "iPhone 推送设置" : "手机同步…")

            if model.isPhoneOptionsOpen {
                // Fixed height once settled; while the floating window
                // animates, as tall as it has grown so far (rows clipped).
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: model.isPhoneOptionsResizing ? nil : IslandMetrics.phoneOptionsHeight)
                    .frame(maxHeight: IslandMetrics.phoneOptionsHeight)
                    .overlay(alignment: .top) {
                        options
                            .fixedSize(horizontal: false, vertical: true)
                            .opacity(model.isPhoneOptionsVisible ? 1 : 0)
                    }
                    .clipped()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.strokeSoft, lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onChange(of: connected) { isConnected in
            if !isConnected { model.setPhoneOptionsOpen(false) }
        }
    }

    /// Fits in `phoneOptionsHeight`: the window grows by that much.
    private var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Theme.strokeSoft)
                .frame(height: 0.8)
                .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 9) {
                SettingsToggleRow("灵动岛实时推送",
                                  detail: "关闭后不再推送灵动岛信息",
                                  isOn: $model.phoneLiveActivityEnabled)
                SettingsToggleRow("状态变更提醒",
                                  detail: "关闭后不再震动、亮屏提醒",
                                  isOn: $model.phoneLiveAlertsEnabled)
                    .disabled(!model.phoneLiveActivityEnabled)
                    .opacity(model.phoneLiveActivityEnabled ? 1 : 0.45)
                SettingsToggleRow("手机端审批",
                                  detail: "关闭后手机不能允许 / 拒绝请求",
                                  isOn: $model.phoneApprovalsEnabled)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func isConnected(_ link: PhoneLinkState) -> Bool {
        if case .connected = link { return true }
        return false
    }
}

private struct UpdateInfoPopover: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("最近更新", model.lastUpdated.formatted(date: .omitted, time: .standard))
            row("同步到 iPhone", model.pairing.lastPushedAt?.formatted(date: .omitted, time: .standard) ?? "尚未同步")
        }
        .padding(14)
        .frame(width: 200, alignment: .leading)
        .background(Theme.panelFill)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
        }
        .font(.system(size: 11, weight: .medium))
    }
}

private struct SettingsPopover: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsToggleRow("音效", isOn: $model.soundEnabled)
            SettingsToggleRow("空闲 3 分钟自动隐藏", isOn: $model.autoHideEnabled)
            SettingsToggleRow("开机自启动", isOn: $model.launchAtLogin)

            Divider().overlay(Theme.strokeSoft)

            Button {
                model.isSettingsPopoverPresented = false
                model.openPanelSettings()
            } label: {
                Label("悬浮窗设置…", systemImage: "rectangle.on.rectangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                model.isSettingsPopoverPresented = false
                model.openSettings()
            } label: {
                Label("手机同步…", systemImage: "iphone.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.textPrimary)
        .padding(14)
        .frame(width: 220, alignment: .leading)
        .background(Theme.panelFill)
        .onDisappear {
            model.isSettingsPopoverPresented = false
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? Theme.accentBlue : Theme.surfaceRaised)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(isOn ? Theme.accentBlue : Theme.stroke, lineWidth: 0.8)
                        )

                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(Color.black.opacity(0.82))
                    }
                }
                .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(1)
                        .foregroundStyle(Theme.textPrimary)

                    if let detail {
                        Text(detail)
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One agent's card: status badge + usage / token info.
private struct AgentCard: View {
    let status: AgentStatus
    var isAuthorizingClaude = false
    var claudeAuthorizationMessage: String?
    var authorizeClaude: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                titleBlock
                Spacer(minLength: 0)
                AgentStateText(state: status.state)
            }

            // Codex usage quotas
            if let p = status.primary, let pct = p.usedPercent {
                UsageBar(label: "5 小时额度", pct: pct, resetsAt: p.resetsAt)
            }
            if let s = status.secondary, let pct = s.usedPercent {
                UsageBar(label: "周额度", pct: pct, resetsAt: s.resetsAt)
            }

            if status.tool == .claude, status.primary == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text(claudeAuthorizationMessage ?? status.usageError ?? "登录 Claude Code 后可自动查看官方 5 小时额度 / 周用量")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)

                    Button {
                        authorizeClaude?()
                    } label: {
                        HStack(spacing: 5) {
                            if isAuthorizingClaude {
                                ProgressView()
                                    .scaleEffect(0.45)
                                    .frame(width: 10, height: 10)
                            } else {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                                    .font(.system(size: 10))
                            }
                            Text(isAuthorizingClaude ? "正在接入…" : "连接 Claude")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceRaised))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.strokeSoft, lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textPrimary)
                    .disabled(isAuthorizingClaude)
                    .help("已安装 Claude Code 时引导登录；未安装时尝试 Claude 桌面版登录")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleBlock: some View {
        AgentNameText(
            name: status.tool.displayName,
            isWorking: status.state == .working
        )
    }
}

private struct AgentNameText: View {
    let name: String
    let isWorking: Bool

    private let titleFont = Font.system(size: 13, weight: .semibold)

    var body: some View {
        Text(name)
            .font(titleFont)
            .foregroundStyle(isWorking ? Theme.textPrimary.opacity(0.48) : Theme.textPrimary)
            .lineLimit(1)
            .overlay {
                if isWorking {
                    ShimmerBand(period: 1.55, widthFraction: 0.48)
                        .blendMode(.screen)
                        .mask(
                            Text(name)
                                .font(titleFont)
                                .lineLimit(1)
                        )
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct AgentStateText: View {
    let state: AgentState

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var label: String {
        switch state {
        case .working: return "Working"
        case .completed: return "Done"
        case .needsApproval: return "Needs Approval"
        case .idle: return "Free"
        case .offline: return "Offline"
        case .error: return "Error"
        }
    }

    private var color: Color {
        switch state {
        case .completed:
            return Theme.accentBlue.opacity(0.95)
        case .needsApproval, .error:
            return Theme.accentRed.opacity(0.95)
        default:
            return Theme.color(state).opacity(0.9)
        }
    }
}

/// A labelled usage bar with percentage and reset countdown.
private struct UsageBar: View {
    let label: String
    let pct: Double
    let resetsAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textSecondary)
                Spacer()
                PixelPercentText(pct: pct, color: Theme.usageColor(pct))
            }
            GeometryReader { geo in
                PixelUsageMeter(
                    pct: pct,
                    width: geo.size.width,
                    color: Theme.usageColor(pct)
                )
            }
            .frame(height: 10)
            if let r = resetsAt {
                Text(r.countdownToNow)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

private struct PixelPercentText: View {
    let pct: Double
    let color: Color

    var body: some View {
        Text(String(format: "%.0f%%", pct))
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .foregroundStyle(color.opacity(0.9))
            .shadow(color: color.opacity(0.18), radius: 2)
            .shadow(color: color.opacity(0.08), radius: 5)
    }
}

private struct PixelUsageMeter: View {
    let pct: Double
    let width: CGFloat
    let color: Color

    private let blockSize: CGFloat = 5
    private let gap: CGFloat = 2

    var body: some View {
        let count = max(1, Int((width + gap) / (blockSize + gap)))
        let filled = Int((Double(count) * min(100, max(0, pct)) / 100).rounded(.up))

        HStack(spacing: gap) {
            ForEach(0..<count, id: \.self) { index in
                let isFilled = index < filled
                let progress = filled > 1 ? Double(index) / Double(filled - 1) : 1
                let opacity = 0.46 + progress * 0.54
                let brightness = -0.10 + progress * 0.20

                Rectangle()
                    .fill(isFilled ? color.opacity(opacity) : Theme.surfacePressed)
                    .brightness(isFilled ? brightness : 0)
                    .shadow(
                        color: isFilled && index >= max(0, filled - 3) ? color.opacity(0.36) : .clear,
                        radius: 3,
                        x: 0,
                        y: 0
                    )
                    .overlay(
                        Rectangle()
                            .strokeBorder(Theme.strokeSoft, lineWidth: 0.5)
                    )
                    .frame(width: blockSize, height: 8)
            }
        }
        .frame(width: width, alignment: .leading)
        .clipped()
    }
}

private struct DividerLine: View {
    var body: some View {
        Rectangle()
            .fill(Theme.strokeSoft)
            .frame(height: 0.8)
    }
}
