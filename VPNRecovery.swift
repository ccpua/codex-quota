import Foundation

enum VPNRecoveryLog {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CodexQuota/vpn-recovery.log")
    private static let queue = DispatchQueue(label: "local.codexquota.vpn-log")

    static func write(_ message: String) {
        NSLog("VPN recovery: %@", message)
        queue.sync {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 262_144 { try Data().write(to: fileURL) }
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                NSLog("Cannot write VPN recovery log: %@", error.localizedDescription)
            }
        }
    }
}

/// Probe independently of quota requests: a successful/cached RPC is not a
/// connectivity test, and a token-refresh transport failure may look like auth.
final class VPNNetworkCheck {
    enum Target: String {
        case internet
        case codex

        var endpoints: [URL] {
            switch self {
            case .internet:
                return [URL(string: "https://www.gstatic.com/generate_204")!,
                        URL(string: "https://cp.cloudflare.com/generate_204")!]
            case .codex:
                return [URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                        URL(string: "https://auth.openai.com/")!]
            }
        }
    }

    private let session: URLSession
    private let endpoints: [URL]?
    private var tasks: [URLSessionDataTask] = []
    private var generation = 0
    private var activeTarget: Target?

    init(configuration: URLSessionConfiguration = .ephemeral,
         endpoints: [URL]? = nil) {
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 6
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        self.endpoints = endpoints
    }

    func check(target: Target = .internet, _ completion: @escaping (Bool) -> Void) {
        // A quota transport failure must check its own routes. A response from
        // an unrelated site cannot establish that a split-tunnel route works.
        if !tasks.isEmpty {
            guard activeTarget != target else { return }
            cancel()
        }
        let endpoints = self.endpoints ?? target.endpoints
        guard !endpoints.isEmpty else { return }
        activeTarget = target
        generation += 1
        let currentGeneration = generation
        var remaining = endpoints.count
        for endpoint in endpoints {
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            request.httpMethod = "HEAD"
            let task = session.dataTask(with: request) { [weak self] _, response, _ in
                DispatchQueue.main.async {
                    guard let self, self.generation == currentGeneration else { return }
                    remaining -= 1
                    // Any HTTPS response proves reachability. HTTP 403/500 from
                    // a service is not a reason to repeatedly restart the VPN.
                    let reachable = response is HTTPURLResponse
                    // General internet checks accept either endpoint. Codex
                    // needs both the quota and login routes to be reachable.
                    if target == .codex && !reachable {
                        self.cancel()
                        completion(false)
                    } else if target == .internet && reachable {
                        self.cancel()
                        completion(true)
                    } else if remaining == 0 {
                        self.cancel()
                        completion(target == .codex)
                    }
                }
            }
            tasks.append(task)
            task.resume()
        }
    }

    func cancel() {
        generation += 1
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        activeTarget = nil
    }
}

struct VPNRecoveryConfiguration: Equatable {
    var enabled: Bool
    var shortcutName: String

    var canRun: Bool { enabled && !shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

protocol VPNShortcutRunning: AnyObject {
    func run(name: String, completion: @escaping (Result<Void, Error>) -> Void)
}

enum SystemVPNState: Equatable {
    case clear
    case otherVPNConnected
    case unavailable
}

protocol SystemVPNChecking: AnyObject {
    func check(_ completion: @escaping (SystemVPNState) -> Void)
}

/// The shortcut-controlled AmneziaVPN uses its own daemon, outside the system
/// VPN list. Any connected service in that list therefore belongs to another
/// VPN. Do not infer this from utun interfaces: Amnezia itself creates those.
final class SystemVPNChecker: SystemVPNChecking {
    private let executable: URL
    private let arguments: [String]
    private let timeout: TimeInterval

    init(executable: URL = URL(fileURLWithPath: "/usr/sbin/scutil"),
         arguments: [String] = ["--nc", "list"], timeout: TimeInterval = 5) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
    }

    static func parse(_ output: String) -> SystemVPNState {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first == "Available network connection services in the current set (*=enabled):" else { return .unavailable }
        let row = try! NSRegularExpression(pattern: #"^\*?\s*\((Connected|Disconnected|Connecting|Disconnecting|Invalid)\)\s+[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\s+.+$"#)
        var connected = false
        for line in lines.dropFirst() {
            guard let match = row.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let statusRange = Range(match.range(at: 1), in: line) else { return .unavailable }
            let status = String(line[statusRange])
            if status == "Invalid" { return .unavailable }
            if status == "Connected" { connected = true }
        }
        return connected ? .otherVPNConnected : .clear
    }

    func check(_ completion: @escaping (SystemVPNState) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = self.executable
            process.arguments = self.arguments
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            let expiry = DispatchWorkItem { if process.isRunning { process.terminate() } }
            let state: SystemVPNState
            do {
                try process.run()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.timeout, execute: expiry)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationReason == .exit && process.terminationStatus == 0,
                   let text = String(data: data, encoding: .utf8) {
                    state = Self.parse(text)
                } else {
                    state = .unavailable
                }
            } catch {
                state = .unavailable
            }
            expiry.cancel()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            DispatchQueue.main.async { completion(state) }
        }
    }
}

