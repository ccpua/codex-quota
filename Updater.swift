import AppKit

var currentAppVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.6"
}
private let updateVersionEndpoint = URL(string: "https://assets-dev-1412625299.cos.ap-guangzhou.myqcloud.com/codex-quota/config/codex_reset_version")!
private let updateDownloadBase = URL(string: "https://github.com/ccpua/codex-quota/releases/download/")!

struct AppVersion: Comparable, Equatable {
    let components: [Int]
    let string: String
    let releaseTag: String

    init?(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.compactMap({ Int($0) }).count == 3 else { return nil }
        components = parts.compactMap { Int($0) }
        string = number
        releaseTag = "v\(number)"
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

func updateDownloadURL(for version: String) -> URL? {
    guard let version = AppVersion(version) else { return nil }
    return updateDownloadBase
        .appendingPathComponent(version.releaseTag, isDirectory: true)
        .appendingPathComponent("Codex-Quota-\(version.string)-arm64.dmg")
}

final class UpdateClient {
    struct Failure: LocalizedError { let errorDescription: String? }
    private var versionTask: URLSessionDataTask?
    private var downloadTask: URLSessionDownloadTask?

    func checkVersion(completion: @escaping (Result<AppVersion, Error>) -> Void) {
        versionTask?.cancel()
        var components = URLComponents(url: updateVersionEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "check", value: String(Int(Date().timeIntervalSince1970 / 3600)))]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        versionTask = URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<AppVersion, Error>
            if let error = error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                result = .failure(Failure(errorDescription: tr("版本服务返回 HTTP \(http.statusCode)。", "The update service returned HTTP \(http.statusCode).")))
            } else if let data, let raw = String(data: data, encoding: .utf8), let version = AppVersion(raw) {
                result = .success(version)
            } else {
                result = .failure(Failure(errorDescription: tr("远程版本号格式无效。", "The remote version number is invalid.")))
            }
            DispatchQueue.main.async { completion(result) }
        }
        versionTask?.resume()
    }

    func download(version: AppVersion, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let url = updateDownloadURL(for: version.string) else {
            completion(.failure(Failure(errorDescription: tr("下载地址无效。", "The download URL is invalid."))))
            return
        }
        downloadTask?.cancel()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 600)
        request.setValue("application/x-apple-diskimage", forHTTPHeaderField: "Accept")
        downloadTask = URLSession.shared.downloadTask(with: request) { temporaryURL, response, error in
            let result: Result<URL, Error>
            do {
                if let error { throw error }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw Failure(errorDescription: tr("更新下载返回 HTTP \(http.statusCode)。", "The update download returned HTTP \(http.statusCode)."))
                }
                guard let temporaryURL else { throw Failure(errorDescription: tr("更新下载失败。", "The update download failed.")) }
                let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("local.ming.codexquota/Updates", isDirectory: true)
                try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
                let destination = cacheRoot.appendingPathComponent("Codex-Quota-\(version.string)-arm64.dmg")
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                result = .success(destination)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
        downloadTask?.resume()
    }

    func stop() {
        versionTask?.cancel(); versionTask = nil
        downloadTask?.cancel(); downloadTask = nil
    }
}

struct PreparedUpdate {
    let target: URL
    let staged: URL
    let requiresPrivileges: Bool
}

enum UpdateInstaller {
    struct Failure: LocalizedError { let errorDescription: String? }

    static func prepare(dmg: URL, version: AppVersion) throws -> PreparedUpdate {
        let target = Bundle.main.bundleURL.standardizedFileURL
        guard target.pathExtension == "app", target.path != "/" else {
            throw Failure(errorDescription: tr("无法确定当前应用位置。", "The current app location could not be determined."))
        }
        guard !target.path.hasPrefix("/Volumes/") else {
            throw Failure(errorDescription: tr("请先将应用拖到“应用程序”文件夹，再执行更新。", "Move the app to Applications before updating."))
        }
        let parent = target.deletingLastPathComponent()
        let requiresPrivileges = !FileManager.default.isWritableFile(atPath: parent.path)

        let attach = try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-plist", dmg.path])
        guard let plist = try PropertyListSerialization.propertyList(from: attach, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPath = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw Failure(errorDescription: tr("无法挂载更新镜像。", "The update disk image could not be mounted."))
        }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mountPath, "-force"]) }

        let source = URL(fileURLWithPath: mountPath).appendingPathComponent("Codex Quota.app", isDirectory: true)
        guard let bundle = Bundle(url: source),
              bundle.bundleIdentifier == "local.ming.codexquota",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version.string else {
            throw Failure(errorDescription: tr("更新包中的应用或版本不匹配。", "The app or version in the update does not match."))
        }
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", source.path])

        let stagingRoot: URL
        if requiresPrivileges {
            stagingRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("local.ming.codexquota/Installer/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        } else {
            stagingRoot = parent
        }
        let staged = stagingRoot.appendingPathComponent(".Codex Quota-\(UUID().uuidString).app", isDirectory: true)
        do {
            _ = try run("/usr/bin/ditto", [source.path, staged.path])
            _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return PreparedUpdate(target: target, staged: staged, requiresPrivileges: requiresPrivileges)
    }

    static func launchInstaller(_ update: PreparedUpdate) throws {
        let script = """
        pid="$1"
        target="$2"
        staged="$3"
        backup="${target}.previous"
        while /bin/kill -0 "$pid" 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$backup"
        if /bin/mv "$target" "$backup" && /bin/mv "$staged" "$target"; then
          /usr/bin/open -g "$target"
          /bin/rm -rf "$backup"
        else
          /bin/rm -rf "$target"
          if [ -e "$backup" ]; then
            /bin/mv "$backup" "$target"
            /usr/bin/open -g "$target"
          fi
        fi
        """
        let arguments = [script, "\(ProcessInfo.processInfo.processIdentifier)", update.target.path, update.staged.path]
        if update.requiresPrivileges {
            let appleScript = """
            on run argv
              set commandText to "/usr/bin/nohup /bin/zsh -c " & quoted form of item 1 of argv & " codex-quota-updater " & quoted form of item 2 of argv & " " & quoted form of item 3 of argv & " " & quoted form of item 4 of argv & " >/dev/null 2>&1 &"
              do shell script commandText with administrator privileges
            end run
            """
            _ = try run("/usr/bin/osascript", ["-e", appleScript] + arguments)
        } else {
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/zsh")
            helper.arguments = ["-c", script, "codex-quota-updater"] + Array(arguments.dropFirst())
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            try helper.run()
        }
    }

    @discardableResult private static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(errorDescription: detail?.isEmpty == false ? detail : tr("更新安装失败。", "The update could not be installed."))
        }
        return data
    }
}
