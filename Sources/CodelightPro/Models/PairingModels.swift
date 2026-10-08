import Foundation

struct DeviceRegistrationRequest: Codable {
    let name: String
    let platform: String
}

struct DeviceRegistrationResponse: Codable {
    let deviceId: String
    let token: String
}

struct PairingStartResponse: Codable {
    let pairingId: String
    let code: String
    let pairUrl: String
    let qrDataUrl: String
    let expiresAt: TimeInterval
}

struct PairingDisplayState: Equatable {
    var serverURL: String = UserDefaults.standard.string(forKey: "sync.serverURL") ?? "http://localhost:3000"
    var isLoading = false
    var message: String?
    var qrDataURL: String?
    var pairURL: String?
    var expiresAt: Date?
    var lastPushedAt: Date?
    var linkedMobileCount: Int?
    /// The last upload to the relay failed (server down, offline, …).
    var syncFailed = false
    /// Set when a phone just claimed the code: plays the success animation
    /// before the window closes.
    var pairedAt: Date?
}

/// How the Mac is linked to the iPhone, as shown in the expanded panel.
enum PhoneLinkState: Equatable {
    /// Never paired with a relay (or no upload has happened yet).
    case notPaired
    /// Registered with the relay, but no phone has claimed a pairing.
    case noPhone
    case connected(Int)
    case unreachable

    var label: String {
        switch self {
        case .notPaired: return "未连接 iPhone"
        case .noPhone: return "未绑定 iPhone"
        case .connected(1): return "已连接 iPhone"
        case .connected(let count): return "已连接 \(count) 台 iPhone"
        case .unreachable: return "iPhone 连接中断"
        }
    }
}

struct StatusSyncSummary: Codable {
    let overallState: AgentState
    let projectName: String
    let stateText: String
    let updatedAt: Date
}

struct DesktopStatusPayload: Codable {
    let platform: String
    let appVersion: String
    let updatedAt: Date
    let summary: StatusSyncSummary
    let statuses: [AgentStatus]
    /// Pending permission requests the phone can answer.
    let approvals: [ApprovalRequest]
}

/// What the paired phones may do with this Mac's status. One copy lives on
/// the relay; the Mac panel and the phone app both change it.
struct PhonePreferences: Codable, Equatable {
    /// Off: no Live Activity is started or updated, a running one is ended.
    let liveActivity: Bool
    /// Off: Live Activity updates carry no alert.
    let alerts: Bool
    /// Off: phones get no pending approvals and can't answer them.
    let approvals: Bool
}

struct StatusPushResponse: Codable {
    let ok: Bool
    let deliveredTo: Int
    /// Missing from relays without shared phone settings.
    let phone: PhonePreferences?
    let phoneRevision: Int?

    var phoneSettings: PhoneSettingsResponse? {
        guard let phone, let phoneRevision else { return nil }
        return PhoneSettingsResponse(phone: phone, phoneRevision: phoneRevision)
    }
}

struct PhoneSettingsResponse: Codable {
    let phone: PhonePreferences
    /// Grows with every change on the relay; 0 = never set.
    let phoneRevision: Int
}
