import Foundation

struct ClaudeCodeCLI {
    struct AuthStatus {
        let loggedIn: Bool
        let authMethod: String?
        let apiProvider: String?
    }

    static var executableURL: URL? {
        if let path = findInPath("claude") {
            return URL(fileURLWithPath: path)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static var isInstalled: Bool {
        executableURL != nil
    }

    static func authStatus() -> AuthStatus? {
        guard let executableURL else { return nil }
        guard let output = run(executableURL: executableURL, arguments: ["auth", "status"]) else {
            return nil
        }
        guard let data = output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return AuthStatus(
            loggedIn: obj["loggedIn"] as? Bool ?? false,
            authMethod: obj["authMethod"] as? String,
            apiProvider: obj["apiProvider"] as? String
        )
    }

    static func isLoggedIn() -> Bool {
        authStatus()?.loggedIn == true
    }

    static func version() -> String {
        guard let executableURL,
              let output = run(executableURL: executableURL, arguments: ["--version"]),
              let version = output.split(separator: " ").first else {
            return "2.1.183"
        }
        return String(version)
    }

    static func openLoginWindow() throws {
        guard let executableURL else {
            throw ClaudeAuthorizationError.claudeCodeMissing
        }

        let script = """
        #!/bin/zsh
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        clear
        echo "CodelightPro needs Claude Code login to show official usage."
        echo
        "\(executableURL.path)" auth login --claudeai
        echo
        echo "Login finished. You can close this window and return to CodelightPro."
        echo "Press any key to close..."
        read -k 1
        """

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codelightpro-claude-login-\(UUID().uuidString).command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, S_IRUSR | S_IWUSR | S_IXUSR)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.path]
        try process.run()
    }

    private static func run(executableURL: URL, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "\(executableURL.deletingLastPathComponent().path):\(ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")"
        ]) { _, new in new }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    private static func findInPath(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zsh", "-lc", "command -v \(command)"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