struct VPNShortcutCommand: Equatable {
    let executable: String
    let arguments: [String]

    static func resolve(name: String, applicationRoots: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        URL(fileURLWithPath: "/Applications")
    ]) -> VPNShortcutCommand {
        // A Shortcuts-exported app has its own, already-granted permission identity.
        // Launch it through LaunchServices instead of inheriting this app's identity.
        if !name.isEmpty && !name.contains("/") {
            for root in applicationRoots {
                let app = root.appendingPathComponent(name + ".app")
                let info = app.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: info),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let identifier = plist["CFBundleIdentifier"] as? String,
                      identifier.hasPrefix("com.apple.shortcuts.droplet.") else { continue }
                return VPNShortcutCommand(executable: "/usr/bin/open", arguments: ["-W", "-n", app.path])
            }
        }
        return VPNShortcutCommand(executable: "/usr/bin/shortcuts", arguments: ["run", name])
    }
}

final class VPNShortcutLauncher: VPNShortcutRunning {
    func run(name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let command = VPNShortcutCommand.resolve(name: name)
        VPNRecoveryLog.write("Launch: \(command.executable) \(command.arguments)")
        let runner = VPNShortcutRunner(executable: URL(fileURLWithPath: command.executable), arguments: { _ in command.arguments })
        runner.run(name: name, completion: completion)
    }
}

/// Runs the exact shortcut name as one argument, without a shell.
final class VPNShortcutRunner: VPNShortcutRunning {
    struct Failure: LocalizedError { let errorDescription: String? }
    private let executable: URL
    private let arguments: (String) -> [String]
    private let timeout: TimeInterval

    init(executable: URL = URL(fileURLWithPath: "/usr/bin/shortcuts"),
         timeout: TimeInterval = 150,
         arguments: @escaping (String) -> [String] = { ["run", $0] }) {
        self.executable = executable
        self.timeout = timeout
        self.arguments = arguments
    }

    func run(name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(name)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let output = Pipe()
        process.standardError = output
        // Drain stderr while the process is running, with a bounded tail for diagnostics.
        let queue = DispatchQueue(label: "local.codexquota.vpn-shortcut")
        var errorOutput = Data()
        var finished = false
        var timedOut = false
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            queue.async {
                errorOutput.append(data)
                if errorOutput.count > 8192 { errorOutput = Data(errorOutput.suffix(8192)) }
            }
        }
        func finish(_ result: Result<Void, Error>) {
            guard !finished else { return }
            finished = true
            output.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { completion(result) }
        }
        process.terminationHandler = { process in
            queue.async {
                if timedOut {
                    finish(.failure(Failure(errorDescription: "Shortcut timed out after \(Int(self.timeout)) seconds.")))
                } else if process.terminationReason == .exit && process.terminationStatus == 0 {
                    finish(.success(()))
                } else {
                    let detail = String(data: errorOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let message = detail.isEmpty ? "Shortcut exited with status \(process.terminationStatus)." : detail
                    finish(.failure(Failure(errorDescription: message)))
                }
            }
        }
        do {
            try process.run()
        } catch {
            queue.async { finish(.failure(error)) }
            return
        }
        queue.asyncAfter(deadline: .now() + timeout) {
            guard !finished, process.isRunning else { return }
            timedOut = true
            process.terminate()
            // Do not overlap another shortcut if this process ignores termination.
            // The completion arrives only when the process actually exits.
        }
    }
}

