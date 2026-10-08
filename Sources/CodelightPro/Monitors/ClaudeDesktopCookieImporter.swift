import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import SQLite3

enum ClaudeDesktopCookieError: LocalizedError {
    case cookieStoreMissing
    case safeStorageMissing
    case sessionKeyMissing
    case decryptFailed

    var errorDescription: String? {
        switch self {
        case .cookieStoreMissing:
            return "未找到 Claude 桌面版登录数据，请先打开 Claude 桌面版并登录"
        case .safeStorageMissing:
            return "未获得 Claude 桌面版钥匙串权限"
        case .sessionKeyMissing:
            return "Claude 桌面版未找到有效登录态"
        case .decryptFailed:
            return "Claude 桌面版登录态解密失败"
        }
    }
}

final class ClaudeDesktopCookieImporter: @unchecked Sendable {
    static var isInstalled: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        return FileManager.default.fileExists(atPath: support.path)
            || FileManager.default.fileExists(atPath: "/Applications/Claude.app")
    }

    func importSessionKey() throws -> String {
        let cookieDB = try latestCookieStore()
        let password = try safeStoragePassword()
        let key = try aesKey(password: password)
        let rows = try sessionKeyRows(from: cookieDB)

        for row in rows {
            if !row.value.isEmpty { return row.value }
            if let decrypted = decryptCookie(row.encryptedValue, hostKey: row.hostKey, key: key),
               decrypted.hasPrefix("sk-ant-") {
                try save(sessionKey: decrypted)
                return decrypted
            }
        }
        throw rows.isEmpty ? ClaudeDesktopCookieError.sessionKeyMissing : ClaudeDesktopCookieError.decryptFailed
    }

    static func readSavedSessionKey() -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codelightpro/claude-session-key")
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Forget a saved session key the server rejected, so the next lookup
    /// re-imports the live cookie from Claude Desktop instead of reusing it.
    static func deleteSavedSessionKey() {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codelightpro/claude-session-key")
        try? FileManager.default.removeItem(at: file)
    }

    private struct CookieRow {
        let hostKey: String
        let value: String
        let encryptedValue: Data
        let expiresUTC: Int64
    }

    private func latestCookieStore() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        let candidates = [
            base.appendingPathComponent("Cookies"),
            base.appendingPathComponent("Network/Cookies")
        ]

        let fm = FileManager.default
        let nested = (try? fm.subpathsOfDirectory(atPath: base.path)) ?? []
        let all = candidates + nested
            .filter { $0.hasSuffix("/Cookies") || $0 == "Cookies" }
            .map { base.appendingPathComponent($0) }

        let existing = all.filter { fm.fileExists(atPath: $0.path) }
        guard let newest = existing.max(by: { modificationDate($0) < modificationDate($1) }) else {
            throw ClaudeDesktopCookieError.cookieStoreMissing
        }
        return newest
    }

    private func safeStoragePassword() throws -> String {
        let pairs = [
            ["find-generic-password", "-s", "Claude Safe Storage", "-a", "Claude Key", "-w"],
            ["find-generic-password", "-s", "Claude Safe Storage", "-w"]
        ]
        for args in pairs {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch { continue }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { continue }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let password = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !password.isEmpty { return password }
        }
        throw ClaudeDesktopCookieError.safeStorageMissing
    }

    private func sessionKeyRows(from dbURL: URL) throws -> [CookieRow] {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codelightpro-claude-cookies-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: dbURL, to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ClaudeDesktopCookieError.cookieStoreMissing
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT host_key, value, encrypted_value, expires_utc
        FROM cookies
        WHERE name = 'sessionKey' AND host_key LIKE '%claude.ai%'
        ORDER BY last_update_utc DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClaudeDesktopCookieError.sessionKeyMissing
        }
        defer { sqlite3_finalize(statement) }

        var rows: [CookieRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let host = String(cString: sqlite3_column_text(statement, 0))
            let value = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let blob = sqlite3_column_blob(statement, 2)
            let count = Int(sqlite3_column_bytes(statement, 2))
            let encrypted = blob.map { Data(bytes: $0, count: count) } ?? Data()
            let expires = sqlite3_column_int64(statement, 3)
            rows.append(CookieRow(hostKey: host, value: value, encryptedValue: encrypted, expiresUTC: expires))
        }
        return rows
    }

    private func aesKey(password: String) throws -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let keyLength = key.count
        let passwordData = Data(password.utf8)
        let saltData = Data("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                saltData.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        saltData.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw ClaudeDesktopCookieError.decryptFailed }
        return key
    }

    private func decryptCookie(_ encryptedValue: Data, hostKey: String, key: Data) -> String? {
        guard encryptedValue.count > 3,
              String(decoding: encryptedValue.prefix(3), as: UTF8.self) == "v10" else {
            return nil
        }
        let payload = encryptedValue.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: payload.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var outLength = 0

        let status = out.withUnsafeMutableBytes { outBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outBytes.baseAddress,
                            outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(outLength..<out.count)

        let hostDigest = Data(SHA256.hash(data: Data(hostKey.utf8)))
        if out.count > hostDigest.count, out.prefix(hostDigest.count) == hostDigest {
            out.removeFirst(hostDigest.count)
        }
        return String(data: out, encoding: .utf8)
    }

    private func save(sessionKey: String) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".codelightpro", isDirectory: true)
        let file = dir.appendingPathComponent("claude-session-key")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try sessionKey.write(to: file, atomically: true, encoding: .utf8)
        chmod(file.path, S_IRUSR | S_IWUSR)
    }
}
