import Foundation

/// Fetches Claude Code's *official* subscription usage from the undocumented
/// `/api/oauth/usage` endpoint (the same one `claude /status` uses).
///
/// Auth = the OAuth access token Claude Code already stored locally. We never
/// write it ourselves; we just read it to call the API on the user's behalf and
/// display their own usage. If Claude Code CLI is not installed, we can fall
/// back to Claude Desktop's web session cookie.
///
/// Throttled hard (default 60s) — without the `User-Agent: claude-code/...`
/// header the endpoint 429s aggressively, and even with it we stay polite.
final class ClaudeUsageAPI: @unchecked Sendable {
    private enum TokenSource {
        case environment
        case setupToken
        case keychain
        case credentialsFile
    }

    /// Result of a single source's fetch attempt, so `fetch()` can fall back
    /// from the Claude Code (OAuth) path to the Claude web/desktop path.
    private enum FetchOutcome {
        case success(Snapshot)
        case rateLimited(retryAfter: TimeInterval?)
        /// Claude Code's stored access token is past `expiresAt`. We skip the
        /// request entirely (a dead token only earns a misleading 429).
        case expired
        /// The server rejected the credential (401/403). For the desktop
        /// session this means the saved cookie is stale and worth re-importing.
        case unauthorized(String)
        case failure(String)
    }

    private enum OrgResult {
        case id(String)
        case outcome(FetchOutcome)
    }

    struct Window {
        let utilization: Double   // 0–100
        let resetsAt: Date?
    }
    struct Snapshot {
        var fiveHour: Window?
        var sevenDay: Window?
        var error: String?
        let at: Date
    }

    private let lock = NSLock()
    private var _snapshot: Snapshot?
    private var lastAttempt = Date.distantPast
    /// After a 429 we must not poll again until this time (driven by the
    /// server's `Retry-After`). This is the "auto-retry" the UI promises.
    private var nextAllowedAttempt = Date.distantPast
    private var inFlight = false

    var snapshot: Snapshot? {
        lock.lock(); defer { lock.unlock() }
        return _snapshot
    }

    /// Request a refresh after an explicit user action (e.g. tapping "connect").
    ///
    /// Unlike a naive force, this does NOT bypass throttling: the official usage
    /// endpoint is aggressively rate-limited and shares its tiny budget with the
    /// background poller and the `claude` CLI, so a double-tap — or a tap right
    /// after a background poll — must not fire a second request, or it 429s. If
    /// we already hold usage data we keep it; otherwise we allow a near-immediate
    /// fetch but still honour any active 429 backoff window.
    func forceRefresh() {
        lock.lock()
        let hasUsage = _snapshot.map { $0.fiveHour != nil || $0.sevenDay != nil } ?? false
        lock.unlock()
        refreshIfNeeded(interval: hasUsage ? 30 : 3)
    }

    /// Kick off a refresh if enough time has passed. Non-blocking: the actual
    /// network call runs on a background queue and updates `snapshot` later.
    func refreshIfNeeded(interval: TimeInterval = 60) {
        lock.lock()
        let now = Date()
        let due = now.timeIntervalSince(lastAttempt) >= interval
            && now >= nextAllowedAttempt
            && !inFlight
        if due { lastAttempt = now; inFlight = true }
        lock.unlock()
        guard due else { return }
        DispatchQueue.global(qos: .utility).async { [self] in fetch() }
    }

    private func finish(_ snap: Snapshot) {
        lock.lock(); _snapshot = snap; inFlight = false; lock.unlock()
    }

    /// Record a failed fetch. Transient failures (notably 429 rate-limiting)
    /// keep any previously fetched usage so the UI doesn't flash empty, and a
    /// non-nil `retryAfter` pushes out the next allowed attempt so we actually
    /// back off instead of hammering the endpoint.
    ///
    /// `keepStale: false` discards any previously fetched windows. Use it for
    /// auth failures (expired/401/403): re-login is required, so the old data is
    /// meaningless — and keeping it would leave `primary` non-nil, which hides
    /// the re-login prompt and freezes the UI on a stale "即将重置" countdown.
    private func fail(_ message: String, retryAfter: TimeInterval? = nil, keepStale: Bool = true) {
        lock.lock()
        if let retryAfter {
            // Honour the server's window (it can be tens of minutes); just guard
            // against absurd values so we never wedge for longer than an hour.
            nextAllowedAttempt = Date().addingTimeInterval(min(max(retryAfter, 5), 3600))
        }
        if keepStale, let prev = _snapshot, prev.fiveHour != nil || prev.sevenDay != nil {
            _snapshot = Snapshot(fiveHour: prev.fiveHour, sevenDay: prev.sevenDay,
                                 error: message, at: Date())
        } else {
            _snapshot = Snapshot(error: message, at: Date())
        }
        inFlight = false
        lock.unlock()
    }

