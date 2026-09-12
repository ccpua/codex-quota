import Foundation
import SQLite3

/// Disjoint line counts: pair replacements inside each zero-context diff hunk.
struct CodeLineCounts: Equatable {
    var added = 0
    var modified = 0
    var deleted = 0
    static func + (lhs: Self, rhs: Self) -> Self {
        Self(added: lhs.added + rhs.added, modified: lhs.modified + rhs.modified, deleted: lhs.deleted + rhs.deleted)
    }
    static func patch(_ patch: String) -> Self {
        var result = Self(), additions = 0, deletions = 0, inHunk = false
        func flush() {
            let paired = min(additions, deletions)
            result = result + Self(added: additions - paired, modified: paired, deleted: deletions - paired)
            additions = 0; deletions = 0
        }
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { flush(); inHunk = false }
            else if line.hasPrefix("@@ ") { flush(); inHunk = true }
            else if inHunk {
                if line.hasPrefix("+") { additions += 1 }
                else if line.hasPrefix("-") { deletions += 1 }
                else if !line.hasPrefix("\\") { flush(); inHunk = false }
            }
        }
        flush()
        return result
    }
}

struct CodeProject {
    let name: String
    let roots: [String]
}

enum CodeActivityFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

enum CodexProjects {
    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [CodeProject] {
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let directory = configured.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let databases = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        // Read only. Never migrate or mutate the Codex database.
        if let database = databases.first, let projects = readDatabase(database) { return projects }
        let data = try Data(contentsOf: directory.appendingPathComponent(".codex-global-state.json"))
        return try decodeLegacy(data)
    }

    static func decodeLegacy(_ data: Data) throws -> [CodeProject] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodeActivityFailure.message(tr("无法读取 Codex 项目列表", "Cannot read Codex projects"))
        }
        if let projects = object["local-projects"] as? [String: [String: Any]] {
            return projects.values.compactMap { item in
                guard let name = item["name"] as? String, let roots = item["rootPaths"] as? [String] else { return nil }
                return CodeProject(name: name, roots: roots)
            }.sorted { $0.name < $1.name }
        }
        if let roots = object["electron-saved-workspace-roots"] as? [String] {
            return roots.map { CodeProject(name: URL(fileURLWithPath: $0).lastPathComponent, roots: [$0]) }
        }
        throw CodeActivityFailure.message(tr("当前 Codex 项目格式暂不支持", "This Codex project format is not supported"))
    }

    private static func readDatabase(_ url: URL) -> [CodeProject]? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        var statement: OpaquePointer?
        let sql = "SELECT p.id, p.name, r.path FROM projects p LEFT JOIN project_roots r ON r.project_id = p.id ORDER BY p.position, r.position"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var order: [String] = [], names: [String: String] = [:], roots: [String: [String]] = [:]
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            if names[id] == nil { order.append(id) }
            names[id] = String(cString: sqlite3_column_text(statement, 1))
            if let path = sqlite3_column_text(statement, 2) { roots[id, default: []].append(String(cString: path)) }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { return nil }
        return order.map { CodeProject(name: names[$0]!, roots: roots[$0] ?? []) }
    }
}

struct CodeRepositoryActivity {
    let path: String
    let projects: [String]
    var committed = CodeLineCounts()
    var uncommitted = CodeLineCounts()
    var issue: String?
    var total: CodeLineCounts { committed + uncommitted }
}

struct CodeActivitySnapshot {
    let date: Date
    let timeZone: TimeZone
    let projectCount: Int
    let repositories: [CodeRepositoryActivity]
    var committed: CodeLineCounts { repositories.reduce(CodeLineCounts()) { $0 + $1.committed } }
    var uncommitted: CodeLineCounts { repositories.reduce(CodeLineCounts()) { $0 + $1.uncommitted } }
    var total: CodeLineCounts { committed + uncommitted }
    var incomplete: Bool { repositories.contains { $0.issue != nil } }
}