/// All policy state is used on the main queue, like AppDelegate's quota results.
final class VPNRecovery {
    private let shortcut: VPNShortcutRunning
    private let systemVPN: SystemVPNChecking
    private let configuration: () -> VPNRecoveryConfiguration
    private let now: () -> TimeInterval
    private let cooldown: TimeInterval
    private let logger: (String) -> Void
    private var running = false
    private var checkingSystemVPN = false
    private var networkReachable = true
    private var stopped = false
    private var lastAttempt: TimeInterval?
    private var lastConnectivity: String?
    private var awaitingQuotaNetworkCheck = false
    private var lastSkip: String?
    private(set) var lastMessage: String?
    var onReconnect: (() -> Void)?
    var onStatusChange: (() -> Void)?
    var onNetworkCheckRequested: (() -> Void)?

    init(shortcut: VPNShortcutRunning = VPNShortcutLauncher(),
         systemVPN: SystemVPNChecking = SystemVPNChecker(),
         cooldown: TimeInterval = 180,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         logger: @escaping (String) -> Void = VPNRecoveryLog.write,
         configuration: @escaping () -> VPNRecoveryConfiguration) {
        self.shortcut = shortcut
        self.systemVPN = systemVPN
        self.cooldown = cooldown
        self.now = now
        self.configuration = configuration
        self.logger = logger
    }

    func networkCheckCompleted(reachable: Bool, target: VPNNetworkCheck.Target = .internet) {
        guard !stopped else { return }
        networkReachable = reachable
        let status = "Connectivity check (\(target.rawValue)): \(reachable ? "online" : "offline")"
        if lastConnectivity != status {
            lastConnectivity = status
            log(status)
        }
        if reachable && awaitingQuotaNetworkCheck {
            skip("Quota request failed, but connectivity checks passed. VPN reconnect skipped.")
        }
        awaitingQuotaNetworkCheck = false
        if !reachable { reconnectAfterConfirmedOutage() }
    }

    func quotaFailed(mayBeNetworkFailure: Bool) {
        // A quota/API failure is only a reason to check connectivity. It must
        // never directly restart a healthy connection, even after the cooldown.
        guard mayBeNetworkFailure, !stopped, configuration().canRun else { return }
        awaitingQuotaNetworkCheck = true
        onNetworkCheckRequested?()
    }

    private func reconnectAfterConfirmedOutage() {
        let settings = configuration()
        guard !stopped else { return }
        guard settings.canRun else { skip("Automatic reconnect is disabled or has no shortcut configured."); return }
        guard !running else { skip("Reconnect is already running."); return }
        guard !checkingSystemVPN else { return }
        if let lastAttempt, now() - lastAttempt < cooldown {
            skip("Waiting for the 180-second reconnect interval."); return
        }
        // Query afresh immediately before each attempt, including retries. A
        // skipped check must not consume the reconnect cooldown.
        checkingSystemVPN = true
        systemVPN.check { [weak self] state in
            guard let self else { return }
            self.checkingSystemVPN = false
            guard !self.stopped, !self.networkReachable, self.configuration().canRun else { return }
            switch state {
            case .otherVPNConnected:
                self.skip("Another system VPN is connected. Amnezia reconnect skipped.")
            case .unavailable:
                self.skip("Cannot determine system VPN status. Amnezia reconnect skipped.")
            case .clear:
                self.startReconnect()
            }
        }
    }

    private func startReconnect() {
        let settings = configuration()
        lastSkip = nil
        running = true
        lastAttempt = now()
        log("Running shortcut: \(settings.shortcutName)")
        shortcut.run(name: settings.shortcutName) { [weak self] result in
            guard let self else { return }
            self.running = false
            switch result {
            case .success:
                self.log("Reconnect launcher finished; checking connectivity: \(settings.shortcutName)")
                if !self.stopped { self.onReconnect?() }
            case .failure(let error):
                self.log("Shortcut failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        stopped = true
        // Do not interrupt a shortcut halfway through disconnect -> connect.
    }

    private func log(_ message: String) {
        lastMessage = message
        logger(message)
        onStatusChange?()
    }

    private func skip(_ message: String) {
        guard lastSkip != message || lastMessage != message else { return }
        lastSkip = message
        log(message)
    }
}