    /// Parse a `Retry-After` header (delta-seconds or HTTP-date).
    private func retryAfterSeconds(from resp: HTTPURLResponse?) -> TimeInterval? {
        guard let raw = resp?.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let secs = TimeInterval(raw) { return secs }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        if let date = fmt.date(from: raw) { return max(0, date.timeIntervalSinceNow) }
        return nil
    }

    /// Orchestrates the fallback chain: try the Claude Code (OAuth) path first;
    /// if it can't refresh the quota (rate-limited or any other failure), fall
    /// back to the Claude web/desktop session — a different host/auth that may
    /// still work. Only when BOTH are exhausted do we surface an error, and we
    /// prefer a concrete rate-limit countdown when one is available.
    private func fetch() {
        // 1. Claude Code OAuth token — but only if it hasn't expired. An expired
        //    access token earns a 429 that masquerades as rate-limiting, so we
        //    detect expiry locally and skip the doomed request.
        var codeOutcome: FetchOutcome?
        if let token = readToken() {
            if let exp = token.expiresAt, exp <= Date() {
                codeOutcome = .expired
            } else {
                codeOutcome = fetchOAuth(token: token.value, source: token.source)
            }
        } else if ClaudeCodeCLI.isInstalled {
            codeOutcome = .failure("请先登录 Claude Code")
        }
        if case .success(let snap)? = codeOutcome { finish(snap); return }

        // 2. Fallback: Claude web/desktop session. When the CLI side is expired
        //    (or otherwise failed) we test the desktop login — if it works we
        //    show its usage and stay silent, only nagging to re-login when this
        //    also fails.
        var webOutcome: FetchOutcome?
        if let (sessionKey, wasSaved) = desktopSessionKey() {
            webOutcome = fetchWeb(sessionKey: sessionKey)
            // A saved key can go stale while Claude Desktop itself stays logged
            // in with a newer cookie. Drop it and retry once with the live one.
            if case .unauthorized? = webOutcome, wasSaved {
                ClaudeDesktopCookieImporter.deleteSavedSessionKey()
                if let (liveKey, _) = desktopSessionKey(), liveKey != sessionKey {
                    webOutcome = fetchWeb(sessionKey: liveKey)
                }
            }
        } else if codeOutcome == nil, ClaudeDesktopCookieImporter.isInstalled {
            webOutcome = .failure("请导入 Claude 桌面版登录")
        }
        if case .success(let snap)? = webOutcome { finish(snap); return }

        // 3. Both paths failed. Surface the most useful message.
        reportFailure(codeOutcome: codeOutcome, webOutcome: webOutcome)
    }

    /// The Claude desktop session key: prefer a previously-saved one, otherwise
    /// extract it live from the desktop app's cookie store (and cache it).
    private func desktopSessionKey() -> (key: String, wasSaved: Bool)? {
        if let saved = ClaudeDesktopCookieImporter.readSavedSessionKey() { return (saved, true) }
        guard ClaudeDesktopCookieImporter.isInstalled,
              let live = try? ClaudeDesktopCookieImporter().importSessionKey() else { return nil }
        return (live, false)
    }

    /// Pick the final error to show after every source failed. A rate-limit
    /// (with its countdown) wins over a generic failure; if nothing concrete is
    /// available, fall back to an install/login hint.
    private func reportFailure(codeOutcome: FetchOutcome?, webOutcome: FetchOutcome?) {
        let outcomes = [codeOutcome, webOutcome].compactMap { $0 }

        // CLI login expired and the desktop fallback didn't save us → nag to
        // re-login. This wins over a 429 (which an expired token also triggers),
        // and we set no backoff so we recover within one poll after re-login.
        if outcomes.contains(where: { if case .expired = $0 { return true } else { return false } }) {
            // Drop any stale usage so `primary` goes nil and the UI shows the
            // re-login prompt + button instead of freezing on "即将重置".
            fail("Claude Code 登录已过期，请在终端重新登录（运行 claude 即可）", keepStale: false)
            return
        }
        for outcome in outcomes {
            if case .rateLimited(let retryAfter) = outcome {
                let seconds = retryAfter ?? 45
                fail(rateLimitMessage(seconds: seconds), retryAfter: seconds)
                return
            }
        }
        switch outcomes.first {
        case .failure(let message)?, .unauthorized(let message)?:
            fail(message)
            return
        default:
            break
        }
        if ClaudeCodeCLI.isInstalled {
            fail("请先登录 Claude Code")
        } else if ClaudeDesktopCookieImporter.isInstalled {
            fail("请导入 Claude 桌面版登录")
        } else {
            fail("未安装 Claude Code")
        }
    }

