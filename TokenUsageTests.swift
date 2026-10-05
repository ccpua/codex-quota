import Foundation

func runTokenUsageTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sessions = root.appendingPathComponent("sessions")
    let archive = root.appendingPathComponent("archived_sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let date = ISO8601DateFormatter().date(from: "2026-10-05T07:00:00Z")!
    func event(_ stamp: String, _ cumulative: Int, _ last: Int) -> Data {
        let value: [String: Any] = ["timestamp": stamp, "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": cumulative], "last_token_usage": ["total_tokens": last]]]]
        var data = try! JSONSerialization.data(withJSONObject: value); data.append(10); return data
    }
    let file = sessions.appendingPathComponent("old-session.jsonl")
    var data = event("2026-10-04T15:59:59Z", 100, 100)
    data.append(event("2026-10-04T16:00:00.000Z", 150, 50)) // Beijing midnight
    data.append(event("2026-10-04T16:00:01Z", 150, 50)) // repeated notification
    data.append(event("2026-10-05T02:00:00Z", 200, 50))
    try data.write(to: file)
    let scanner = TokenUsageScanner()
    func check(_ expected: Int, now: Date = date) throws {
        let actual = try scanner.scan(root: root, now: now).total
        precondition(actual == expected, "Expected \(expected), got \(actual)")
    }
    try check(100)
    try check(100)
    let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
    let partial = event("2026-10-05T03:00:00Z", 250, 50)
    try handle.write(contentsOf: partial.dropLast())
    try check(100)
    try handle.write(contentsOf: Data([10])); try handle.close()
    try check(150)
    let fork = sessions.appendingPathComponent("fork.jsonl")
    try event("2026-10-05T03:10:00Z", 10050, 50).write(to: fork)
    try check(200)
    try FileManager.default.moveItem(at: file, to: archive.appendingPathComponent(file.lastPathComponent))
    try check(200)
    var reset = event("2026-10-05T03:10:00Z", 10050, 50)
    reset.append(event("2026-10-05T03:11:00Z", 20, 20)) // counter reset
    try reset.write(to: fork)
    try check(220)
    try check(0, now: date.addingTimeInterval(86400))
    precondition(tokenUsageLabel(4_196_906) == "4.20M")
    precondition(tokenUsageLabel(nil) == "—")
    print("Passed: Beijing midnight, cumulative deltas, duplicate events, partial writes, forks, archives, counter resets and next-day rollover.")
}
