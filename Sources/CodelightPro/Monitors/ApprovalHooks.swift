import Foundation

/// The `PermissionRequest` hook shared by Claude Code and Codex (both accept
/// the same `hookSpecificOutput.decision` reply). It drops the request into
/// `~/.codelightpro/approvals/` for `ApprovalCenter`, which shows it on the
/// Mac panel and the paired iPhone, then waits for whichever answers first.
///
/// It never decides on its own: when the app isn't running, approvals are
/// off, the user picks "在终端处理", or nobody answers in time, it prints
/// nothing and the agent shows its usual prompt.
enum ApprovalHookScript {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codelightpro/approve.sh")
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codelightpro/approvals", isDirectory: true)

    /// How long the script waits for an answer before handing back to the
    /// agent's own prompt, and the (longer) timeout the agent gives the hook.
    static let waitSeconds = 300
    static let hookTimeout = 330

    /// `ApprovalCenter` refreshes this while approvals are on; an older stamp
    /// means the app is gone and the script must not hold anything up.
    static let heartbeatMaxAge = 10

    static func write() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let script = #"""
        #!/bin/bash
        # CodelightPro — PermissionRequest hook for Claude Code and Codex.
        # Shows the request on the Mac panel and the paired iPhone, and replies
        # with whichever answers first. No answer → prints nothing, so the agent
        # shows its usual prompt. $1 = claude | codex, stdin = hook event JSON.
        src="$1"
        dir="$HOME/.codelightpro/approvals"
        alive="$dir/.alive"

        app_alive() {
          [ -f "$alive" ] || return 1
          beat="$(cat "$alive" 2>/dev/null)"
          [ -n "$beat" ] && [ $(( $(date +%s) - beat )) -le __MAX_AGE__ ]
        }
        app_alive || exit 0

        payload="$(cat)"
        id="$(date +%s)-$$-$RANDOM"
        umask 077
        { printf '%s\n%s\n' "$src" "$$"; printf '%s' "$payload"; } > "$dir/$id.tmp" && mv "$dir/$id.tmp" "$dir/$id.req"
        trap 'rm -f "$dir/$id.req" "$dir/$id.res"' EXIT

        deadline=$(( $(date +%s) + __WAIT__ ))
        while [ "$(date +%s)" -lt "$deadline" ]; do
          if [ -f "$dir/$id.res" ]; then
            case "$(cat "$dir/$id.res")" in
              allow) printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}' ;;
              deny)  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"已在 CodelightPro 中拒绝"}}}' ;;
            esac
            exit 0
          fi
          app_alive || exit 0
          sleep 0.3
        done
        exit 0
        """#
            .replacingOccurrences(of: "__MAX_AGE__", with: String(heartbeatMaxAge))
            .replacingOccurrences(of: "__WAIT__", with: String(waitSeconds))
        try script.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

/// Adds the approval hook to `~/.codex/hooks.json`, keeping every other
/// entry. Codex asks the user to trust a new hook (in Codex, `/hooks`) before
/// it runs; until then Codex simply prompts as before.
struct CodexHookInstaller {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var hooksURL: URL { home.appendingPathComponent(".codex/hooks.json") }
    private var backupURL: URL { home.appendingPathComponent(".codex/hooks.json.codelightpro-backup") }

    func install() {
        // No Codex here at all → don't create its config directory.
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path) else { return }
        do {
            try ApprovalHookScript.write()
            try merge()
        } catch {
            NSLog("CodelightPro: Codex hook install failed — \(error.localizedDescription)")
        }
    }

    private func merge() throws {
        let command = "'\(ApprovalHookScript.url.path)' codex"

        var root: [String: Any] = [:]
        let original = try? Data(contentsOf: hooksURL)
        if let original {
            guard let parsed = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else {
                // Unreadable / unexpected file: leave it alone rather than clobber it.
                return
            }
            root = parsed
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let existing = hooks["PermissionRequest"]
        if existing != nil, (existing as? [[String: Any]]) == nil { return }
        var groups = (existing as? [[String: Any]]) ?? []

        let isOurs: ([String: Any]) -> Bool = { group in
            (group["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains(ApprovalHookScript.url.path) == true
            } ?? false
        }
        let upToDate = groups.contains { group in
            (group["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String) == command && ($0["timeout"] as? Int) == ApprovalHookScript.hookTimeout
            } ?? false
        }
        if upToDate { return }

        groups.removeAll(where: isOurs)
        groups.append(["hooks": [["type": "command", "command": command, "timeout": ApprovalHookScript.hookTimeout]]])
        hooks["PermissionRequest"] = groups
        root["hooks"] = hooks

        if let original, !FileManager.default.fileExists(atPath: backupURL.path) {
            try? original.write(to: backupURL)
        }
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: hooksURL, options: .atomic)
        NSLog("CodelightPro: installed Codex approval hook into \(hooksURL.path)")
    }
}