    /// "接口限流，约 47 分钟后恢复（09:41）"
    private func rateLimitMessage(seconds: TimeInterval) -> String {
        let secs = max(0, Int(seconds.rounded()))
        let dur: String
        if secs >= 3600 {
            dur = "\(secs / 3600) 小时 \((secs % 3600) / 60) 分钟"
        } else if secs >= 60 {
            dur = "\(secs / 60) 分钟"
        } else {
            dur = "\(secs) 秒"
        }
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "zh_CN")
        clock.dateFormat = "HH:mm"
        let when = clock.string(from: Date().addingTimeInterval(seconds))
        return "接口限流，约 \(dur)后恢复（\(when)）"
    }

    private func fetchOAuth(token: String, source: TokenSource) -> FetchOutcome {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("claude-code/\(ClaudeCodeCLI.version())", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15

        let sem = DispatchSemaphore(value: 0)
        var outcome: FetchOutcome = .failure("请求失败")
        URLSession.shared.dataTask(with: req) { [self] data, resp, err in
            defer { sem.signal() }
            if let err = err {
                outcome = .failure(err.localizedDescription)
                return
            }
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            guard code == 200, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if code == 401 || code == 403 {
                    invalidate(tokenSource: source)
                }
                switch code {
                case 401: outcome = .failure("凭证过期，请在 Claude Code 重新登录")
                case 403: outcome = .failure("Claude Code 终端授权未被官方用量接口接受，请重新授权")
                case 429: outcome = .rateLimited(retryAfter: retryAfterSeconds(from: http))
                default:  outcome = .failure("请求失败 (HTTP \(code))")
                }
                return
            }
            outcome = .success(Snapshot(
                fiveHour: window(obj["five_hour"]),
                sevenDay: window(obj["seven_day"]),
                error: nil,
                at: Date()
            ))
        }.resume()
        sem.wait()
        return outcome
    }

    private func fetchWeb(sessionKey: String) -> FetchOutcome {
        let orgId: String
        switch fetchOrganizationId(sessionKey: sessionKey) {
        case .outcome(let outcome): return outcome
        case .id(let id): orgId = id
        }

        var req = URLRequest(url: URL(string: "https://claude.ai/api/organizations/\(orgId)/usage")!)
        req.httpMethod = "GET"
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        let sem = DispatchSemaphore(value: 0)
        var outcome: FetchOutcome = .failure("请求失败")
        URLSession.shared.dataTask(with: req) { [self] data, resp, err in
            defer { sem.signal() }
            if let err = err {
                outcome = .failure(err.localizedDescription)
                return
            }
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            guard code == 200, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                switch code {
                case _ where isCloudflareChallenge(http): outcome = .failure(cloudflareMessage)
                case 401, 403: outcome = .unauthorized("Claude 桌面登录已过期，请重新导入授权")
                case 429: outcome = .rateLimited(retryAfter: retryAfterSeconds(from: http))
                default: outcome = .failure("请求失败 (HTTP \(code))")
                }
                return
            }
            outcome = .success(Snapshot(
                fiveHour: window(obj["five_hour"]),
                sevenDay: window(obj["seven_day"]),
                error: nil,
                at: Date()
            ))
        }.resume()
        sem.wait()
        return outcome
    }

    private func fetchOrganizationId(sessionKey: String) -> OrgResult {
        var req = URLRequest(url: URL(string: "https://claude.ai/api/organizations")!)
        req.httpMethod = "GET"
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        let sem = DispatchSemaphore(value: 0)
        var result: OrgResult = .outcome(.failure("组织信息请求失败"))
        URLSession.shared.dataTask(with: req) { [self] data, resp, err in
            defer { sem.signal() }
            if let err = err {
                result = .outcome(.failure(err.localizedDescription))
                return
            }
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            guard code == 200, let data = data,
                  let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                switch code {
                case _ where isCloudflareChallenge(http): result = .outcome(.failure(cloudflareMessage))
                case 401, 403: result = .outcome(.unauthorized("Claude 桌面登录已过期，请重新导入授权"))
                case 429: result = .outcome(.rateLimited(retryAfter: retryAfterSeconds(from: http)))
                default: result = .outcome(.failure("组织信息请求失败 (HTTP \(code))"))
                }
                return
            }
            let selected = orgs.first {
                (($0["capabilities"] as? [String]) ?? []).map { $0.lowercased() }.contains("chat")
            } ?? orgs.first {
                let capabilities = Set((($0["capabilities"] as? [String]) ?? []).map { $0.lowercased() })
                return !(capabilities.count == 1 && capabilities.contains("api"))
            }
                ?? orgs.first
            if let id = selected?["uuid"] as? String {
                result = .id(id)
            } else {
                result = .outcome(.failure("未找到 Claude 组织信息"))
            }
        }.resume()
        sem.wait()
        return result
    }

    /// claude.ai sits behind Cloudflare, which sometimes answers non-browser
    /// clients with a 403 "Just a moment…" challenge page. That says nothing
    /// about the session cookie, so it must not trigger a re-import.
    private func isCloudflareChallenge(_ resp: HTTPURLResponse?) -> Bool {
        guard let resp else { return false }
        if resp.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge" { return true }
        let type = resp.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        return resp.statusCode == 403 && type.contains("text/html")
    }

    private let cloudflareMessage = "claude.ai 触发了 Cloudflare 验证，暂时无法读取网页版用量"

    private func window(_ any: Any?) -> Window? {
        guard let d = any as? [String: Any], let u = num(d["utilization"]) else { return nil }
        var reset: Date?
        if let s = d["resets_at"] as? String { reset = parseISO(s) }
        return Window(utilization: u, resetsAt: reset)
    }

    // MARK: - token

    /// Resolve the OAuth token, trying the most explicit sources first:
    /// 1. env `CLAUDE_CODE_OAUTH_TOKEN`
    /// 2. `~/.codelightpro/token` — long-lived token from `claude setup-token`
    ///    (written by `scripts/setup_claude_token.sh`)
    /// 3. standalone-CLI Keychain item `Claude Code-credentials` (JSON)
    /// 4. `~/.claude/.credentials.json` (JSON)
    ///
    /// `expiresAt` (when the source carries it) lets us notice a stale token
    /// *before* spending a request on it — the usage endpoint answers an expired
    /// token with a 429, which otherwise looks exactly like rate-limiting.
    private func readToken() -> (value: String, source: TokenSource, expiresAt: Date?)? {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"],
           !env.isEmpty { return (env, .environment, nil) }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let setupToken = home.appendingPathComponent(".codelightpro/token")
        if let raw = try? String(contentsOf: setupToken, encoding: .utf8) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return (value, .setupToken, nil) }
        }

        if let t = readKeychainToken() { return (t.value, .keychain, t.expiresAt) }

        let creds = home.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: creds), let t = extractToken(from: data) {
            return (t.value, .credentialsFile, t.expiresAt)
        }

        return nil
    }

    private func invalidate(tokenSource: TokenSource) {
        switch tokenSource {
        case .environment, .setupToken, .keychain, .credentialsFile:
            break
        }
    }

    private func readKeychainToken() -> (value: String, expiresAt: Date?)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return extractToken(from: data)
    }

    /// Credentials JSON shape:
    /// `{ "claudeAiOauth": { "accessToken": "...", "expiresAt": <epoch-ms> } }`.
    private func extractToken(from data: Data) -> (value: String, expiresAt: Date?)? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = j["claudeAiOauth"] as? [String: Any],
              let tok = oauth["accessToken"] as? String else { return nil }
        var expiresAt: Date?
        if let ms = num(oauth["expiresAt"]) { expiresAt = Date(timeIntervalSince1970: ms / 1000) }
        return (tok, expiresAt)
    }
}

/// Parse ISO-8601 like "2026-04-11T07:00:00.528743+00:00" (with microseconds
/// and colon offset) robustly.
private func parseISO(_ s: String) -> Date? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: s) { return d }
    iso.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: s) { return d }

    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxxxx",
                "yyyy-MM-dd'T'HH:mm:ss.SSSxxxxx",
                "yyyy-MM-dd'T'HH:mm:ssxxxxx"] {
        df.dateFormat = fmt
        if let d = df.date(from: s) { return d }
    }
    return nil
}
