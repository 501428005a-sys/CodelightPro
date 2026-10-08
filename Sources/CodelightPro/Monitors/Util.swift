import Foundation

/// Read the last `maxBytes` of a file and return complete lines.
/// Drops the first (possibly partial) line when we didn't start at byte 0.
func readTail(_ url: URL, maxBytes: Int = 512 * 1024) -> [String] {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
    try? fh.seek(toOffset: start)
    let data = (try? fh.readToEnd()) ?? Data()
    var text = String(decoding: data, as: UTF8.self)
    if start > 0, let nl = text.firstIndex(of: "\n") {
        text = String(text[text.index(after: nl)...])
    }
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

/// Read the first `maxBytes` of a file and return complete lines.
/// Useful for headers (e.g. Codex `session_meta`) that live at byte 0.
func readHead(_ url: URL, maxBytes: Int = 16 * 1024) -> [String] {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? fh.close() }
    let data = (try? fh.read(upToCount: maxBytes)) ?? Data()
    let text = String(decoding: data, as: UTF8.self)
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

/// Product name shown when a session isn't inside a git repository.
let appDisplayName = "CodelightPro"

/// Walks up from `cwd` looking for a `.git` entry; returns the repo root's
/// folder name when found, otherwise nil.
func gitProjectName(from cwd: String?) -> String? {
    guard let cwd, !cwd.isEmpty else { return nil }
    var dir = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
    let fm = FileManager.default
    while dir.path != "/" {
        if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            let name = dir.lastPathComponent
            return name.isEmpty ? nil : name
        }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}

/// Parse one JSONL line into a dictionary.
func parseLine(_ line: String) -> [String: Any]? {
    guard let d = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

/// Coerce a JSON number (NSNumber/Int/Double) to Double.
func num(_ any: Any?) -> Double? {
    if let d = any as? Double { return d }
    if let i = any as? Int { return Double(i) }
    if let n = any as? NSNumber { return n.doubleValue }
    return nil
}

func modificationDate(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
}
