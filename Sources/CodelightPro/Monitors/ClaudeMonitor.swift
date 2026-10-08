import Foundation

/// Reads ~/.claude/projects to determine Claude Code's state and token usage.
///
/// Note: Claude's subscription rate-limit % is NOT stored locally, so we report
/// per-session token totals as an approximation. Approval detection is
/// best-effort: the permission prompt isn't written to the transcript until it
/// resolves, so we infer a *pending* tool call (assistant `tool_use` with no
/// following tool result).
struct ClaudeMonitor {
    let home = FileManager.default.homeDirectoryForCurrentUser
    private let freshWriteWindow: TimeInterval = 5
    private let responseInProgressWindow: TimeInterval = 15 * 60
    private let toolCallGraceWindow: TimeInterval = 2 * 60
    private let approvalWindow: TimeInterval = 10 * 60
    /// How long an event from the installed hooks stays authoritative.
    private let hookFreshWindow: TimeInterval = 60 * 60

    private enum LastEvent {
        case none
        case queueOperation
        case stopped
        case userPrompt
        case toolResult
        case assistant(stopReason: String?, hasToolUse: Bool, hasThinking: Bool, hasText: Bool)
    }

    func poll() -> AgentStatus {
        var status = AgentStatus(tool: .claude, state: .offline, detail: "未找到 Claude 会话")

        guard let session = latestSession() else { return status }

        let mtime = modificationDate(session)
        status.lastActivity = mtime

        let lines = readTail(session)
        var lastAssistantToolUse = false
        var resolvedAfter = false
        var lastEvent = LastEvent.none
        var sessionTokens = 0
        var cwd: String?

        for line in lines {
            guard let obj = parseLine(line),
                  let type = obj["type"] as? String else { continue }

            if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }

            switch type {
            case "last-prompt":
                lastAssistantToolUse = false
                resolvedAfter = false
                lastEvent = .userPrompt
            case "mode":
                if let mode = obj["mode"] as? String, mode == "normal" {
                    lastAssistantToolUse = false
                    resolvedAfter = true
                    lastEvent = .stopped
                }
            case "queue-operation":
                if let operation = obj["operation"] as? String,
                   operation == "enqueue" || operation == "dequeue" {
                    lastAssistantToolUse = false
                    resolvedAfter = false
                    lastEvent = .queueOperation
                }
            case "assistant":
                if let m = obj["message"] as? [String: Any] {
                    if let u = m["usage"] as? [String: Any] {
                        sessionTokens += Int(num(u["input_tokens"]) ?? 0)
                        sessionTokens += Int(num(u["output_tokens"]) ?? 0)
                    }
                    let stopReason = m["stop_reason"] as? String
                    let hasToolUse = messageContainsToolUse(m)
                    let hasThinking = messageContainsContentType(m, type: "thinking")
                    let hasText = messageContainsContentType(m, type: "text")
                    lastAssistantToolUse = stopReason == "tool_use" || hasToolUse
                    resolvedAfter = false
                    lastEvent = .assistant(
                        stopReason: stopReason,
                        hasToolUse: hasToolUse,
                        hasThinking: hasThinking,
                        hasText: hasText
                    )
                }
            case "user":
                if messageContainsToolResult(obj["message"] as? [String: Any]) {
                    resolvedAfter = true
                    lastEvent = .toolResult
                } else {
                    lastAssistantToolUse = false
                    resolvedAfter = false
                    lastEvent = .userPrompt
                }
            default:
                break
            }
        }

