import Foundation

enum ClaudeAuthorizationError: LocalizedError {
    case claudeCodeMissing
    case claudeUnavailable
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .claudeCodeMissing:
            return "未找到 Claude Code 终端版"
        case .claudeUnavailable:
            return "未安装 Claude Code，也未找到 Claude 桌面版登录"
        case .launchFailed(let message):
            return "启动 Claude Code 登录失败：\(message)"
        }
    }
}

enum ClaudeAuthorizationResult {
    case claudeCodeAlreadyLoggedIn
    case openedClaudeCodeLogin
    case importedClaudeDesktop
}

/// Connects Claude usage through the preferred local auth source:
/// 1. Claude Code CLI installed + logged in: use its stored OAuth automatically.
/// 2. Claude Code CLI installed but not logged in: open `claude auth login`.
/// 3. Claude Code CLI missing but Claude Desktop exists: import Desktop cookie.
/// 4. Neither exists: tell the user Claude is not installed.
final class ClaudeAuthorizer: @unchecked Sendable {
    func authorize() async throws -> ClaudeAuthorizationResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.authorizeSynchronously()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func authorizeSynchronously() throws -> ClaudeAuthorizationResult {
        if ClaudeCodeCLI.isInstalled {
            if ClaudeCodeCLI.isLoggedIn() {
                return .claudeCodeAlreadyLoggedIn
            }
            do {
                try ClaudeCodeCLI.openLoginWindow()
                return .openedClaudeCodeLogin
            } catch {
                throw ClaudeAuthorizationError.launchFailed(error.localizedDescription)
            }
        }

        if ClaudeDesktopCookieImporter.isInstalled {
            _ = try ClaudeDesktopCookieImporter().importSessionKey()
            return .importedClaudeDesktop
        }

        throw ClaudeAuthorizationError.claudeUnavailable
    }
}
