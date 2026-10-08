import Foundation

final class StatusSyncClient {
    private let defaults = UserDefaults.standard
    private let session: URLSession

    private enum Key {
        static let serverURL = "sync.serverURL"
        static let deviceId = "sync.deviceId"
        static let desktopToken = "sync.desktopToken"
        static let registeredServerURL = "sync.registeredServerURL"
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    var configuredServerURL: String {
        defaults.string(forKey: Key.serverURL) ?? "http://localhost:3000"
    }

    func startPairing(serverURL rawServerURL: String) async throws -> PairingStartResponse {
        let serverURL = try normalizedServerURL(rawServerURL)
        defaults.set(serverURL, forKey: Key.serverURL)

        let registration = try await ensureDesktopRegistration(serverURL: serverURL)
        var request = try makeRequest(serverURL: serverURL, path: "/api/pairings/start")
        request.httpMethod = "POST"
        request.setValue("Bearer \(registration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        return try await send(request, as: PairingStartResponse.self)
    }

    func push(statuses: [AgentStatus], summary: StatusSyncSummary,
              approvals: [ApprovalRequest]) async throws -> StatusPushResponse? {
        guard let serverURL = defaults.string(forKey: Key.serverURL),
              let deviceId = defaults.string(forKey: Key.deviceId),
              let token = defaults.string(forKey: Key.desktopToken),
              !serverURL.isEmpty,
              !deviceId.isEmpty,
              !token.isEmpty else {
            return nil
        }

        let payload = DesktopStatusPayload(
            platform: "macOS",
            appVersion: "0.1.0",
            updatedAt: Date(),
            summary: summary,
            statuses: statuses,
            approvals: approvals
        )

        var request = try makeRequest(serverURL: serverURL, path: "/api/desktop/status")
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-CodelightPro-Device")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        request.httpBody = try encoder.encode(payload)

        return try await send(request, as: StatusPushResponse.self)
    }

    /// Approval answers made on the phone since the last call (the relay
    /// hands each one out once). Empty when not paired.
    func fetchApprovalDecisions() async throws -> [RemoteApprovalDecision] {
        guard let serverURL = defaults.string(forKey: Key.serverURL),
              let token = defaults.string(forKey: Key.desktopToken),
              !serverURL.isEmpty, !token.isEmpty else { return [] }
        var request = try makeRequest(serverURL: serverURL, path: "/api/desktop/approvals/decisions")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(request, as: RemoteApprovalDecisionsResponse.self).decisions
    }

    /// The shared phone settings; nil when not paired.
    func fetchPhoneSettings() async throws -> PhoneSettingsResponse? {
        guard let (serverURL, token) = credentials else { return nil }
        var request = try makeRequest(serverURL: serverURL, path: "/api/desktop/settings")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(request, as: PhoneSettingsResponse.self)
    }

    /// Writes the Mac's switches; nil when not paired.
    func updatePhoneSettings(_ phone: PhonePreferences) async throws -> PhoneSettingsResponse? {
        guard let (serverURL, token) = credentials else { return nil }
        var request = try makeRequest(serverURL: serverURL, path: "/api/desktop/settings")
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["phone": phone])
        return try await send(request, as: PhoneSettingsResponse.self)
    }

    private var credentials: (serverURL: String, token: String)? {
        guard let serverURL = defaults.string(forKey: Key.serverURL),
              let token = defaults.string(forKey: Key.desktopToken),
              !serverURL.isEmpty, !token.isEmpty else { return nil }
        return (serverURL, token)
    }

    private func ensureDesktopRegistration(serverURL: String) async throws -> DeviceRegistrationResponse {
        if defaults.string(forKey: Key.registeredServerURL) == serverURL,
           let deviceId = defaults.string(forKey: Key.deviceId),
           let token = defaults.string(forKey: Key.desktopToken),
           !deviceId.isEmpty,
           !token.isEmpty {
            return DeviceRegistrationResponse(deviceId: deviceId, token: token)
        }

        var request = try makeRequest(serverURL: serverURL, path: "/api/desktop/register")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = DeviceRegistrationRequest(
            name: Host.current().localizedName ?? "Mac",
            platform: "macOS"
        )
        request.httpBody = try JSONEncoder().encode(body)

        let registration = try await send(request, as: DeviceRegistrationResponse.self)
        defaults.set(serverURL, forKey: Key.registeredServerURL)
        defaults.set(registration.deviceId, forKey: Key.deviceId)
        defaults.set(registration.token, forKey: Key.desktopToken)
        return registration
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw SyncError.server(message)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }

    private func makeRequest(serverURL: String, path: String) throws -> URLRequest {
        guard let base = URL(string: serverURL),
              let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw SyncError.invalidServerURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        return request
    }

    private func normalizedServerURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutTrailingSlash = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: withoutTrailingSlash),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw SyncError.invalidServerURL
        }
        return withoutTrailingSlash
    }
}

enum SyncError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "服务器地址不正确，请填写 http:// 或 https:// 开头的地址。"
        case .invalidResponse:
            return "服务器响应格式不正确。"
        case .server(let message):
            return "服务器返回错误：\(message)"
        }
    }
}