/// A bounded, read-only Git command. File-backed output avoids pipe deadlocks on large diffs.
enum ActivityGit {
    static func run(_ path: String, _ arguments: [String], acceptDifference: Bool = false) throws -> Data {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("codex-quota-git-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-C", path, "-c", "core.quotePath=false", "-c", "diff.external=", "-c", "core.fsmonitor=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        // A GUI launched from a shell must still inspect the requested repository.
        for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["GIT_OPTIONAL_LOCKS"] = "0"; environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle; process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 8) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            throw CodeActivityFailure.message(tr("Git 查询超时", "Git scan timed out"))
        }
        guard process.terminationStatus == 0 || (acceptDifference && process.terminationStatus == 1) else {
            throw CodeActivityFailure.message(tr("目录不可用或 Git 查询失败", "Directory unavailable or Git scan failed"))
        }
        let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 32 * 1024 * 1024 else {
            throw CodeActivityFailure.message(tr("变更过大，未纳入汇总", "Diff too large to include"))
        }
        return try Data(contentsOf: output)
    }
    static func text(_ path: String, _ arguments: [String], acceptDifference: Bool = false) throws -> String {
        String(decoding: try run(path, arguments, acceptDifference: acceptDifference), as: UTF8.self)
    }
}

enum CodeActivityScanner {
    final class Cache {
        struct Entry { let fingerprint: Data; let day: Date; let counts: CodeLineCounts; let saved: Date }
        var entries: [String: Entry] = [:]
    }
    static let extensions = ["swift", "py", "pyi", "js", "jsx", "mjs", "cjs", "ts", "tsx", "vue", "svelte", "html", "css", "scss", "sass", "less", "c", "h", "cc", "cpp", "hpp", "m", "mm", "rs", "go", "java", "kt", "kts", "rb", "php", "sh", "bash", "zsh", "sql", "dart", "ex", "exs", "lua", "r", "R", "cs", "fs", "scala", "clj", "pl", "proto"]
    static let excludedDirectories = ["node_modules", "vendor", "dist", "build", "build-cache", ".build", ".next", ".venv", "venv", "__pycache__", "Pods", "third_party"]
    static var pathspecs: [String] {
        extensions.map { ":(glob)**/*.\($0)" }
        + excludedDirectories.map { ":(exclude,glob)**/\($0)/**" }
        + [":(exclude,glob)**/*.min.js", ":(exclude,glob)**/console/assets/**"]
    }
    static func isSource(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        return extensions.contains(URL(fileURLWithPath: path).pathExtension)
            && !parts.dropLast().contains(where: excludedDirectories.contains)
            && !path.hasSuffix(".min.js") && !path.contains("console/assets/")
    }
    static let diffOptions = ["--no-ext-diff", "--no-textconv", "--no-color", "--find-renames", "--unified=0", "--inter-hunk-context=0"]

