import SwiftUI
import UserNotifications

/// Polls the monitors on a timer and pushes results into the model.
@MainActor
final class Poller {
    private let model: AppModel
    private let codex = CodexMonitor()
    private let claude = ClaudeMonitor()
    private let claudeAPI = ClaudeUsageAPI()
    private let codexAPI = CodexRateLimitAPI()
    private let sync: StatusSyncClient
    private var timer: Timer?
    private var isPolling = false
    private var hasAppliedSnapshot = false

    /// How long the "completed" cat lingers after a task finishes (working→idle).
    private let completedLinger: TimeInterval = 180
    private var codexCompletedUntil: Date?
    private var claudeCompletedUntil: Date?

    /// Status upload to the relay: immediately when an agent's state changes
    /// (that is what drives the phone's push notifications), otherwise as a
    /// heartbeat so the phone's dashboard stays fresh.
    private let syncHeartbeat: TimeInterval = 30
    private var lastSyncedSignature: String?
    private var lastSyncedAt = Date.distantPast
    private var isSyncing = false

    /// Phone settings shared through the relay (changed here or on a phone).
    /// A local change is pushed right away; otherwise the relay's copy is
    /// read every few seconds so a phone's change shows up here quickly.
    private let phoneSettingsPollInterval: TimeInterval = 5
    private var phoneSettingsRevision = -1
    private var phoneSettingsDirty = false
    private var isSyncingPhoneSettings = false
    private var lastPhoneSettingsFetch = Date.distantPast

    init(model: AppModel, sync: StatusSyncClient) {
        self.model = model
        self.sync = sync
    }

