import SwiftUI

enum Theme {
    /// Shared geometry so the collapsed strip and the expanded panel share one
    /// continuous shape (the panel just grows downward from the strip).
    static let panelRadius: CGFloat = 19
    /// Transparent margin around the floating strip inside its window.
    static let panelInset: CGFloat = 7

    /// Full-black surface for the whole floating panel.
    static let panelFill = Color.black
    static let panelBorder = Color.white.opacity(0.085)

    static let surface = Color.white.opacity(0.045)
    static let surfaceRaised = Color.white.opacity(0.075)
    static let surfacePressed = Color.white.opacity(0.030)
    static let stroke = Color.white.opacity(0.110)
    static let strokeSoft = Color.white.opacity(0.065)
    static let textPrimary = Color.white.opacity(0.920)
    static let textSecondary = Color.white.opacity(0.620)
    static let textTertiary = Color.white.opacity(0.380)
    static let accentBlue = Color(red: 0.42, green: 0.66, blue: 0.92)
    static let idleGlowBlue = Color(red: 0.28, green: 0.52, blue: 0.78)
    static let accentMint = Color(red: 0.43, green: 0.78, blue: 0.65)
    static let accentLime = Color(red: 0.55, green: 0.86, blue: 0.45)
    static let accentAmber = Color(red: 0.93, green: 0.67, blue: 0.35)
    static let accentRed = Color(red: 0.88, green: 0.38, blue: 0.42)
    static let muted = Color(red: 0.55, green: 0.57, blue: 0.62)

    static func color(_ state: AgentState) -> Color {
        switch state {
        case .working: return accentMint
        case .completed: return accentLime
        case .needsApproval: return accentAmber
        case .error: return accentRed
        case .idle: return accentBlue
        case .offline: return muted
        }
    }

    /// Colour of the activity ring around the panel / island.
    static func glowColor(_ state: AgentState) -> Color {
        switch state {
        case .idle: return idleGlowBlue
        case .completed: return accentBlue
        case .needsApproval: return accentRed
        default: return color(state)
        }
    }

    /// Colour of `AppModel.currentTrackedStateText` in the strip / island.
    static func trackedStateColor(_ text: String, overall: AgentState) -> Color {
        switch text {
        case "DONE": return accentBlue.opacity(0.95)
        case "NEEDS APPROVAL": return accentRed.opacity(0.95)
        default: return color(overall).opacity(0.9)
        }
    }

    /// The status light next to the iPhone link label.
    static func phoneLinkColor(_ link: PhoneLinkState) -> Color {
        switch link {
        case .connected: return accentLime
        case .unreachable: return accentRed
        case .notPaired, .noPhone: return muted
        }
    }

    static func icon(_ state: AgentState) -> String {
        switch state {
        case .working: return "bolt.fill"
        case .completed: return "checkmark.circle.fill"
        case .needsApproval: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .idle: return "moon.fill"
        case .offline: return "powersleep"
        }
    }

    static func usageColor(_ pct: Double) -> Color {
        switch pct {
        case ..<60: return accentMint
        case ..<85: return accentAmber
        default: return accentRed
        }
    }
}

extension Date {
    /// "2小时15分后" / "3天4小时后" style countdown to this date.
    var countdownToNow: String {
        let secs = Int(timeIntervalSinceNow)
        if secs <= 0 { return "即将重置" }
        let d = secs / 86400
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if d > 0 { return "\(d)天\((secs % 86400) / 3600)小时后重置" }
        if h > 0 { return "\(h)小时\(m)分后重置" }
        return "\(m)分后重置"
    }
}
