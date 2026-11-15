import Foundation

private final class MockVPNURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var responses: [String: Int] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let status = Self.responses[request.url!.host!] ?? 0
        Self.lock.unlock()
        if status == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private final class MockVPNShortcut: VPNShortcutRunning {
    var names: [String] = []
    var callback: ((Result<Void, Error>) -> Void)?
    func run(name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        names.append(name); callback = completion
    }
    func finish(_ result: Result<Void, Error>) { let completion = callback; callback = nil; completion?(result) }
}

private final class MockSystemVPNChecker: SystemVPNChecking {
    var state: SystemVPNState = .clear
    var deferred = false
    var checks = 0
    var callback: ((SystemVPNState) -> Void)?
    func check(_ completion: @escaping (SystemVPNState) -> Void) {
        checks += 1
        if deferred { callback = completion } else { completion(state) }
    }
    func finish(_ state: SystemVPNState) { let completion = callback; callback = nil; completion?(state) }
}

func runVPNRecoveryTests() throws {
    struct Failure: LocalizedError { let errorDescription: String? }
    func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(errorDescription: message) }
    }
    var settings = VPNRecoveryConfiguration(enabled: false, shortcutName: "reconnect VPN")
    var time: TimeInterval = 1000
    let shortcut = MockVPNShortcut()
    let recovery = VPNRecovery(shortcut: shortcut, systemVPN: MockSystemVPNChecker(), now: { time }, logger: { _ in }, configuration: { settings })
    var refreshes = 0
    var requestedChecks = 0
    recovery.onReconnect = { refreshes += 1 }
    recovery.onNetworkCheckRequested = { requestedChecks += 1 }

    recovery.quotaFailed(mayBeNetworkFailure: true)
    try expect(shortcut.names.isEmpty && requestedChecks == 0, "Disabled recovery must have no side effects")
    settings.enabled = true
    settings.shortcutName = "  "
    recovery.quotaFailed(mayBeNetworkFailure: true)
    try expect(shortcut.names.isEmpty && requestedChecks == 0, "Missing shortcut must have no side effects")
    settings.shortcutName = "reconnect VPN"
    recovery.quotaFailed(mayBeNetworkFailure: false)
    try expect(shortcut.names.isEmpty, "Authentication and local errors must not reconnect")
    try expect(!QuotaClient.Failure(errorDescription: "local").mayBeNetworkFailure, "Local quota failures default to non-network")
    for message in ["failed to refresh auth token: error sending request", "auth request timed out", "login endpoint: DNS lookup failed"] {
        try expect(!QuotaClient.isAuthenticationFailure(message), "Token-refresh transport failures must remain network failures")
    }
    for message in ["Not authenticated; please login", "HTTP 401 Unauthorized", "auth token expired"] {
        try expect(QuotaClient.isAuthenticationFailure(message), "Real login failures must remain authentication errors")
    }

    recovery.quotaFailed(mayBeNetworkFailure: true)
    recovery.quotaFailed(mayBeNetworkFailure: true)
    try expect(requestedChecks == 2 && shortcut.names.isEmpty, "Quota failures must request fresh checks without directly reconnecting")
    recovery.networkCheckCompleted(reachable: true)
    try expect(recovery.lastMessage?.contains("VPN reconnect skipped") == true, "A healthy check after quota failure must explain why reconnect was skipped")
    time += 200
    recovery.quotaFailed(mayBeNetworkFailure: true)
    recovery.networkCheckCompleted(reachable: true)
    try expect(shortcut.names.isEmpty, "Healthy connectivity must prevent reconnect even when quota queries fail and cooldown has elapsed")
    recovery.networkCheckCompleted(reachable: false)
    recovery.networkCheckCompleted(reachable: false)
    try expect(shortcut.names == ["reconnect VPN"], "Only a confirmed outage may run the configured shortcut")
    time += 200
    recovery.quotaFailed(mayBeNetworkFailure: false)
    recovery.networkCheckCompleted(reachable: false)
    try expect(shortcut.names.count == 1, "A running reconnect must not overlap, even after cooldown or a non-network error")
    shortcut.finish(.success(()))
    try expect(refreshes == 1, "A completed reconnect must request a fresh quota read")

    // Start another attempt, fail it, and enforce cooldown after failure too.
    settings.shortcutName = "another shortcut"
    recovery.networkCheckCompleted(reachable: false)
    try expect(shortcut.names == ["reconnect VPN", "another shortcut"], "Recovery must use the current configuration after cooldown")
    shortcut.finish(.failure(Failure(errorDescription: "permission denied")))
    try expect(refreshes == 1 && recovery.lastMessage?.contains("permission denied") == true, "Shortcut errors must be observable without claiming recovery")
    time += 179
    recovery.networkCheckCompleted(reachable: false)
    try expect(shortcut.names.count == 2, "Shortcut failure must not bypass cooldown")
    time += 1
    recovery.networkCheckCompleted(reachable: false)
    try expect(shortcut.names.count == 3, "Recovery becomes eligible after 180 seconds")
    settings.enabled = false
    time += 200
    shortcut.finish(.success(()))
    recovery.networkCheckCompleted(reachable: false)
    try expect(shortcut.names.count == 3, "Disabling recovery must prevent new attempts")
    settings.enabled = true
    recovery.networkCheckCompleted(reachable: false)
    try expect(shortcut.names.count == 4, "Recovery can be enabled again")
    recovery.stop()
    let stoppedRefreshes = refreshes
    shortcut.finish(.success(()))
    time += 200
    recovery.networkCheckCompleted(reachable: false)
    try expect(shortcut.names.count == 4 && refreshes == stoppedRefreshes, "Stopping must prevent callbacks from refreshing and prevent new runs")

    // The independent health check must recover even without a failed quota RPC.
    let healthShortcut = MockVPNShortcut()
    let healthRecovery = VPNRecovery(shortcut: healthShortcut, systemVPN: MockSystemVPNChecker(), now: { time }, logger: { _ in }, configuration: { settings })
    healthRecovery.networkCheckCompleted(reachable: true)
    try expect(healthShortcut.names.isEmpty, "Online health checks must not reconnect")
    healthRecovery.quotaFailed(mayBeNetworkFailure: false)
    healthRecovery.networkCheckCompleted(reachable: false)
    healthRecovery.networkCheckCompleted(reachable: false)
    try expect(healthShortcut.names.count == 1, "Offline health checks must trigger once despite successful/cached RPC or misleading auth classification")
    healthShortcut.finish(.success(()))
    time += 180
    healthRecovery.networkCheckCompleted(reachable: false)
    try expect(healthShortcut.names.count == 2, "Continued offline health checks must retry after cooldown")
    healthShortcut.finish(.success(()))

    let systemHeader = "Available network connection services in the current set (*=enabled):\n"
    func systemRow(_ status: String, name: String = "Office VPN") -> String {
        "* (\(status)) A30DC785-C4B5-4A9A-AB79-9D3D8DB28D77 VPN (com.wireguard.macos) \"\(name)\" [VPN:com.wireguard.macos]\n"
    }
    try expect(SystemVPNChecker.parse(systemHeader) == .clear, "No configured system VPNs must allow recovery")
    try expect(SystemVPNChecker.parse(systemHeader + systemRow("Disconnected", name: "Connected office")) == .clear, "A profile name must not be mistaken for its connection status")
    try expect(SystemVPNChecker.parse(systemHeader + systemRow("Disconnected") + systemRow("Connected", name: "办公 VPN")) == .otherVPNConnected, "Any connected system VPN must block Amnezia recovery")
    try expect(SystemVPNChecker.parse(systemHeader + systemRow("Connecting") + systemRow("Disconnecting")) == .clear, "Only the connected state triggers the requested exclusion")
    for output in ["", "access denied", systemHeader + "malformed row", systemHeader + systemRow("Unknown"), systemHeader + systemRow("Invalid")] {
        try expect(SystemVPNChecker.parse(output) == .unavailable, "Unknown system VPN status must not permit a reconnect")
    }

    let systemChecker = MockSystemVPNChecker()
    let guardedShortcut = MockVPNShortcut()
    var guardedSettings = VPNRecoveryConfiguration(enabled: true, shortcutName: "reconnect VPN")
    let guardedRecovery = VPNRecovery(shortcut: guardedShortcut, systemVPN: systemChecker, now: { time }, logger: { _ in }, configuration: { guardedSettings })
    guardedRecovery.networkCheckCompleted(reachable: true)
    try expect(systemChecker.checks == 0, "Healthy connectivity must not run system checks or reconnects")
    systemChecker.deferred = true
    guardedRecovery.networkCheckCompleted(reachable: false)
    guardedRecovery.networkCheckCompleted(reachable: false)
    try expect(systemChecker.checks == 1 && guardedShortcut.names.isEmpty, "Concurrent outage reports must share the pending system check")
    systemChecker.finish(.otherVPNConnected)
    try expect(guardedShortcut.names.isEmpty && guardedRecovery.lastMessage?.contains("Another system VPN") == true, "Another connected VPN must skip the shortcut and record the reason")
    guardedRecovery.networkCheckCompleted(reachable: false)
    systemChecker.finish(.unavailable)
    try expect(systemChecker.checks == 2 && guardedShortcut.names.isEmpty, "Each new decision must reread VPN state; failed reads must skip recovery")
    guardedRecovery.networkCheckCompleted(reachable: false)
    systemChecker.finish(.clear)
    try expect(systemChecker.checks == 3 && guardedShortcut.names.count == 1, "Skipped checks must not consume cooldown; a fresh clear result permits recovery")
    guardedShortcut.finish(.success(()))
    time += 180
    systemChecker.deferred = false
    systemChecker.state = .otherVPNConnected
    guardedRecovery.networkCheckCompleted(reachable: false)
    try expect(systemChecker.checks == 4 && guardedShortcut.names.count == 1, "A VPN connected since the previous attempt must block the next retry")
    systemChecker.state = .clear
    guardedRecovery.networkCheckCompleted(reachable: false)
    try expect(systemChecker.checks == 5 && guardedShortcut.names.count == 2, "Recovery may resume on a fresh check after the other VPN disconnects")
    guardedShortcut.finish(.success(()))
    time += 180
    systemChecker.deferred = true
    guardedRecovery.networkCheckCompleted(reachable: false)
    guardedRecovery.networkCheckCompleted(reachable: true)
    systemChecker.finish(.clear)
    try expect(guardedShortcut.names.count == 2, "Connectivity returning while the VPN check is pending must cancel the attempt")
    guardedRecovery.networkCheckCompleted(reachable: false)
    guardedSettings.enabled = false
    systemChecker.finish(.clear)
    try expect(guardedShortcut.names.count == 2, "Disabling recovery during a VPN check must cancel the attempt")
    guardedSettings.enabled = true
    guardedRecovery.networkCheckCompleted(reachable: false)
    guardedRecovery.stop()
    systemChecker.finish(.clear)
    try expect(guardedShortcut.names.count == 2, "Stopping during a VPN check must cancel the attempt")

    var display = QuotaDisplayState()
    display.networkUnavailable = true
    display.error = nil // A successful quota RPC must not clear the independent warning.
    try expect(display.warning != nil, "A quota success must not clear an offline warning")
    display.networkUnavailable = false
    try expect(display.warning == nil, "Connectivity recovery must clear the independent warning")
    display.error = "quota timed out"
    display.quotaNetworkReachable = true
    try expect(display.warning != display.error, "A quota warning must explain when connectivity passed and VPN recovery was skipped")
    display.networkUnavailable = true
    try expect(display.warning?.contains("VPN") == false, "A confirmed outage must take precedence over an earlier passing service check")

    let roots = FileManager.default.temporaryDirectory.appendingPathComponent("vpn-export-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: roots) }
    let app = roots.appendingPathComponent("reconnect VPN.app")
    let info = app.appendingPathComponent("Contents/Info.plist")
    try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.apple.shortcuts.droplet.fixture"], format: .xml, options: 0).write(to: info)
    let exported = VPNShortcutCommand.resolve(name: "reconnect VPN", applicationRoots: [roots])
    try expect(exported == VPNShortcutCommand(executable: "/usr/bin/open", arguments: ["-W", "-n", app.path]), "An exported shortcut must launch independently through LaunchServices")
    try expect(VPNShortcutCommand.resolve(name: "missing", applicationRoots: [roots]).executable == "/usr/bin/shortcuts", "A shortcut without an exported app must retain CLI support")
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "not.a.shortcut"], format: .xml, options: 0).write(to: info)
    try expect(VPNShortcutCommand.resolve(name: "reconnect VPN", applicationRoots: [roots]).executable == "/usr/bin/shortcuts", "An unrelated app with the same name must not be launched")

    // Real URLSession request flow, with URLProtocol providing all responses locally.
    let probeCases: [(VPNNetworkCheck.Target, [String: Int], Bool)] = [
        (.internet, ["primary.test": 0, "secondary.test": 0], false),
        (.internet, ["primary.test": 0, "secondary.test": 204], true),
        (.internet, ["primary.test": 403, "secondary.test": 0], true),
        (.codex, ["primary.test": 0, "secondary.test": 204], false),
        (.codex, ["primary.test": 403, "secondary.test": 0], false),
        (.codex, ["primary.test": 401, "secondary.test": 500], true)
    ]
    try expect(VPNNetworkCheck.Target.codex.endpoints.compactMap(\.host) == ["chatgpt.com", "auth.openai.com"], "Quota failures must probe the actual quota and authentication routes")
    for (target, statuses, expected) in probeCases {
        MockVPNURLProtocol.lock.lock()
        MockVPNURLProtocol.responses = statuses
        MockVPNURLProtocol.lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockVPNURLProtocol.self]
        let checker = VPNNetworkCheck(configuration: configuration, endpoints: [URL(string: "https://primary.test")!, URL(string: "https://secondary.test")!])
        var result: Bool?
        var completions = 0
        let checkedShortcut = MockVPNShortcut()
        let checkedRecovery = VPNRecovery(shortcut: checkedShortcut, systemVPN: MockSystemVPNChecker(), logger: { _ in }, configuration: { settings })
        checkedRecovery.onNetworkCheckRequested = {
            checker.check(target: target) { reachable in
                result = reachable
                completions += 1
                checkedRecovery.networkCheckCompleted(reachable: reachable, target: target)
            }
        }
        checkedRecovery.quotaFailed(mayBeNetworkFailure: true)
        checker.check(target: target) { _ in completions += 100 }
        let deadline = Date().addingTimeInterval(3)
        while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try expect(result == expected && completions == 1, "The checker must merge probes, avoid overlap, and finish once")
        try expect(checkedShortcut.names.count == (expected ? 0 : 1), "Only failed connectivity probes may trigger recovery; HTTP errors prove a route is reachable")
        checker.check(target: target) { _ in completions += 100 }
        checker.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try expect(completions == 1, "Canceled health checks must not deliver stale results")
    }

    // Switching from general checks to service checks must discard earlier
    // passing callbacks, rather than letting an unrelated site hide an outage.
    MockVPNURLProtocol.lock.lock()
    MockVPNURLProtocol.responses = ["primary.test": 204, "secondary.test": 0]
    MockVPNURLProtocol.lock.unlock()
    let switchingConfiguration = URLSessionConfiguration.ephemeral
    switchingConfiguration.protocolClasses = [MockVPNURLProtocol.self]
    let switchingChecker = VPNNetworkCheck(configuration: switchingConfiguration, endpoints: [URL(string: "https://primary.test")!, URL(string: "https://secondary.test")!])
    var switchedResult: Bool?
    var staleResults = 0
    switchingChecker.check { _ in staleResults += 1 }
    switchingChecker.check(target: .codex) { switchedResult = $0 }
    let switchDeadline = Date().addingTimeInterval(3)
    while switchedResult == nil && Date() < switchDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    try expect(switchedResult == false && staleResults == 0, "Changing probe targets must cancel general checks and report the failing service route")

    // Exercise real process handling with harmless system commands, never Shortcuts.
    func run(_ runner: VPNShortcutRunner, name: String = "reconnect VPN") throws -> Result<Void, Error> {
        var outcome: Result<Void, Error>?
        var completions = 0
        runner.run(name: name) { result in outcome = result; completions += 1 }
        let deadline = Date().addingTimeInterval(5)
        while outcome == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard let outcome else { throw Failure(errorDescription: "Process completion timed out") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try expect(completions == 1, "Process completion must fire exactly once")
        return outcome
    }
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("vpn-recovery-injection-\(UUID().uuidString)")
    let literalName = "reconnect VPN; touch \(marker.path)"
    try run(VPNShortcutRunner(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: { ["%s", $0] }), name: literalName).get()
    try expect(!FileManager.default.fileExists(atPath: marker.path), "Shortcut names must be passed literally, never evaluated by a shell")
    if case .success = try run(VPNShortcutRunner(executable: URL(fileURLWithPath: "/usr/bin/false"))) {
        throw Failure(errorDescription: "A non-zero process exit must report failure")
    }
    if case .success = try run(VPNShortcutRunner(executable: URL(fileURLWithPath: "/private/tmp/missing-\(UUID().uuidString)"))) {
        throw Failure(errorDescription: "Failure to launch must report failure")
    }
    let timeout = try run(VPNShortcutRunner(executable: URL(fileURLWithPath: "/bin/sleep"), timeout: 0.05, arguments: { _ in ["2"] }))
    guard case .failure(let error) = timeout, error.localizedDescription.contains("timed out") else {
        throw Failure(errorDescription: "A hung command must time out")
    }

    func checkSystemVPN(_ checker: SystemVPNChecker) throws -> SystemVPNState {
        var result: SystemVPNState?
        var callbacks = 0
        checker.check { result = $0; callbacks += 1 }
        let deadline = Date().addingTimeInterval(3)
        while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard let result, callbacks == 1 else { throw Failure(errorDescription: "System VPN checker must finish exactly once") }
        return result
    }
    let fixtureCommand = URL(fileURLWithPath: "/usr/bin/printf")
    try expect(try checkSystemVPN(SystemVPNChecker(executable: fixtureCommand, arguments: ["%s", systemHeader + systemRow("Connected")])) == .otherVPNConnected, "The real process reader must report a connected VPN")
    try expect(try checkSystemVPN(SystemVPNChecker(executable: fixtureCommand, arguments: ["%s", systemHeader + systemRow("Disconnected")])) == .clear, "The real process reader must report disconnected profiles correctly")
    try expect(try checkSystemVPN(SystemVPNChecker(executable: URL(fileURLWithPath: "/usr/bin/false"))) == .unavailable, "A failed system query must block recovery")
    try expect(try checkSystemVPN(SystemVPNChecker(executable: URL(fileURLWithPath: "/private/tmp/missing-vpn-query"))) == .unavailable, "A system query launch failure must block recovery")
    try expect(try checkSystemVPN(SystemVPNChecker(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"], timeout: 0.05)) == .unavailable, "A timed-out system query must block recovery")
    print("Passed: fresh system VPN checks before every attempt, connected-VPN exclusion, failed-check exclusion, pending-check cancellation, independent health checks, transport/auth classification, exported-app routing, cooldown, no overlap and process timeouts. No real shortcut or VPN was run.")
}
