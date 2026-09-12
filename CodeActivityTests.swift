import Foundation

func runCodeActivityTests() throws {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CodeActivityFailure.message("Test failed: " + message) }
    }
    let hunk = "diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -1,2 +1,3 @@\n-a\n-b\n+x\n+y\n+z\n@@ -9 +10,0 @@\n-delete\n"
    try expect(CodeLineCounts.patch(hunk) == CodeLineCounts(added: 1, modified: 2, deleted: 1), "disjoint replacement counts")
    try expect(CodeLineCounts.patch("diff --git a/x b/x\n@@ -1 +1 @@\n---literal\n+++literal\n\\ No newline at end of file\n") == CodeLineCounts(modified: 1), "content resembling diff headers")
    try expect(CodeLineCounts.patch("diff --git a/x b/x\nBinary files a/x and b/x differ\n") == CodeLineCounts(), "binary files")
    try expect(!CodeActivityScanner.isSource("node_modules/demo/index.js") && !CodeActivityScanner.isSource("docs/readme.md") && CodeActivityScanner.isSource("src/a.swift"), "source scope")
    let json = Data(#"{"local-projects":{"a":{"name":"One","rootPaths":["/tmp/a","/tmp/b"]}},"electron-saved-workspace-roots":["/tmp/stale"]}"#.utf8)
    let projects = try CodexProjects.decodeLegacy(json)
    try expect(projects.count == 1 && projects[0].roots.count == 2, "current saved projects override stale legacy roots")
    let zone = TimeZone(identifier: "Asia/Shanghai")!
    let date = ISO8601DateFormatter().date(from: "2026-09-12T12:00:00+08:00")!
    let day = CodeActivityScanner.dayInterval(date, zone: zone)
    try expect(day.start == ISO8601DateFormatter().date(from: "2026-09-12T00:00:00+08:00")!, "selected time-zone midnight")
    let dst = CodeActivityScanner.dayInterval(ISO8601DateFormatter().date(from: "2026-03-08T12:00:00-07:00")!, zone: TimeZone(identifier: "America/Los_Angeles")!)
    try expect(dst.duration == 23 * 3600, "DST day boundaries")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("code-activity-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func write(_ path: String, _ text: String) throws {
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    func git(_ arguments: [String], date: String = "2026-09-12T10:00:00+08:00") throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", directory.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_AUTHOR_DATE"] = date; environment["GIT_COMMITTER_DATE"] = date
        p.environment = environment
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        try expect(p.terminationStatus == 0, "fixture git \(arguments)")
    }
    try git(["init", "-b", "main"])
    try write("sample.py", "old\nkeep\n")
    try git(["add", "."])
    try git(["commit", "-m", "yesterday"], date: "2026-09-11T23:59:59+08:00")
    try write("sample.py", "new\nextra\nkeep\n")
    try write("README.md", "Ignored documentation\n")
    try git(["add", "."])
    try git(["commit", "-m", "today"], date: "2026-09-12T00:00:00+08:00")
    // Staged and unstaged edits must be measured together against HEAD.
    try write("sample.py", "temporary\nextra\nkeep\n")
    try git(["add", "sample.py"])
    try write("sample.py", "new\nextra\nchanged\n")
    try write("new\tfile.py", "one\ntwo")
    try write("dist/bundle.js", "ignored\n")
    try write("node_modules/demo/index.js", "ignored\n")
    try write("README.md", "Still ignored\n")
    try Data([0, 1, 2, 3]).write(to: directory.appendingPathComponent("binary.py"))
    let linked = [CodeProject(name: "One", roots: [directory.path]), CodeProject(name: "Two", roots: [directory.path, directory.appendingPathComponent(".").path])]
    let snapshot = CodeActivityScanner.scan(projects: linked, date: date, zone: zone)
    try expect(snapshot.repositories.count == 1 && !snapshot.incomplete, "shared repository deduplication: \(snapshot.repositories)")
    try expect(snapshot.committed == CodeLineCounts(added: 1, modified: 1), "only today's committed source lines: \(snapshot.committed)")
    try expect(snapshot.uncommitted == CodeLineCounts(added: 2, modified: 1), "working copy, untracked, no double staged count: \(snapshot.uncommitted)")

    // A commit at the next midnight is excluded, while the previous commit remains reachable.
    try git(["reset", "--hard", "HEAD"])
    try write("sample.py", "tomorrow\nextra\nkeep\n")
    try git(["add", "sample.py"])
    try git(["commit", "-m", "tomorrow"], date: "2026-09-13T00:00:00+08:00")
    let boundary = CodeActivityScanner.scan(projects: linked, date: date, zone: zone)
    try expect(boundary.committed == snapshot.committed, "next day excluded without pruning earlier history")

    let worktree = directory.appendingPathComponent("linked-tree")
    try git(["worktree", "add", "--detach", worktree.path, "HEAD"])
    try write("linked-tree/sample.py", "worktree\nextra\nkeep\n")
    let cache = CodeActivityScanner.Cache()
    let worktreeProjects = linked + [CodeProject(name: "Linked", roots: [worktree.path])]
    let first = CodeActivityScanner.scan(projects: worktreeProjects, date: date, zone: zone, cache: cache)
    let second = CodeActivityScanner.scan(projects: worktreeProjects, date: date, zone: zone, cache: cache)
    try expect(!first.incomplete && first.repositories.count == 1, "worktrees grouped by common repository")
    try expect(first.committed == boundary.committed && second.total == first.total, "cached commits and worktree commits not duplicated")
    // The linked worktree directory is untracked inside the main repo; ignore it there,
    // as real Codex worktrees normally live outside the checkout.
    try write(".git/info/exclude", "linked-tree/\n")
    let deduplicated = CodeActivityScanner.scan(projects: worktreeProjects, date: date, zone: zone)
    try expect(deduplicated.uncommitted == boundary.uncommitted + CodeLineCounts(modified: 1), "each worktree counted once")
    try git(["worktree", "remove", "--force", worktree.path])
    try git(["stash", "push", "--include-untracked", "-m", "not a project commit"])
    let stashed = CodeActivityScanner.scan(projects: linked, date: date, zone: zone)
    try expect(!stashed.incomplete && stashed.committed == boundary.committed, "stash snapshots must not count as today's commits")

    let unborn = directory.appendingPathComponent("unborn")
    try FileManager.default.createDirectory(at: unborn, withIntermediateDirectories: true)
    try git(["init", "-b", "main", unborn.path])
    try write("unborn/test.swift", "staged\n")
    try git(["-C", unborn.path, "add", "."])
    try write("unborn/test.swift", "live\nsecond\n")
    let initial = CodeActivityScanner.scan(projects: [CodeProject(name: "Unborn", roots: [unborn.path])], date: date, zone: zone)
    try expect(!initial.incomplete && initial.total == CodeLineCounts(added: 2), "unborn repository uses current contents: \(initial.repositories)")
    print("Code activity tests passed: replacements, source scope, project discovery, time zones/DST, shared roots, staged/unstaged edits, new files, binary exclusion, midnight boundaries, worktrees, caching and unborn repositories.")
}
