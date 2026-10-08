import Foundation

/// Which agent this status describes.
enum AgentTool: String, Codable {
    case codex
    case claude

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }
}

/// High-level state of an agent, shared across all platforms (mac/win/ios).
enum AgentState: String, Codable {
    case idle           // 空闲：有会话但没在动
    case working        // 正在工作
    case completed      // 刚完成任务（working→idle 后短暂展示）
    case needsApproval  // 需要审批
    case error          // 出错
    case offline        // 没找到会话 / 未运行

    var label: String {
        switch self {
        case .idle: return "空闲"
        case .working: return "工作中"
        case .completed: return "已完成"
        case .needsApproval: return "需审批"
        case .error: return "出错"
        case .offline: return "未运行"
        }
    }
}

/// One usage window (e.g. Codex 5h primary / weekly secondary).
struct UsageWindow: Codable {
    var usedPercent: Double?
    var windowMinutes: Int?
    var resetsAt: Date?
}

/// The portable status record. This is the contract shared with Windows & iOS
/// (see PROTOCOL.md). Desktop apps fill it from local files; future server
/// relays it as JSON to iOS.
struct AgentStatus: Codable, Identifiable {
    var id: String { tool.rawValue }

    var tool: AgentTool
    var state: AgentState
    var detail: String = ""

    var sessionTitle: String?

    // Codex: exact rate-limit windows.
    var primary: UsageWindow?     // 5 小时额度
    var secondary: UsageWindow?   // 周窗口
    var planType: String?

    // Claude: per-session token count (bonus info alongside the official %).
    var sessionTokens: Int?
    var contextPercent: Double?   // 上下文窗口占用（可选）

    // Claude local fallback (when official % isn't available): rolling-window
    // token totals + estimated cost, aggregated across all local sessions.
    var windowTokens: Int?        // 滚动 5 小时
    var weekTokens: Int?          // 本周
    var windowCostUSD: Double?
    var weekCostUSD: Double?
    var usageIsOfficial: Bool = false   // true = primary/secondary are official %

    // Surface API problems (token expired / rate limited) to the UI.
    var usageError: String?

    var lastActivity: Date?
}