        let age = Date().timeIntervalSince(mtime)
        switch lastEvent {
        case .stopped:
            status.state = .idle
            status.detail = "空闲"
        case .queueOperation:
            if age < responseInProgressWindow {
                status.state = .working
                status.detail = "正在工作"
            } else {
                status.state = .idle
                status.detail = "空闲"
            }
        case .userPrompt:
            if age < responseInProgressWindow {
                status.state = .working
                status.detail = "正在思考"
            } else {
                status.state = .idle
                status.detail = "空闲"
            }
        case .toolResult:
            if age < responseInProgressWindow {
                status.state = .working
                status.detail = "正在处理工具结果"
            } else {
                status.state = .idle
                status.detail = "空闲"
            }
        case let .assistant(stopReason, hasToolUse, hasThinking, hasText):
            if lastAssistantToolUse && !resolvedAfter {
                if age < toolCallGraceWindow {
                    status.state = .working
                    status.detail = "正在调用工具"
                } else if age < approvalWindow {
                    status.state = .needsApproval
                    status.detail = "可能等待审批"
                } else {
                    status.state = .idle
                    status.detail = "空闲"
                }
            } else if hasThinking && !hasText {
                if age < responseInProgressWindow {
                    status.state = .working
                    status.detail = "正在思考"
                } else {
                    status.state = .idle
                    status.detail = "空闲"
                }
            } else if stopReason == nil || (stopReason == "tool_use" && !hasToolUse) {
                if age < responseInProgressWindow {
                    status.state = .working
                    status.detail = "正在工作"
                } else {
                    status.state = .idle
                    status.detail = "空闲"
                }
            } else if age < freshWriteWindow && stopReason != "end_turn" && stopReason != "stop_sequence" {
                status.state = .working
                status.detail = "正在工作"
            } else {
                status.state = .idle
                status.detail = "空闲"
            }
        case .none:
            if age < freshWriteWindow {
                status.state = .working
                status.detail = "正在工作"
            } else {
                status.state = .idle
                status.detail = "空闲"
            }
        }

        status.sessionTokens = sessionTokens

        // If the installed hooks have written a fresh, accurate state, trust it
        // over the transcript heuristic above (especially for "needs approval").
        if let hook = hookState(), Date().timeIntervalSince(hook.at) < hookFreshWindow {
            status.state = hook.state
            status.detail = hook.detail
            status.lastActivity = max(status.lastActivity ?? .distantPast, hook.at)
        }

        status.sessionTitle = gitProjectName(from: cwd) ?? appDisplayName
        if let t = status.sessionTitle, !t.isEmpty { status.detail += " · \(t)" }
        return status
    }

    // MARK: - hook signal

    /// Aggregates the per-session files in `~/.codelightpro/status/` (each written
    /// by our hooks: line 1 = state label, line 2 = unix epoch, rest = raw JSON).
    /// Across all fresh sessions, the most-urgent state wins — so if *any* session
    /// is waiting for approval, we surface it.
    private func hookState() -> (state: AgentState, at: Date, detail: String)? {
        let dir = home.appendingPathComponent(".codelightpro/status")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return nil }

        let now = Date()
        var best: (state: AgentState, at: Date, detail: String)?

        for file in files where file.pathExtension == "json" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
            guard let label = lines.first.map(String.init), !label.isEmpty else { continue }

            let at: Date
            if lines.count > 1, let epoch = TimeInterval(lines[1].trimmingCharacters(in: .whitespaces)) {
                at = Date(timeIntervalSince1970: epoch)
            } else {
                at = modificationDate(file)
            }
            guard now.timeIntervalSince(at) < hookFreshWindow else { continue }

            let mapped: (AgentState, String)
            switch label {
            case "working":  mapped = (.working, "正在工作")
            case "approval": mapped = (.needsApproval, "等待审批")
            case "idle":     mapped = (.idle, "空闲")
            case "done":     mapped = (.idle, "已完成")
            default:         continue
            }

            let candidate = (state: mapped.0, at: at, detail: mapped.1)
            if best == nil
                || hookPriority(candidate.state) > hookPriority(best!.state)
                || (hookPriority(candidate.state) == hookPriority(best!.state) && candidate.at > best!.at) {
                best = candidate
            }
        }
        return best
    }

    private func hookPriority(_ state: AgentState) -> Int {
        switch state {
        case .needsApproval: return 4
        case .working: return 3
        case .completed: return 2
        case .idle: return 1
        default: return 0
        }
    }

    // MARK: - helpers

    private func latestSession() -> URL? {
        let dir = home.appendingPathComponent(".claude/projects")
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

    private func messageContainsToolUse(_ message: [String: Any]) -> Bool {
        messageContainsContentType(message, type: "tool_use")
    }

    private func messageContainsContentType(_ message: [String: Any], type: String) -> Bool {
        guard let content = message["content"] as? [[String: Any]] else { return false }
        return content.contains { ($0["type"] as? String) == type }
    }

    private func messageContainsToolResult(_ message: [String: Any]?) -> Bool {
        guard let content = message?["content"] as? [[String: Any]] else { return false }
        return content.contains { ($0["type"] as? String) == "tool_result" }
    }
}
