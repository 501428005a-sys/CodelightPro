import SwiftUI

/// Observable state shared by all views.
@MainActor
final class AppModel: ObservableObject {
    @Published var codex = AgentStatus(tool: .codex, state: .offline, detail: "…")
    @Published var claude = AgentStatus(tool: .claude, state: .offline, detail: "…")
    @Published var lastUpdated = Date()
    @Published var isAuthorizingClaude = false
    @Published var claudeAuthorizationMessage: String?
    @Published var pairing = PairingDisplayState()
    @Published var soundEnabled: Bool = UserDefaults.standard.object(forKey: "sound.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(soundEnabled, forKey: "sound.enabled")
        }
    }

    /// When on, the floating strip hides after a few idle minutes and pops back
    /// when an agent starts working. Default on.
    @Published var autoHideEnabled: Bool = UserDefaults.standard.object(forKey: "autoHide.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoHideEnabled, forKey: "autoHide.enabled")
            onAutoHideSettingChange?()
        }
    }

    /// 灵动岛实时推送: off → the paired iPhone shows no Live Activity at all.
    /// Sent with every status upload; the relay and the phone both obey it.
    @Published var phoneLiveActivityEnabled: Bool = UserDefaults.standard.object(forKey: "phone.liveActivity") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(phoneLiveActivityEnabled, forKey: "phone.liveActivity")
            phonePreferencesDidChange()
        }
    }

    /// 状态变更提醒: off → island updates stay silent (no buzz, no screen wake).
    @Published var phoneLiveAlertsEnabled: Bool = UserDefaults.standard.object(forKey: "phone.liveAlerts") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(phoneLiveAlertsEnabled, forKey: "phone.liveAlerts")
            phonePreferencesDidChange()
        }
    }

    /// 手机端审批: off → phones get no approval cards or island buttons and
    /// can't answer; requests are handled on the Mac only.
    @Published var phoneApprovalsEnabled: Bool = UserDefaults.standard.object(forKey: "phone.approvals") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(phoneApprovalsEnabled, forKey: "phone.approvals")
            phonePreferencesDidChange()
        }
    }

    /// Set while copying in the relay's settings, so they aren't sent back.
    private var isApplyingRemotePhonePreferences = false

    private func phonePreferencesDidChange() {
        if !isApplyingRemotePhonePreferences { onPhonePreferencesChange?() }
    }

    /// The relay's copy changed (e.g. switched on the phone).
    func applyRemotePhonePreferences(_ phone: PhonePreferences) {
        isApplyingRemotePhonePreferences = true
        defer { isApplyingRemotePhonePreferences = false }
        if phoneLiveActivityEnabled != phone.liveActivity { phoneLiveActivityEnabled = phone.liveActivity }
        if phoneLiveAlertsEnabled != phone.alerts { phoneLiveAlertsEnabled = phone.alerts }
        if phoneApprovalsEnabled != phone.approvals { phoneApprovalsEnabled = phone.approvals }
    }

    var phonePreferences: PhonePreferences {
        PhonePreferences(liveActivity: phoneLiveActivityEnabled, alerts: phoneLiveAlertsEnabled,
                         approvals: phoneApprovalsEnabled)
    }

    /// The phone switches dropped down under 已连接 iPhone. The panel grows
    /// downward by `IslandMetrics.phoneOptionsHeight` to make room; only
    /// AppDelegate sets it (after resizing the window).
    @Published var isPhoneOptionsOpen = false
    /// Where the drop-down is heading (chevron, fade); set as soon as it's
    /// clicked, while `isPhoneOptionsOpen` follows the window.
    @Published var isPhoneOptionsVisible = false
    /// While the floating window animates its height, the agent cards keep
    /// their height and the rows take whatever the window has grown by.
    @Published var isPhoneOptionsResizing = false

    var expandedExtraHeight: CGFloat {
        isPhoneOptionsOpen ? IslandMetrics.phoneOptionsHeight : 0
    }

    /// Permission requests from Claude Code / Codex awaiting an answer on the
    /// panel or the paired iPhone, oldest first. Owned by `ApprovalCenter`.
    @Published var approvals: [ApprovalRequest] = []

    @Published var launchAtLogin: Bool = LaunchAtLogin.isEnabled {
        didSet {
            LaunchAtLogin.set(launchAtLogin)
        }
    }

    /// The mode on screen. Changed only by dragging (strip to the top centre →
    /// island, island pulled out → strip); AppDelegate owns it. Remembered.
    @Published var displayMode: DisplayMode = DisplayMode(
        rawValue: UserDefaults.standard.string(forKey: "display.mode") ?? ""
    ) ?? .floating {
        didSet {
            UserDefaults.standard.set(displayMode.rawValue, forKey: "display.mode")
        }
    }
    /// Displays currently connected; kept fresh by AppDelegate.
    @Published var screens: [ScreenInfo] = []
    /// The display the panel is on right now (`ScreenInfo.id`).
    @Published var currentScreenID: String?

    /// The display the panel should live on whenever it's connected (nil →
    /// wherever it was last dragged). Stored by UUID; the name is kept so the
    /// settings can still show it while it's unplugged.
    @Published var preferredScreenID: String? = UserDefaults.standard.string(forKey: "display.preferredScreen") {
        didSet {
            guard preferredScreenID != oldValue else { return }
            UserDefaults.standard.set(preferredScreenID, forKey: "display.preferredScreen")
            preferredScreenName = screens.first { $0.id == preferredScreenID }?.name
            onPreferredScreenChange?()
        }
    }
    @Published private(set) var preferredScreenName: String? = UserDefaults.standard.string(forKey: "display.preferredScreenName") {
        didSet {
            UserDefaults.standard.set(preferredScreenName, forKey: "display.preferredScreenName")
        }
    }

    @Published var islandMetrics = IslandMetrics.fallback
    /// Non-nil while morphing between island and floating strip.
    @Published var morph: PanelMorph?

    @Published var isExpanded = false {
        didSet {
            if !isExpanded {
                isPhoneOptionsOpen = false
                isPhoneOptionsVisible = false
                isPhoneOptionsResizing = false
            }
            onExpandChange?(isExpanded)
        }
    }
    @Published var isSettingsPopoverPresented = false

    /// Set by AppDelegate to resize the floating window.
    var onExpandChange: ((Bool) -> Void)?
    var onAuthorizeClaudeUsage: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenPanelSettings: (() -> Void)?
    /// A phone switch was flipped here; the relay's copy must follow.
    var onPhonePreferencesChange: (() -> Void)?
    /// Asks AppDelegate to open / close the phone switches.
    var onPhoneOptionsChange: ((Bool) -> Void)?
    /// Fired when the preferred display is changed.
    var onPreferredScreenChange: (() -> Void)?
    var onStartPairing: ((String) -> Void)?
    /// Fired after each poll so the window controller can re-evaluate auto-hide.
    var onStatusesUpdated: (() -> Void)?
    /// Fired when the auto-hide preference is toggled.
    var onAutoHideSettingChange: (() -> Void)?
    var onDecideApproval: ((String, ApprovalDecision) -> Void)?
    /// Mouse down/drag/up on the island; AppDelegate tells clicks from drags.
    var onIslandPointer: ((IslandPointerPhase) -> Void)?

    var statuses: [AgentStatus] { [codex, claude] }

    private var currentTrackedStatus: AgentStatus? {
        let titled = statuses.filter { status in
            guard let title = status.sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return !title.isEmpty
        }

        let needsAttention = titled.filter { $0.state == .needsApproval }
        let working = titled.filter { $0.state == .working }
        let source = !needsAttention.isEmpty ? needsAttention : (!working.isEmpty ? working : titled)

        return source.max {
            ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast)
        }
    }

    var currentTrackedProjectName: String {
        currentTrackedStatus?.sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No tracked project"
    }

    var currentTrackedStateText: String {
        if statuses.contains(where: { $0.state == .needsApproval }) {
            return "NEEDS APPROVAL"
        }

        if statuses.contains(where: { $0.state == .working }) {
            return "WORKING"
        }

        switch currentTrackedStatus?.state ?? overall {
        case .idle: return "FREE"
        case .working: return "WORKING"
        case .completed: return "DONE"
        case .needsApproval: return "NEEDS APPROVAL"
        case .error: return "ERROR"
        case .offline: return "OFFLINE"
        }
    }

    var currentTrackedProjectIsWorking: Bool {
        currentTrackedStatus?.state == .working
    }

    /// The single most-urgent state, used to color the collapsed orb.
    var overall: AgentState {
        let states = statuses.map(\.state)
        if states.contains(.needsApproval) { return .needsApproval }
        if states.contains(.working) { return .working }
        if states.contains(.completed) { return .completed }
        if states.contains(.error) { return .error }
        if states.contains(.idle) { return .idle }
        return .offline
    }

    func authorizeClaudeUsage() {
        onAuthorizeClaudeUsage?()
    }

    func openSettings() {
        onOpenSettings?()
    }

    func openPanelSettings() {
        onOpenPanelSettings?()
    }

    func setPhoneOptionsOpen(_ open: Bool) {
        onPhoneOptionsChange?(open)
    }

    var phoneLink: PhoneLinkState {
        if pairing.syncFailed { return .unreachable }
        switch pairing.linkedMobileCount {
        case nil: return .notPaired
        case 0?: return .noPhone
        case let count?: return .connected(count)
        }
    }

    func decideApproval(_ id: String, _ decision: ApprovalDecision) {
        onDecideApproval?(id, decision)
    }

    func startPairing() {
        onStartPairing?(pairing.serverURL)
    }
}
