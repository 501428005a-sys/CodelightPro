import Foundation

/// A pending permission request from Claude Code or Codex, caught by the
/// `PermissionRequest` hook. Shown on the Mac panel and uploaded to the relay
/// so the paired iPhone can answer it too (see PROTOCOL.md).
struct ApprovalRequest: Codable, Identifiable, Equatable {
    let id: String
    let tool: AgentTool
    /// The agent's tool name: Bash, Edit, apply_patch, …
    let toolName: String
    /// What's being asked for: the command, the file, or the raw input.
    let summary: String
    let project: String?
    let createdAt: Date
}

enum ApprovalDecision: String, Codable {
    case allow
    case deny
    /// Hand back to the agent's own prompt (in the terminal / Codex app).
    case terminal = "ask"
}

/// A decision made on the phone, fetched back from the relay.
struct RemoteApprovalDecision: Codable {
    let id: String
    let decision: ApprovalDecision
}

struct RemoteApprovalDecisionsResponse: Codable {
    let decisions: [RemoteApprovalDecision]
}

extension ApprovalRequest {
    /// Parses a file written by `approve.sh`: source, hook pid, then the hook
    /// event JSON.
    static func parse(id: String, contents: String) -> (request: ApprovalRequest, pid: pid_t, event: [String: Any])? {
        let parts = contents.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let pid = pid_t(parts[1].trimmingCharacters(in: .whitespaces)),
              let data = parts[2].data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        let tool: AgentTool = parts[0] == "codex" ? .codex : .claude
        let toolName = event["tool_name"] as? String ?? "Tool"
        let input = event["tool_input"]
        let cwd = event["cwd"] as? String
        let seconds = Double(id.split(separator: "-").first ?? "") ?? Date().timeIntervalSince1970

        let request = ApprovalRequest(
            id: id,
            tool: tool,
            toolName: toolName,
            summary: summary(of: input),
            project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 },
            createdAt: Date(timeIntervalSince1970: seconds)
        )
        return (request, pid, event)
    }

    private static func summary(of input: Any?) -> String {
        let text: String
        if let dict = input as? [String: Any] {
            if let command = dict["command"] as? String {
                text = command
            } else if let command = dict["command"] as? [String] {
                text = command.joined(separator: " ")
            } else if let path = dict["file_path"] as? String {
                text = path
            } else if let patch = dict["input"] as? String ?? dict["patch"] as? String {
                text = patch
            } else if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]) {
                text = String(decoding: data, as: UTF8.self)
            } else {
                text = ""
            }
        } else if let string = input as? String {
            text = string
        } else {
            text = ""
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 600 ? String(trimmed.prefix(600)) + "…" : trimmed
    }
}