    func start(interval: TimeInterval = 2.0) {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func authorizeClaudeUsage() {
        guard !model.isAuthorizingClaude else { return }
        model.isAuthorizingClaude = true
        model.claudeAuthorizationMessage = "正在检查 Claude 登录…"

        Task {
            do {
                let result = try await ClaudeAuthorizer().authorize()
                switch result {
                case .claudeCodeAlreadyLoggedIn:
                    model.claudeAuthorizationMessage = "Claude Code 已登录，正在刷新官方用量…"
                    claudeAPI.forceRefresh()
                    tick()
                case .openedClaudeCodeLogin:
                    model.claudeAuthorizationMessage = "已打开 Claude Code 登录窗口，登录完成后会自动刷新"
                case .importedClaudeDesktop:
                    model.claudeAuthorizationMessage = "Claude 桌面版已连接，正在刷新官方用量…"
                    claudeAPI.forceRefresh()
                    tick()
                }
            } catch {
                model.claudeAuthorizationMessage = error.localizedDescription
            }
            model.isAuthorizingClaude = false
        }
    }

    private func tick() {
        guard !isPolling else { return }
        isPolling = true

        let codexMon = codex
        let claudeMon = claude
        let api = claudeAPI
        let codexLimits = codexAPI
        DispatchQueue.global(qos: .utility).async {
            var c = codexMon.poll()
            codexLimits.refreshIfNeeded()
            codexLimits.apply(to: &c)
            var cl = claudeMon.poll()

            // Attach Claude's official 5h / weekly usage from the API.
            api.refreshIfNeeded()
            if let snap = api.snapshot {
                if let f = snap.fiveHour {
                    cl.primary = UsageWindow(usedPercent: f.utilization,
                                             windowMinutes: 300, resetsAt: f.resetsAt)
                    cl.usageIsOfficial = true
                }
                if let d = snap.sevenDay {
                    cl.secondary = UsageWindow(usedPercent: d.utilization,
                                               windowMinutes: 10080, resetsAt: d.resetsAt)
                    cl.usageIsOfficial = true
                }
                cl.usageError = snap.error
            }

            Task { @MainActor in self.apply(codex: c, claude: cl) }
        }
    }

    private func apply(codex c0: AgentStatus, claude cl0: AgentStatus) {
        isPolling = false

        var c = c0
        var cl = cl0
        playTransitionSounds(codex: c0, claude: cl0)
        c.state = celebrate(previous: model.codex.state, raw: c0.state, until: &codexCompletedUntil)
        cl.state = celebrate(previous: model.claude.state, raw: cl0.state, until: &claudeCompletedUntil)

        notifyIfNeeded(old: model.codex, new: c)
        notifyIfNeeded(old: model.claude, new: cl)
        if model.claudeAuthorizationMessage?.contains("正在刷新官方用量") == true,
           cl.usageIsOfficial || cl.usageError != nil {
            model.claudeAuthorizationMessage = nil
        }
        model.codex = c
        model.claude = cl
        model.lastUpdated = Date()
        hasAppliedSnapshot = true
        model.onStatusesUpdated?()
        syncStatusIfNeeded()
        syncPhoneSettings()
    }

    func phonePreferencesChangedLocally() {
        phoneSettingsDirty = true
        syncPhoneSettings()
    }

    private func syncPhoneSettings() {
        guard !isSyncingPhoneSettings else { return }
        if phoneSettingsDirty {
            isSyncingPhoneSettings = true
            phoneSettingsDirty = false
            let phone = model.phonePreferences
            Task {
                defer { isSyncingPhoneSettings = false }
                do {
                    if let settings = try await sync.updatePhoneSettings(phone) {
                        applyPhoneSettings(settings)
                    }
                } catch {
                    phoneSettingsDirty = true   // retried next tick
                }
            }
        } else if Date().timeIntervalSince(lastPhoneSettingsFetch) >= phoneSettingsPollInterval {
            lastPhoneSettingsFetch = Date()
            isSyncingPhoneSettings = true
            Task {
                defer { isSyncingPhoneSettings = false }
                if let settings = try? await sync.fetchPhoneSettings() {
                    applyPhoneSettings(settings)
                }
            }
        }
    }

    private func applyPhoneSettings(_ settings: PhoneSettingsResponse) {
        // A local change still on its way wins; so does anything newer
        // than this read (status pushes race with the settings calls).
        guard !phoneSettingsDirty, settings.phoneRevision >= phoneSettingsRevision else { return }
        if settings.phoneRevision == 0, settings.phone != model.phonePreferences {
            // Never set on this relay (new pairing / older setup): the Mac's
            // own switches become the shared ones.
            phoneSettingsDirty = true
            return
        }
        phoneSettingsRevision = settings.phoneRevision
        model.applyRemotePhonePreferences(settings.phone)
    }

    /// Opening the panel refreshes Codex's quota (throttled) so it's current
    /// when you look at it.
    func refreshCodexUsage() {
        codexAPI.refreshIfNeeded(force: true)
    }

    /// Force an upload on the next opportunity (e.g. right after pairing).
    func pushStatusNow() {
        lastSyncedSignature = nil
        syncStatusIfNeeded()
    }

    private func syncStatusIfNeeded() {
        let signature = model.statuses
            .map { "\($0.tool.rawValue):\($0.state.rawValue):\($0.sessionTitle ?? "")" }
            .joined(separator: "|") + "|" + model.approvals.map(\.id).joined(separator: ",")
        let changed = signature != lastSyncedSignature
        guard !isSyncing,
              changed || Date().timeIntervalSince(lastSyncedAt) >= syncHeartbeat else { return }

        isSyncing = true
        let summary = StatusSyncSummary(
            overallState: model.overall,
            projectName: model.currentTrackedProjectName,
            stateText: model.currentTrackedStateText,
            updatedAt: model.lastUpdated
        )
        let statuses = model.statuses
        let approvals = model.approvals
        Task {
            defer { isSyncing = false }
            do {
                // nil = not paired with a server yet; nothing to do.
                guard let response = try await sync.push(statuses: statuses, summary: summary,
                                                       approvals: approvals) else { return }
                lastSyncedSignature = signature
                lastSyncedAt = Date()
                model.pairing.lastPushedAt = lastSyncedAt
                model.pairing.linkedMobileCount = response.deliveredTo
                model.pairing.syncFailed = false
                if let settings = response.phoneSettings { applyPhoneSettings(settings) }
            } catch {
                // Sync is optional; local monitoring must stay quiet and
                // reliable. Leaving the signature unchanged retries next tick.
                lastSyncedAt = Date()
                model.pairing.syncFailed = true
            }
        }
    }

    private func playTransitionSounds(codex c: AgentStatus, claude cl: AgentStatus) {
        guard hasAppliedSnapshot, model.soundEnabled else { return }

        let started = (model.codex.state != .working && c.state == .working)
            || (model.claude.state != .working && cl.state == .working)
        let finished = (model.codex.state == .working && c.state == .idle)
            || (model.claude.state == .working && cl.state == .idle)
        let needsApproval = (model.codex.state != .needsApproval && c.state == .needsApproval)
            || (model.claude.state != .needsApproval && cl.state == .needsApproval)

        if needsApproval {
            SoundPlayer.shared.playNeedsApproval()
        } else if started {
            SoundPlayer.shared.playTaskStarted()
        } else if finished {
            SoundPlayer.shared.playTaskFinished()
        }
    }

    /// Briefly show `.completed` when a task just finished (working→idle), then
    /// fall back to the raw state. `previous` is last tick's *displayed* state.
    private func celebrate(previous: AgentState, raw: AgentState, until: inout Date?) -> AgentState {
        // Fresh completion edge.
        if raw == .idle, previous == .working {
            until = Date().addingTimeInterval(completedLinger)
            return .completed
        }
        // Keep celebrating while idle and the timer is still alive.
        if raw == .idle, let deadline = until {
            if Date() < deadline { return .completed }
            until = nil
        }
        // Any non-idle activity cancels the celebration.
        if raw != .idle { until = nil }
        return raw
    }

    /// Fire a macOS notification when an agent newly needs approval.
    private func notifyIfNeeded(old: AgentStatus, new: AgentStatus) {
        guard new.state == .needsApproval, old.state != .needsApproval else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(new.tool.displayName) 需要审批"
        content.body = new.sessionTitle ?? "有一个操作等待你确认"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
