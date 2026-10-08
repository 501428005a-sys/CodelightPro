import Foundation

/// Live Codex quota straight from Codex's own `app-server`
/// (`account/rateLimits/read`). The session log only gains new numbers when a
/// message is sent; this refreshes them without touching Codex's conversation.
/// Codex handles its own auth — we never read its tokens. `CodexMonitor`'s
/// session-log values remain the fallback.
final class CodexRateLimitAPI: @unchecked Sendable {
    struct Snapshot {
        var primary: UsageWindow?
        var secondary: UsageWindow?
        var planType: String?
        let at: Date
    }

    /// Background refresh cadence, and the minimum gap for user-triggered ones
    /// (opening the panel) so repeated clicks don't spawn a process each time.
    private let interval: TimeInterval = 300
    private let manualGap: TimeInterval = 30
    private let timeout: TimeInterval = 15

    private let lock = NSLock()
    private var _snapshot: Snapshot?
    private var lastAttempt = Date.distantPast
    private var inFlight = false

    var snapshot: Snapshot? {
        lock.lock(); defer { lock.unlock() }
        return _snapshot
    }

    /// Overlay the live quota on a polled status, unless the session log has
    /// newer numbers (a message was sent after our last fetch).
    func apply(to status: inout AgentStatus) {
        guard let snap = snapshot,
              status.primary == nil || snap.at > (status.lastActivity ?? .distantPast) else { return }
        status.primary = Self.current(snap.primary) ?? status.primary
        status.secondary = Self.current(snap.secondary) ?? status.secondary
        status.planType = snap.planType ?? status.planType
    }

    /// A window whose reset time has passed is back to 0%.
    private static func current(_ window: UsageWindow?) -> UsageWindow? {
        guard var window, let resetsAt = window.resetsAt, resetsAt <= Date() else { return window }
        window.usedPercent = 0
        window.resetsAt = nil
        return window
    }

    /// Fire-and-forget; the result is picked up on a later poll.
    func refreshIfNeeded(force: Bool = false) {
        lock.lock()
        let gap = force ? manualGap : interval
        guard !inFlight, Date().timeIntervalSince(lastAttempt) >= gap else {
            lock.unlock()
            return
        }
        inFlight = true
        lastAttempt = Date()
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [self] in
            let result = fetch()
            lock.lock()
            if let result { _snapshot = result }
            inFlight = false
            lock.unlock()
        }
    }

    // MARK: - app-server round trip

    private func fetch() -> Snapshot? {
        guard let executable = Self.codexExecutable() else { return nil }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        // GUI apps get a bare PATH; an npm-installed codex needs `node`.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + Self.extraPaths.joined(separator: ":")
        process.environment = env

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        let reader = LineReader()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                done.signal()
                return
            }
            if reader.append(chunk, untilReplyID: 2) { done.signal() }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }

        let messages: [[String: Any]] = [
            ["id": 1, "method": "initialize",
             "params": ["clientInfo": ["name": "codelightpro", "title": "CodelightPro", "version": "0.1.0"]]],
            ["method": "initialized"],
            ["id": 2, "method": "account/rateLimits/read"],
        ]
        var payload = Data()
        for message in messages {
            guard let line = try? JSONSerialization.data(withJSONObject: message) else { return nil }
            payload.append(line)
            payload.append(0x0A)
        }
        try? input.fileHandleForWriting.write(contentsOf: payload)

        guard done.wait(timeout: .now() + timeout) == .success,
              let reply = reader.reply,
              let result = reply["result"] as? [String: Any],
              let limits = result["rateLimits"] as? [String: Any] else { return nil }

        return Snapshot(
            primary: Self.window(limits["primary"] as? [String: Any]),
            secondary: Self.window(limits["secondary"] as? [String: Any]),
            planType: limits["planType"] as? String,
            at: Date()
        )
    }

    private static func window(_ d: [String: Any]?) -> UsageWindow? {
        guard let d else { return nil }
        var w = UsageWindow()
        w.usedPercent = (d["usedPercent"] as? NSNumber)?.doubleValue
        w.windowMinutes = (d["windowDurationMins"] as? NSNumber)?.intValue
        if let r = (d["resetsAt"] as? NSNumber)?.doubleValue {
            w.resetsAt = Date(timeIntervalSince1970: r)
        }
        return w
    }

    // MARK: - Locating codex

    private static let extraPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
                "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin"]
    }()

    /// A standalone CLI first (PATH + usual install dirs), then the copy that
    /// ships inside the Codex / ChatGPT desktop apps.
    static func codexExecutable() -> URL? {
        let fm = FileManager.default
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let candidates = (pathDirs + extraPaths).map { "\($0)/codex" } + [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }
}

/// Splits app-server stdout into JSON-RPC lines and keeps the reply we want.
private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var reply: [String: Any]?

    /// Returns true once the reply with `id` has arrived.
    func append(_ chunk: Data, untilReplyID id: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard reply == nil else { return true }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
               (object["id"] as? NSNumber)?.intValue == id {
                reply = object
                return true
            }
        }
        return false
    }
}