    static func dayInterval(_ date: Date, zone: TimeZone) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.dateInterval(of: .day, for: date)!
    }

    static func scan(projects: [CodeProject], date: Date = Date(), zone: TimeZone, cache: Cache? = nil) -> CodeActivitySnapshot {
        let day = dayInterval(date, zone: zone)
        var paths: [String: Set<String>] = [:]
        for project in projects {
            for path in project.roots { paths[URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path, default: []].insert(project.name) }
        }
        var repositories: [String: (path: String, names: Set<String>, worktrees: Set<String>)] = [:]
        var results: [CodeRepositoryActivity] = []
        for (path, names) in paths.sorted(by: { $0.key < $1.key }) {
            do {
                let top = try ActivityGit.text(path, ["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .newlines)
                let common = try ActivityGit.text(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]).trimmingCharacters(in: .newlines)
                let key = URL(fileURLWithPath: common).resolvingSymlinksInPath().path
                var repo = repositories[key] ?? (top, [], [])
                repo.names.formUnion(names); repo.worktrees.insert(top)
                repositories[key] = repo
            } catch {
                results.append(CodeRepositoryActivity(path: path, projects: names.sorted(), issue: error.localizedDescription))
            }
        }
        for repo in repositories.values.sorted(by: { $0.path < $1.path }) {
            var activity = CodeRepositoryActivity(path: repo.path, projects: repo.names.sorted())
            do {
                let worktreeData = try ActivityGit.run(repo.path, ["worktree", "list", "--porcelain", "-z"])
                let heads = worktreeData.split(separator: 0).compactMap { record -> String? in
                    let field = String(decoding: record, as: UTF8.self)
                    guard field.hasPrefix("HEAD ") else { return nil }
                    let hash = String(field.dropFirst(5))
                    return hash.allSatisfy { $0 == "0" } ? nil : hash
                }
                let refs = try ActivityGit.run(repo.path, ["rev-parse", "--branches", "--remotes", "--tags"])
                let fingerprint = refs + worktreeData
                if let entry = cache?.entries[repo.path], entry.day == day.start,
                   entry.fingerprint == fingerprint, Date().timeIntervalSince(entry.saved) < 60 {
                    activity.committed = entry.counts
                } else {
                // Include branches, tags and worktree HEADs; exclude stash snapshots and merge replay.
                // Filter timestamps ourselves: --since can prune a history with non-monotonic commit dates.
                let history = refs.isEmpty && heads.isEmpty ? "" : try ActivityGit.text(repo.path, ["log", "--branches", "--remotes", "--tags", "--no-merges", "--format=%H %ct"] + Array(Set(heads)).sorted() + ["--"])
                let commits = history.split(separator: "\n").compactMap { line -> String? in
                    let fields = line.split(separator: " ")
                    guard fields.count == 2, let seconds = Double(fields[1]), seconds >= day.start.timeIntervalSince1970,
                          seconds < day.end.timeIntervalSince1970 else { return nil }
                    return String(fields[0])
                }
                for commit in Set(commits).sorted() {
                    let patch = try ActivityGit.text(repo.path, ["show", "--format=", "--root"] + diffOptions + [commit, "--"] + pathspecs)
                    activity.committed = activity.committed + CodeLineCounts.patch(patch)
                }
                cache?.entries[repo.path] = Cache.Entry(fingerprint: fingerprint, day: day.start, counts: activity.committed, saved: Date())
                }
                // Include registered worktrees too; each working directory is counted once.
                var worktrees = repo.worktrees
                for record in worktreeData.split(separator: 0) {
                    let field = String(decoding: record, as: UTF8.self)
                    if field.hasPrefix("worktree ") { worktrees.insert(String(field.dropFirst(9))) }
                }
                for path in worktrees.sorted() {
                    let head = try ActivityGit.text(path, ["rev-parse", "--verify", "--quiet", "HEAD"], acceptDifference: true).trimmingCharacters(in: .newlines)
                    var extraFiles = Data()
                    if head.isEmpty {
                        // An unborn repository has no baseline: count current files once,
                        // even when staged contents differ from the working copy.
                        extraFiles = try ActivityGit.run(path, ["ls-files", "--cached", "-z"])
                    } else {
                        let patch = try ActivityGit.text(path, ["diff"] + diffOptions + ["HEAD", "--"] + pathspecs)
                        activity.uncommitted = activity.uncommitted + CodeLineCounts.patch(patch)
                    }
                    let untracked = try ActivityGit.run(path, ["ls-files", "--others", "--exclude-standard", "-z"]) + extraFiles
                    let records: [Data] = untracked.split(separator: UInt8(0)).map { Data($0) }
                    for record in Set(records) {
                        let file = String(decoding: record, as: UTF8.self)
                        guard isSource(file) else { continue }
                        let url = URL(fileURLWithPath: path).appendingPathComponent(file)
                        guard FileManager.default.fileExists(atPath: url.path) else { continue }
                        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                        let patch = try ActivityGit.text(path, ["diff", "--no-index"] + diffOptions + ["--", "/dev/null", url.path], acceptDifference: true)
                        activity.uncommitted = activity.uncommitted + CodeLineCounts.patch(patch)
                    }
                }
            } catch { activity.issue = error.localizedDescription }
            results.append(activity)
        }
        return CodeActivitySnapshot(date: date, timeZone: zone, projectCount: projects.count, repositories: results.sorted { $0.path < $1.path })
    }
}

final class CodeActivityClient {
    private let queue = DispatchQueue(label: "local.codexquota.code-activity", qos: .utility)
    private var busy = false
    private let cache = CodeActivityScanner.Cache()
    var onResult: ((Result<CodeActivitySnapshot, Error>) -> Void)?
    func refresh(zone: TimeZone = displayTimeZone) {
        // Called only on the main queue; never enqueue overlapping polls.
        guard !busy else { return }
        busy = true
        queue.async {
            let result = Result { CodeActivityScanner.scan(projects: try CodexProjects.read(), zone: zone, cache: self.cache) }
            DispatchQueue.main.async { self.busy = false; self.onResult?(result) }
        }
    }
}
