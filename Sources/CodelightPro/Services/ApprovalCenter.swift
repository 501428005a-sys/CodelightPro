import Foundation

/// Bridges the `approve.sh` hook and the UI: picks up pending requests from
/// `~/.codelightpro/approvals/`, publishes them on `AppModel`, writes the
/// decision back for the waiting hook, and collects answers made on the
/// paired iPhone. Whichever side answers first wins.
@MainActor
final class ApprovalCenter {
    private let model: AppModel
    private let sync: StatusSyncClient
    private var timer: Timer?
    private var isScanning = false
    private var remotePoll: Task<Void, Never>?

    /// Called whenever the pending list changes; `added` when a new request
    /// arrived (so the panel can pop open).
    var onChange: ((_ added: Bool) -> Void)?

    init(model: AppModel, sync: StatusSyncClient) {
        self.model = model
        self.sync = sync
    }

    func start() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    func decide(_ id: String, _ decision: ApprovalDecision) {
        guard model.approvals.contains(where: { $0.id == id }) else { return }
        model.approvals.removeAll { $0.id == id }
        let url = ApprovalHookScript.directory.appendingPathComponent("\(id).res")
        DispatchQueue.global(qos: .userInitiated).async {
            try? Data(decision.rawValue.utf8).write(to: url, options: .atomic)
        }
        onChange?(false)
    }

    // MARK: - Scanning

    private func scan() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .utility).async {
            let found = Self.readPending()
            Task { @MainActor in
                self.isScanning = false
                self.apply(found)
            }
        }
    }

    private func apply(_ found: [ApprovalRequest]) {
        let old = Set(model.approvals.map(\.id))
        let new = Set(found.map(\.id))
        if old != new {
            model.approvals = found
            onChange?(!new.subtracting(old).isEmpty)
        }
        if !found.isEmpty, remotePoll == nil {
            startRemotePolling()
        }
    }

    /// Heartbeat + read requests. Runs off the main thread.
    nonisolated private static func readPending() -> [ApprovalRequest] {
        let fm = FileManager.default
        let dir = ApprovalHookScript.directory
        let alive = dir.appendingPathComponent(".alive")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? Data(String(Int(Date().timeIntervalSince1970)).utf8).write(to: alive, options: .atomic)

        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var pending: [ApprovalRequest] = []
        for file in files where file.pathExtension == "req" {
            let id = file.deletingPathExtension().lastPathComponent
            guard let contents = try? String(contentsOf: file, encoding: .utf8),
                  let (request, pid, event) = ApprovalRequest.parse(id: id, contents: contents) else { continue }
            // The agent killed the hook (e.g. the user interrupted it): the
            // request is moot, and the hook's own cleanup never ran.
            guard kill(pid, 0) == 0 || errno == EPERM else {
                try? fm.removeItem(at: file)
                continue
            }
            // Answered in Claude's own prompt: Claude doesn't stop the hook,
            // so release it ("ask" makes it exit without a decision).
            if request.tool == .claude, answeredInClaude(request, event: event) {
                let res = dir.appendingPathComponent("\(id).res")
                try? Data(ApprovalDecision.terminal.rawValue.utf8).write(to: res, options: .atomic)
                continue
            }
            if request.tool == .claude, commandRunning(event: event, hookPID: pid) {
                let res = dir.appendingPathComponent("\(id).res")
                try? Data(ApprovalDecision.terminal.rawValue.utf8).write(to: res, options: .atomic)
                markWorking(sessionID: event["session_id"] as? String)
                continue
            }
            pending.append(request)
        }
        return pending.sorted { $0.createdAt < $1.createdAt }
    }

    /// Claude Code runs the `PermissionRequest` hook alongside its own prompt
    /// and leaves it running after the user answers there, so the request
    /// would linger until the hook times out. Nothing reports the answer
    /// itself; the first later sign is the session's next status event
    /// (written by `hook.sh`): the same tool finishing, or the turn moving on.
    nonisolated private static func answeredInClaude(_ request: ApprovalRequest, event: [String: Any]) -> Bool {
        guard let sid = event["session_id"] as? String, !sid.isEmpty else { return false }
        let statusFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codelightpro/status/\(sid).json")
        guard let text = try? String(contentsOf: statusFile, encoding: .utf8) else { return false }
        let lines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard lines.count == 3, lines[0] != "approval",
              let epoch = TimeInterval(lines[1].trimmingCharacters(in: .whitespaces)),
              epoch >= request.createdAt.timeIntervalSince1970,
              let data = lines[2].data(using: .utf8),
              let latest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }

        switch latest["hook_event_name"] as? String {
        case "Stop", "UserPromptSubmit", "SessionStart":
            return true
        case "PostToolUse":
            // Other tools of the same turn can finish while this one still
            // waits, so only the requested call itself counts.
            guard (latest["tool_name"] as? String) == (event["tool_name"] as? String) else { return false }
            switch (latest["tool_input"], event["tool_input"]) {
            case let (a as NSObject, b as NSObject): return a.isEqual(b)
            case (nil, nil): return true
            default: return false
            }
        default:
            return false
        }
    }

    /// A long-running command sends no hook event until it finishes, but once
    /// approved Claude runs it in a child shell (`zsh -c … eval '<command>'`),
    /// so seeing that shell means the prompt was answered.
    nonisolated private static func commandRunning(event: [String: Any], hookPID: pid_t) -> Bool {
        guard (event["tool_name"] as? String) == "Bash",
              let command = (event["tool_input"] as? [String: Any])?["command"] as? String,
              !command.isEmpty else { return false }

        // The hook runs under Claude, possibly via a shell. Match by "not a
        // shell": the CLI's executable is named after its version (2.1.x).
        let shells: Set<String> = ["bash", "sh", "zsh", "dash"]
        var claude: pid_t?
        var pid = hookPID
        for _ in 0..<4 {
            guard let parent = ProcessTree.parent(of: pid), let name = ProcessTree.name(of: parent) else { break }
            if !shells.contains(name) { claude = parent; break }
            pid = parent
        }
        guard let claude else { return false }

        let quoted = command.replacingOccurrences(of: "'", with: "'\\''")
        return ProcessTree.children(of: claude).contains { child in
            guard child != pid, let args = ProcessTree.arguments(of: child) else { return false }
            return args.contains(quoted) && !args.contains(ApprovalHookScript.url.path)
        }
    }

    /// Lifts the session's hook state off "approval" so the panel doesn't keep
    /// showing 等待审批 while the approved command runs.
    nonisolated private static func markWorking(sessionID: String?) {
        guard let sessionID, !sessionID.isEmpty else { return }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codelightpro/status/\(sessionID).json")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard lines.count == 3, lines[0] == "approval" else { return }
        let updated = "working\n\(Int(Date().timeIntervalSince1970))\n\(lines[2])"
        try? updated.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - Answers from the phone

    private func startRemotePolling() {
        remotePoll = Task { [weak self] in
            while let self, !Task.isCancelled, !self.model.approvals.isEmpty {
                if let decisions = try? await self.sync.fetchApprovalDecisions() {
                    for decision in decisions {
                        self.decide(decision.id, decision.decision)
                    }
                }
                try? await Task.sleep(for: .milliseconds(1500))
            }
            self?.remotePoll = nil
        }
    }
}
