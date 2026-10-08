import Foundation

/// Installs lightweight, side-effect-only Claude Code hooks so we get an
/// *accurate* state signal (especially "needs approval", which the transcript
/// can't reveal). Each hook just appends one line to `~/.codelightpro/claude-status`;
/// `Notification` / `Stop` hooks have no decision power, so they can never change
/// Claude's behavior.
///
/// The one exception is the `PermissionRequest` approval hook (`approve.sh`,
/// see `ApprovalHookScript`): it can answer allow / deny, but only with a
/// decision the user made on the Mac panel or the paired iPhone, and it falls
/// back to Claude's own prompt whenever there's no answer.
///
/// Safe by construction: backs up the original `settings.json` once, merges only
/// our entries (idempotent), and leaves everything else untouched.
struct ClaudeHookInstaller {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private var supportDir: URL { home.appendingPathComponent(".codelightpro") }
    private var scriptURL: URL { supportDir.appendingPathComponent("hook.sh") }
    private var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    private var backupURL: URL { home.appendingPathComponent(".claude/settings.json.codelightpro-backup") }

    private struct Entry {
        let event: String
        let matcher: String?
        let command: String
        var timeout: Int?
    }

    private var desired: [Entry] {
        statusHooks.map { Entry(event: $0.event, matcher: $0.matcher, command: "\(scriptURL.path) \($0.arg)") } + [
            Entry(event: "PermissionRequest", matcher: nil,
                  command: "\(ApprovalHookScript.url.path) claude",
                  timeout: ApprovalHookScript.hookTimeout),
        ]
    }

    /// (event, matcher, state-label-passed-to-script)
    private var statusHooks: [(event: String, matcher: String?, arg: String)] {
        [
            ("SessionStart", nil, "idle"),
            ("UserPromptSubmit", nil, "working"),
            // Fires after a tool runs — clears a stale "approval" once the user
            // has granted it and Claude resumes working.
            ("PostToolUse", nil, "working"),
            ("PermissionRequest", nil, "approval"),
            ("Stop", nil, "done"),
            // No matcher — fires on every notification; the script classifies it
            // from the payload (robust to whatever notification_type is used).
            ("Notification", nil, "notify"),
            ("SessionEnd", nil, "offline"),
        ]
    }

    func install() {
        do {
            try writeScript()
            try ApprovalHookScript.write()
            try mergeSettings()
        } catch {
            NSLog("CodelightPro: hook install failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Script

    private func writeScript() throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let script = #"""
        #!/bin/bash
        # CodelightPro — records each Claude Code session's live state for the
        # floating monitor. $1 = state label, or "notify" to classify from the
        # event payload. stdin = the hook event JSON. Writes files only; never
        # alters Claude's behavior.
        arg="$1"
        payload="$(cat)"

        # Per-session file so concurrent sessions don't overwrite each other.
        sid="$(printf '%s' "$payload" | sed -n 's/.*"session_id"[^"]*"\([^"]*\)".*/\1/p' | head -n1)"
        [ -z "$sid" ] && sid="default"

        dir="$HOME/.codelightpro/status"
        mkdir -p "$dir"

        # Debug trail: records every event so we can verify what actually fires.
        log="$HOME/.codelightpro/events.log"
        ntype="$(printf '%s' "$payload" | sed -n 's/.*"notification_type"[^"]*"\([^"]*\)".*/\1/p' | head -n1)"
        hname="$(printf '%s' "$payload" | sed -n 's/.*"hook_event_name"[^"]*"\([^"]*\)".*/\1/p' | head -n1)"
        printf '%s arg=%s sid=%s event=%s ntype=%s\n' "$(date +%s)" "$arg" "$sid" "$hname" "$ntype" >> "$log"
        tail -n 200 "$log" > "$log.tmp" 2>/dev/null && mv "$log.tmp" "$log"

        # Session ended: drop its file so it stops counting.
        if [ "$arg" = "offline" ]; then
          rm -f "$dir/$sid.json"
          exit 0
        fi

        state="$arg"
        if [ "$arg" = "notify" ]; then
          case "$payload" in
            *permission_prompt*|*"needs your permission"*|*"permission to use"*) state="approval" ;;
            *) state="idle" ;;
          esac
        fi

        { printf '%s\n%s\n' "$state" "$(date +%s)"; printf '%s' "$payload"; } > "$dir/$sid.json"
        exit 0
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    // MARK: - settings.json merge

    private func mergeSettings() throws {
        var root: [String: Any] = [:]
        var originalData: Data?
        if let data = try? Data(contentsOf: settingsURL) {
            originalData = data
            root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]

        // Idempotent: if every entry is already present, do nothing.
        func present(_ entry: Entry) -> Bool {
            guard let arr = hooks[entry.event] as? [[String: Any]] else { return false }
            return arr.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains {
                    ($0["command"] as? String) == entry.command
                        && ($0["timeout"] as? Int) == entry.timeout
                } ?? false
            }
        }
        if desired.allSatisfy(present) { return }

        // Build our groups per event.
        var ours: [String: [[String: Any]]] = [:]
        for d in desired {
            var hook: [String: Any] = ["type": "command", "command": d.command]
            if let timeout = d.timeout { hook["timeout"] = timeout }
            var group: [String: Any] = ["hooks": [hook]]
            if let matcher = d.matcher { group["matcher"] = matcher }
            ours[d.event, default: []].append(group)
        }

        func isOurs(_ group: [String: Any]) -> Bool {
            (group["hooks"] as? [[String: Any]])?.contains {
                guard let command = $0["command"] as? String else { return false }
                return command.contains("/.codelightpro/hook.sh") || command.contains(ApprovalHookScript.url.path)
            } ?? false
        }

        // Drop any prior CodelightPro entries, then append fresh ones. If an
        // event already exists in an unexpected shape, leave it completely alone.
        for (event, groups) in ours {
            let existing = hooks[event]
            if existing != nil, (existing as? [[String: Any]]) == nil { continue }
            var arr = (existing as? [[String: Any]]) ?? []
            arr.removeAll(where: isOurs)
            arr.append(contentsOf: groups)
            hooks[event] = arr
        }
        root["hooks"] = hooks

        // Back up the pristine original exactly once.
        if let originalData, !FileManager.default.fileExists(atPath: backupURL.path) {
            try? originalData.write(to: backupURL)
        }

        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL, options: .atomic)
        NSLog("CodelightPro: installed Claude Code hooks into \(settingsURL.path)")
    }
}
