import Foundation

/// Reads ~/.codex to determine Codex's current state and usage.
struct CodexMonitor {
    let home = FileManager.default.homeDirectoryForCurrentUser

    func poll() -> AgentStatus {
        var status = AgentStatus(tool: .codex, state: .offline, detail: "未找到 Codex 会话")

        guard let session = latestSession() else { return status }

        let mtime = modificationDate(session)
        status.lastActivity = mtime

        let lines = readTail(session)
        var lastSignificant = ""            // working | done | approval
        var rateLimits: [String: Any]?
        var info: [String: Any]?

        for line in lines {
            guard let obj = parseLine(line),
                  let type = obj["type"] as? String else { continue }
            guard let payload = obj["payload"] as? [String: Any] else { continue }

            if type == "response_item" {
                let rt = payload["type"] as? String
                switch rt {
                case "function_call", "custom_tool_call":
                    if approvalRequested(in: payload) {
                        lastSignificant = "approval"
                    }
                case "function_call_output", "custom_tool_call_output":
                    if lastSignificant == "approval" {
                        lastSignificant = "working"
                    }
                default:
                    break
                }
                continue
            }

            guard type == "event_msg",
                  let pt = payload["type"] as? String else { continue }

            switch pt {
            case "token_count":
                if let i = payload["info"] as? [String: Any] { info = i }
                if let r = payload["rate_limits"] as? [String: Any] { rateLimits = r }
            case "task_started":
                lastSignificant = "working"
            case "patch_apply_end":
                if lastSignificant == "approval" {
                    lastSignificant = "working"
                }
            case "task_complete", "turn_complete", "turn_aborted", "thread_rolled_back":
                lastSignificant = "done"
            default:
                if pt.contains("approval_request") { lastSignificant = "approval" }
            }
        }

        let age = Date().timeIntervalSince(mtime)
        switch lastSignificant {
        case "approval":
            status.state = .needsApproval
            status.detail = "等待审批"
        case "working":
            if age < 90 {
                status.state = .working
                status.detail = "正在工作"
            } else {
                status.state = .idle
                status.detail = "空闲"
            }
        default:
            status.state = .idle
            status.detail = "空闲"
        }

        if let rateLimits {
            status.primary = usageWindow(rateLimits["primary"] as? [String: Any])
            status.secondary = usageWindow(rateLimits["secondary"] as? [String: Any])
            status.planType = rateLimits["plan_type"] as? String
            normalizeExpiredUsageWindows(on: &status)
        }

        if let info,
           let cw = num(info["model_context_window"]), cw > 0,
           let last = info["total_token_usage"] as? [String: Any],
           let used = num(last["total_tokens"]) {
            status.contextPercent = min(100, used / cw * 100)
        }

        // Git repo name when the session lives in one, else the product name.
        status.sessionTitle = gitProjectName(from: sessionCwd(session)) ?? appDisplayName
        if let t = status.sessionTitle, !t.isEmpty { status.detail += " · \(t)" }
        return status
    }

    // MARK: - helpers

    private func latestSession() -> URL? {
        let dir = home.appendingPathComponent(".codex/sessions")
        guard let en = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: URL?
        var bestDate = Date.distantPast
        for case let u as URL in en where u.pathExtension == "jsonl" {
            let d = modificationDate(u)
            if d > bestDate { bestDate = d; best = u }
        }
        return best
    }

    private func usageWindow(_ d: [String: Any]?) -> UsageWindow? {
        guard let d else { return nil }
        var w = UsageWindow()
        w.usedPercent = num(d["used_percent"])
        w.windowMinutes = num(d["window_minutes"]).map { Int($0) }
        if let r = num(d["resets_at"]) { w.resetsAt = Date(timeIntervalSince1970: r) }
        return w
    }

    private func normalizeExpiredUsageWindows(on status: inout AgentStatus) {
        normalizeExpiredUsageWindow(&status.primary)
        normalizeExpiredUsageWindow(&status.secondary)
    }

    private func normalizeExpiredUsageWindow(_ window: inout UsageWindow?) {
        guard var current = window,
              let resetsAt = current.resetsAt,
              resetsAt <= Date() else { return }

        current.usedPercent = 0
        current.resetsAt = nil
        window = current
    }

    private func approvalRequested(in payload: [String: Any]) -> Bool {
        if let arguments = payload["arguments"] as? String,
           arguments.contains("\"sandbox_permissions\":\"require_escalated\"")
            || arguments.contains("\"sandbox_permissions\": \"require_escalated\"") {
            return true
        }

        if let arguments = payload["arguments"] as? [String: Any],
           arguments["sandbox_permissions"] as? String == "require_escalated" {
            return true
        }

        return false
    }

    /// Reads `cwd` from the session header (`session_meta` first line, with a
    /// `turn_context` fallback). Used only to locate the enclosing git repo.
    private func sessionCwd(_ session: URL) -> String? {
        for line in readHead(session) {
            guard let obj = parseLine(line),
                  let payload = obj["payload"] as? [String: Any],
                  let cwd = payload["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }
}
