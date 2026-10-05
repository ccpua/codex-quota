import Foundation

struct DailyTokenUsage {
    let day: DateInterval
    let total: Int
}

func tokenUsageLabel(_ total: Int?) -> String {
    guard let total else { return "—" }
    if total >= 1_000_000 { return String(format: "%.2fM", Double(total) / 1_000_000) }
    if total >= 1_000 { return String(format: "%.1fK", Double(total) / 1_000) }
    return String(total)
}

/// Read append-only rollout events incrementally, counting cumulative deltas once.
final class TokenUsageScanner {
    private struct FileState {
        var offset: UInt64 = 0
        var pending = Data()
        var previous: Int?
        var total = 0
        var modified: Date?
    }
    private var files: [String: FileState] = [:]
    private var day: DateInterval?
    private let timestamp = ISO8601DateFormatter()
    private let fractionalTimestamp = ISO8601DateFormatter()
    init() { fractionalTimestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }

    func scan(root: URL, now: Date = Date()) throws -> DailyTokenUsage {
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let interval = calendar.dateInterval(of: .day, for: now)!
        if day != interval { files.removeAll(); day = interval }
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw CodeActivityFailure.message("无法读取 Codex 会话记录")
        }
        var seen = Set<String>()
        for name in ["sessions", "archived_sessions"] {
            let directory = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], errorHandler: { _, error in
                enumerationError = error; return false
            }) else { throw CodeActivityFailure.message("无法读取 Codex 会话记录") }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                seen.insert(url.path)
                let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = UInt64(attributes.fileSize ?? 0)
                var state = files[url.path] ?? FileState()
                if size < state.offset || (size == state.offset && attributes.contentModificationDate != state.modified) {
                    state = FileState()
                }
                if size > state.offset {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: state.offset)
                    while state.offset < size {
                        let data = try handle.read(upToCount: Int(min(65536, size - state.offset))) ?? Data()
                        guard !data.isEmpty else { break }
                        state.offset += UInt64(data.count); state.pending.append(data)
                        while let end = state.pending.firstIndex(of: 10) {
                            let line = Data(state.pending[..<end])
                            state.pending.removeSubrange(...end)
                            consume(line, state: &state, interval: interval)
                        }
                    }
                }
                state.modified = attributes.contentModificationDate
                files[url.path] = state
            }
            if let enumerationError { throw enumerationError }
        }
        files = files.filter { seen.contains($0.key) }
        return DailyTokenUsage(day: interval, total: files.values.reduce(0) { $0 + $1.total })
    }

    private func consume(_ line: Data, state: inout FileState, interval: DateInterval) {
        // Avoid decoding message contents when the line isn't a usage event.
        guard line.range(of: Data("\"token_count\"".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let cumulative = info["total_token_usage"] as? [String: Any],
              let current = cumulative["total_tokens"] as? Int, current >= 0,
              let dateText = object["timestamp"] as? String,
              let date = fractionalTimestamp.date(from: dateText) ?? timestamp.date(from: dateText) else { return }
        let last = (info["last_token_usage"] as? [String: Any])?["total_tokens"] as? Int
        // The first event can inherit a fork's history. Count only its last request.
        let delta: Int
        if let previous = state.previous, current >= previous { delta = current - previous }
        else { delta = max(0, last ?? 0) }
        state.previous = current
        if date >= interval.start && date < interval.end { state.total += delta }
    }
}

final class TokenUsageClient {
    private let queue = DispatchQueue(label: "local.codexquota.token-usage", qos: .utility)
    private let scanner = TokenUsageScanner()
    private var busy = false
    var onResult: ((Result<DailyTokenUsage, Error>) -> Void)?
    func refresh() {
        guard !busy else { return }; busy = true
        let root = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        queue.async {
            let result = Result { try self.scanner.scan(root: root) }
            DispatchQueue.main.async { self.busy = false; self.onResult?(result) }
        }
    }
}
