import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            // The relay address only matters until one has been saved.
            if !serverConfigured {
                serverCard
            }
            pairingCard
            if model.pairing.pairedAt == nil {
                refreshButton
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(22)
        .frame(width: 390, height: 560, alignment: .topLeading)
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
        Text("手机同步")
            .font(.system(size: 24, weight: .black, design: .rounded))
            .foregroundStyle(Theme.textPrimary)
    }

    private var serverConfigured: Bool {
        UserDefaults.standard.string(forKey: "sync.serverURL") != nil
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("服务器地址", systemImage: "server.rack")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.textPrimary)

            TextField("https://your-relay.zeabur.app", text: $model.pairing.serverURL)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.strokeSoft, lineWidth: 0.8))
        }
        .cardStyle()
    }

    private var refreshButton: some View {
        Button {
            model.startPairing()
        } label: {
            HStack(spacing: 8) {
                if model.pairing.isLoading {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(model.pairing.isLoading ? "正在生成…" : "刷新配对二维码")
                    .font(.system(size: 12, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accentBlue.opacity(0.9)))
            .foregroundStyle(Color.black.opacity(0.82))
        }
        .buttonStyle(.plain)
        .disabled(model.pairing.isLoading)
    }

    private var pairingCard: some View {
        VStack(alignment: .center, spacing: 10) {
            PairingCodeView(payload: model.pairing.pairURL, pairedAt: model.pairing.pairedAt, side: 290)

            if let message = model.pairing.message {
                Text(message)
                    .font(.system(size: 12, weight: model.pairing.pairedAt == nil ? .medium : .bold))
                    .foregroundStyle(messageColor(message))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeInOut(duration: 0.3), value: model.pairing.pairedAt)
            }

            if model.pairing.pairedAt == nil {
                HStack(spacing: 14) {
                    if let expiresAt = model.pairing.expiresAt {
                        Text("有效期至 \(expiresAt.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if let pairURL = model.pairing.pairURL {
                        Button("复制配对链接") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(pairURL, forType: .string)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.accentMint)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func messageColor(_ message: String) -> Color {
        if model.pairing.pairedAt != nil { return Theme.accentLime }
        return message.contains("错误") || message.contains("不正确") ? Theme.accentRed : Theme.textSecondary
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let lastPushedAt = model.pairing.lastPushedAt {
                let phones = model.pairing.linkedMobileCount ?? 0
                Text("最近同步：\(lastPushedAt.formatted(date: .omitted, time: .standard)) · 已绑定 \(phones) 台手机")
                    .foregroundStyle(phones > 0 ? Theme.accentMint : Theme.textSecondary)
            } else {
                Text("生成二维码并完成手机绑定后，Mac 会自动把状态推送到服务器。")
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .font(.system(size: 11))
    }
}

extension View {
    func cardStyle() -> some View {
        padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.strokeSoft, lineWidth: 0.8))
    }
}
