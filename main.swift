import AppKit

private let benefitResetEndpoint = URL(string: "https://config-center-1412625299.cos.ap-guangzhou.myqcloud.com/config/test/codex_reset")!

func parseBenefitReset(_ raw: String) -> Date? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    if let seconds = TimeInterval(value), seconds.isFinite, seconds > 0 {
        return Date(timeIntervalSince1970: seconds)
    }
    let local = DateFormatter()
    local.locale = Locale(identifier: "en_US_POSIX")
    local.calendar = Calendar(identifier: .gregorian)
    local.timeZone = TimeZone(identifier: "Asia/Shanghai")
    local.dateFormat = "yyyy-MM-dd HH:mm:ss"
    if let date = local.date(from: value) { return date }
    return ISO8601DateFormatter().date(from: value)
}

struct QuotaWindow {
    let used: Double
    let minutes: Int
    let reset: Date?
    var remaining: Int { Int(max(0, min(100, 100 - used)).rounded()) }
    var name: String {
        if usesEnglish {
            if minutes == 10080 { return "Weekly" }
            if minutes >= 1440 { return "\(minutes / 1440)-day" }
            if minutes >= 60 { return "\(minutes / 60)-hour" }
            return "\(minutes)-minute"
        }
        if minutes == 10080 { return "本周额度" }
        if minutes == 300 { return "5 小时额度" }
        if minutes >= 1440 { return "\(minutes / 1440) 天额度" }
        if minutes >= 60 { return "\(minutes / 60) 小时额度" }
        return "\(minutes) 分钟额度"
    }
    init?(_ raw: Any?) {
        guard let d = raw as? [String: Any], let used = d["usedPercent"] as? Double,
              let minutes = d["windowDurationMins"] as? Int, used.isFinite, minutes > 0 else { return nil }
        self.used = used; self.minutes = minutes
        reset = (d["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
    }
}

func quotaWindows(_ result: [String: Any]) -> [QuotaWindow] {
    let buckets = result["rateLimitsByLimitId"] as? [String: Any]
    let bucket = (buckets?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any]) ?? [:]
    return [QuotaWindow(bucket["primary"]), QuotaWindow(bucket["secondary"])].compactMap { $0 }
}

final class QuotaClient {
    private let queue = DispatchQueue(label: "local.codexquota.rpc")
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var ready = false
    private var nextID = 10
    private var pending: Int?
    private var generation = 0
    private var lastRequest = Date.distantPast
    var onResult: ((Result<[QuotaWindow], Error>) -> Void)?
    struct Failure: LocalizedError { let errorDescription: String? }

    func refresh() { queue.async { self.refreshOnQueue() } }
    func stop() { queue.sync { self.disconnect() } }
    private func disconnect() {
        generation += 1
        process?.standardOutput.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil; input = nil; ready = false; pending = nil; buffer.removeAll()
    }
    private func report(_ result: Result<[QuotaWindow], Error>) {
        DispatchQueue.main.async { self.onResult?(result) }
    }
    private func fail(_ message: String) {
        disconnect(); report(.failure(Failure(errorDescription: message)))
    }
    private func refreshOnQueue() {
        if pending != nil { return }
        if process == nil { start(); return }
        if ready { requestQuota() }
    }
    private func start() {
        let candidates = ["/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            report(.failure(Failure(errorDescription: "未找到 Codex，请先安装并登录。"))); return
        }
        generation += 1
        let currentGeneration = generation
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["app-server"]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting
        process = p
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { [weak self] in
                guard let self = self, self.generation == currentGeneration else { return }
                self.buffer.append(data)
                while let end = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer[..<end]
                    self.buffer.removeSubrange(...end)
                    if let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { self.receive(message) }
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self = self, self.generation == currentGeneration else { return }
                self.fail("连接已断开，将在下次刷新时重连。")
            }
        }
        do { try p.run() } catch { fail("无法启动 Codex：\(error.localizedDescription)"); return }
        send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex_quota_monitor", "title": "Codex Quota", "version": "1.6.0"]]])
        queue.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self = self, self.generation == currentGeneration, !self.ready else { return }
            self.fail("连接超时，请检查网络后重试。")
        }
    }
    private func send(_ value: [String: Any]) {
        guard let input = input, var data = try? JSONSerialization.data(withJSONObject: value) else { return }
        data.append(10)
        do { try input.write(contentsOf: data) } catch { fail("无法连接 Codex，将自动重试。") }
    }
    private func requestQuota() {
        lastRequest = Date()
        nextID += 1; let id = nextID; pending = id
        let currentGeneration = generation
        send(["id": id, "method": "account/rateLimits/read"])
        queue.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self = self, self.generation == currentGeneration, self.pending == id else { return }
            self.fail("查询超时，保留上次数据；稍后自动重试。")
        }
    }
    private func receive(_ message: [String: Any]) {
        if let id = message["id"] as? Int {
            if let error = message["error"] as? [String: Any], id == 1 || id == pending {
                let raw = (error["message"] as? String ?? "").lowercased()
                fail(raw.contains("auth") || raw.contains("login") || raw.contains("401") ? "请在 Codex 中登录后，再点刷新。" : "额度查询失败，请检查网络后刷新。")
                return
            }
            if id == 1 {
                ready = true; send(["method": "initialized"]); requestQuota()
            } else if id == pending, let result = message["result"] as? [String: Any] {
                pending = nil
                let windows = quotaWindows(result)
                if windows.isEmpty { report(.failure(Failure(errorDescription: "当前账号未返回可用额度数据。"))) }
                else { report(.success(windows)) }
            }
        }
        // Partial server notifications are followed by a fresh read, so missing windows never become zero.
        if message["method"] as? String == "account/rateLimits/updated", pending == nil, Date().timeIntervalSince(lastRequest) > 10 { requestQuota() }
    }
}

final class BenefitResetClient {
    private var task: URLSessionDataTask?
    var onResult: ((Result<Date, Error>) -> Void)?
    struct Failure: LocalizedError { let errorDescription: String? }

    func refresh() {
        task?.cancel()
        var request = URLRequest(url: benefitResetEndpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let result: Result<Date, Error>
            if let error = error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                result = .failure(Failure(errorDescription: "福利重置预测服务返回 HTTP \(http.statusCode)。"))
            } else if let data = data, let raw = String(data: data, encoding: .utf8), let date = parseBenefitReset(raw) {
                result = .success(date)
            } else {
                result = .failure(Failure(errorDescription: "福利重置预测时间格式无效。"))
            }
            DispatchQueue.main.async { self?.onResult?(result) }
        }
        task?.resume()
    }

    func stop() { task?.cancel(); task = nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let client = QuotaClient()
    let benefitClient = BenefitResetClient()
    var statusItem: NSStatusItem!
    var panel: NSPanel!
    var timer: Timer?
    var benefitTimer: Timer?
    var terminationSignal: DispatchSourceSignal?
    var state = QuotaDisplayState(refreshing: true, benefitResetLoading: true)
    var surface: HoverSurface!
    var expanded = false
    var capsuleOrigin = NSPoint.zero
    var hoverWork: DispatchWorkItem?
    var transitionTimer: Timer?
    var dragging = false
    var menuOpen = false
    var resultSucceeded = false
    let smokeTest = CommandLine.arguments.contains("--smoke-test")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = configuredAppearance
        UserDefaults.standard.register(defaults: ["pinned": true])
        state.pinned = UserDefaults.standard.bool(forKey: "pinned")
        let cachedBenefitReset = UserDefaults.standard.double(forKey: "benefitResetPrediction")
        if cachedBenefitReset > 0 {
            state.benefitReset = Date(timeIntervalSince1970: cachedBenefitReset)
            state.benefitResetLoading = false
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 96, height: 34), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Codex Quota"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = state.pinned ? .floating : .normal
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            capsuleOrigin = NSPoint(x: visible.maxX - 116, y: visible.maxY - 74)
        }
        if !smokeTest, let saved = UserDefaults.standard.array(forKey: "capsuleOrigin") as? [Double], saved.count == 2 {
            capsuleOrigin = NSPoint(x: saved[0], y: saved[1])
        }
        panel.setFrameOrigin(capsuleOrigin)
        surface = HoverSurface(frame: panel.contentView!.bounds)
        panel.contentView = surface
        surface.onHover = { [weak self] inside in self?.handleHover(inside) }
        surface.onDragStart = { [weak self] in self?.transitionTimer?.invalidate(); self?.transitionTimer = nil; self?.surface.finishImmediateLayout(); self?.dragging = true; self?.hoverWork?.cancel() }
        surface.onDragEnd = { [weak self] in
            guard let self = self else { return }
            self.dragging = false
            self.capsuleOrigin = NSPoint(x: self.surface.anchorRight && self.expanded ? self.panel.frame.maxX - 96 : self.panel.frame.minX, y: self.panel.frame.maxY - 34)
            self.savePosition()
            self.handleHover(self.panel.frame.contains(NSEvent.mouseLocation))
        }
        client.onResult = { [weak self] result in
            guard let self = self else { return }
            self.state.refreshing = false
            switch result {
            case .success(let windows):
                self.state.windows = windows; self.state.lastUpdated = Date(); self.state.error = nil
                self.resultSucceeded = true
            case .failure(let error): self.state.error = error.localizedDescription
            }
            self.render()
            if self.smokeTest {
                print(self.state.error ?? "Connected: \(self.state.windows.map { "\($0.name) remaining=\($0.remaining)%" }.joined(separator: ", "))")
                NSApp.terminate(nil)
            }
        }
        benefitClient.onResult = { [weak self] result in
            guard let self = self else { return }
            self.state.benefitResetLoading = false
            switch result {
            case .success(let date):
                self.state.benefitReset = date
                self.state.benefitResetUnavailable = false
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "benefitResetPrediction")
            case .failure:
                self.state.benefitResetUnavailable = self.state.benefitReset == nil
            }
            self.render()
        }
        render()
        if !smokeTest { panel.orderFrontRegardless() }
        client.refresh()
        benefitClient.refresh()
        let predictionTimer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            self?.benefitClient.refresh()
        }
        benefitTimer = predictionTimer
        RunLoop.main.add(predictionTimer, forMode: .common)
        scheduleRefresh()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
        signal(SIGTERM, SIG_IGN)
        terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSignal?.setEventHandler { NSApp.terminate(nil) }
        terminationSignal?.resume()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !smokeTest { showPanel() }
        return false
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); benefitTimer?.invalidate(); transitionTimer?.invalidate(); client.stop(); benefitClient.stop(); terminationSignal?.cancel()
        hoverWork?.cancel()
        if !smokeTest { savePosition() }
    }
    func scheduleRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshIntervalSeconds, repeats: true) { [weak self] _ in self?.refreshQuota() }
    }
    @objc func configureRefreshInterval() {
        menuOpen = true
        hoverWork?.cancel()
        defer { menuOpen = false; handleHover(panel.frame.contains(NSEvent.mouseLocation)) }
        let alert = NSAlert()
        alert.messageText = tr("自动刷新间隔", "Refresh interval")
        alert.informativeText = tr("输入 10–3600 秒。保存后立即生效，并在下次启动时保留。", "Enter 10–3600 seconds. Changes apply immediately and are saved.")
        let input = NSTextField(string: String(Int(refreshIntervalSeconds)))
        input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: tr("保存", "Save"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        while alert.runModal() == .alertFirstButtonReturn {
            guard let seconds = Double(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  seconds.isFinite, seconds >= 10, seconds <= 3600 else {
                alert.informativeText = tr("请输入 10 到 3600 之间的秒数。", "Enter a value between 10 and 3600 seconds."); continue
            }
            UserDefaults.standard.set(seconds.rounded(), forKey: "refreshIntervalSeconds")
            scheduleRefresh()
            render()
            refresh()
            break
        }
    }
    @objc func refresh() {
        benefitClient.refresh()
        refreshQuota()
    }
    func refreshQuota() {
        guard !state.refreshing else { return }
        state.refreshing = true; render(); client.refresh()
    }
    func showPanel() { setExpanded(false); panel.orderFrontRegardless() }
    func savePosition() { UserDefaults.standard.set([capsuleOrigin.x, capsuleOrigin.y], forKey: "capsuleOrigin") }
    @objc func togglePanel() {
        hoverWork?.cancel()
        if panel.isVisible { panel.orderOut(nil); setExpanded(false) } else { showPanel() }
    }
    @objc func togglePinned() {
        state.pinned.toggle(); UserDefaults.standard.set(state.pinned, forKey: "pinned")
        panel.level = state.pinned ? .floating : .normal; render()
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = statusItem.button {
            menuOpen = true
            makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
            menuOpen = false; handleHover(panel.frame.contains(NSEvent.mouseLocation))
        } else { togglePanel() }
    }
    @objc func showMenu(_ sender: NSButton) {
        menuOpen = true; hoverWork?.cancel()
        makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        menuOpen = false; handleHover(panel.frame.contains(NSEvent.mouseLocation))
    }
    func addDisplayPreferences(to menu: NSMenu) {
        let language = NSMenuItem(title: tr("语言", "Language"), action: nil, keyEquivalent: "")
        let languages = NSMenu()
        for (code, title) in [("zh", "中文"), ("en", "English")] {
            let item = NSMenuItem(title: title, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = code
            item.state = (usesEnglish ? code == "en" : code == "zh") ? .on : .off
            languages.addItem(item)
        }
        language.submenu = languages; menu.addItem(language)
        let appearance = NSMenuItem(title: tr("外观", "Appearance"), action: nil, keyEquivalent: "")
        let appearances = NSMenu()
        let themeOptions: [(DisplayTheme, String)] = [
            (.system, tr("跟随系统", "System")),
            (.light, tr("浅色", "Light")),
            (.dark, tr("深色", "Dark"))
        ]
        for (theme, title) in themeOptions {
            let item = NSMenuItem(title: title, action: #selector(changeTheme(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = theme.rawValue
            item.state = displayTheme == theme ? .on : .off
            appearances.addItem(item)
        }
        appearance.submenu = appearances; menu.addItem(appearance)
        let zone = NSMenuItem(title: tr("时区", "Time zone") + " · " + displayTimeZone.identifier, action: nil, keyEquivalent: "")
        let zones = NSMenu()
        let system = NSMenuItem(title: tr("跟随系统", "System time zone"), action: #selector(changeTimeZone(_:)), keyEquivalent: "")
        system.target = self; system.representedObject = ""
        system.state = UserDefaults.standard.string(forKey: "displayTimeZone") == nil ? .on : .off
        zones.addItem(system)
        var groups: [String: NSMenu] = [:]
        for identifier in Set(TimeZone.knownTimeZoneIdentifiers + ["UTC"]).sorted() {
            let region = identifier.components(separatedBy: "/").first!
            if groups[region] == nil {
                let group = NSMenuItem(title: region, action: nil, keyEquivalent: "")
                let submenu = NSMenu(); group.submenu = submenu
                zones.addItem(group); groups[region] = submenu
            }
            let item = NSMenuItem(title: identifier, action: #selector(changeTimeZone(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = identifier
            item.state = UserDefaults.standard.string(forKey: "displayTimeZone") == identifier ? .on : .off
            groups[region]?.addItem(item)
        }
        zone.submenu = zones; menu.addItem(zone)
    }
    @objc func changeLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String, ["zh", "en"].contains(code) else { return }
        UserDefaults.standard.set(code, forKey: "displayLanguage")
        render()
    }
    @objc func changeTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let theme = DisplayTheme(rawValue: raw) else { return }
        UserDefaults.standard.set(theme.rawValue, forKey: "displayTheme")
        NSApp.appearance = configuredAppearance
        panel.appearance = configuredAppearance
        surface.appearance = configuredAppearance
        render()
    }
    @objc func changeTimeZone(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        if identifier.isEmpty { UserDefaults.standard.removeObject(forKey: "displayTimeZone") }
        else if TimeZone(identifier: identifier) != nil { UserDefaults.standard.set(identifier, forKey: "displayTimeZone") }
        render()
    }
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [(panel.isVisible ? tr("隐藏小窗", "Hide panel") : tr("显示小窗", "Show panel"), #selector(togglePanel)), (tr("立即刷新", "Refresh now"), #selector(refresh)), (tr("小窗始终置顶", "Always on top"), #selector(togglePinned))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if action == #selector(togglePinned) { item.state = state.pinned ? .on : .off }
            if action == #selector(refresh) { item.isEnabled = !state.refreshing }
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        menu.addItem(.separator())
        addDisplayPreferences(to: menu)
        let interval = NSMenuItem(title: tr("刷新间隔…", "Refresh interval…") + " (\(Int(refreshIntervalSeconds))s)", action: #selector(configureRefreshInterval), keyEquivalent: "")
        interval.target = self
        menu.addItem(interval)
        let hint = NSMenuItem(title: refreshIntervalLabel, action: nil, keyEquivalent: "")
        hint.isEnabled = false; menu.addItem(hint)
        let quitItem = NSMenuItem(title: tr("退出 Codex Quota", "Quit Codex Quota"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; menu.addItem(quitItem)
        return menu
    }
    func handleHover(_ inside: Bool) {
        hoverWork?.cancel()
        guard !dragging && !menuOpen else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.dragging, !self.menuOpen, self.panel.isVisible else { return }
            let stillInside = self.panel.frame.contains(NSEvent.mouseLocation)
            if inside && stillInside { self.setExpanded(true, animated: true) }
            if !inside && !stillInside { self.setExpanded(false, animated: true) }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.10 : 0.32), execute: work)
    }
    func targetFrame(expand: Bool) -> NSRect {
        let size = expand ? NSSize(width: 280, height: surface.card.contentHeight) : NSSize(width: 96, height: 34)
        let anchorRect = NSRect(origin: capsuleOrigin, size: NSSize(width: 96, height: 34))
        let area = (NSScreen.screens.first { $0.visibleFrame.intersects(anchorRect) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let layout = quotaFrame(origin: capsuleOrigin, expandedSize: size, area: area)
        surface.anchorRight = layout.anchorRight
        capsuleOrigin = layout.capsuleOrigin
        return layout.frame
    }
    func setExpanded(_ expand: Bool, animated: Bool = false) {
        let changed = expanded != expand
        expanded = expand
        let target = targetFrame(expand: expand)
        if !changed && panel.frame == target { return }
        transitionTimer?.invalidate()
        transitionTimer = nil
        surface.prepareImmediateLayout(expand: expand)
        let start = panel.frame
        let cardAlpha = surface.card.alphaValue
        let capsuleAlpha = surface.capsule.alphaValue
        let finish = { [weak self] in
            guard let self = self else { return }
            self.panel.setFrame(target, display: true)
            self.surface.card.alphaValue = expand ? 1 : 0
            self.surface.capsule.alphaValue = expand ? 0 : 1
            self.surface.finishImmediateLayout()
            if !self.smokeTest { self.savePosition() }
        }
        guard animated && !dragging && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finish(); return
        }
        let started = ProcessInfo.processInfo.systemUptime
        let duration = expand ? 0.52 : 0.42
        let itemAlphas = surface.card.subviews.map { $0.alphaValue }
        let itemTransforms = surface.card.subviews.map { $0.layer?.affineTransform() ?? .identity }
        for view in surface.card.subviews { view.wantsLayer = true }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let t = min(1, (ProcessInfo.processInfo.systemUptime - started) / duration)
            // Monotonic easing reaches the exact frame without overshoot, so
            // the left and right borders never rebound after expansion.
            let eased = 1 - pow(1 - t, 4)
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
            self.panel.setFrame(NSRect(x: mix(start.minX, target.minX), y: mix(start.minY, target.minY),
                                       width: mix(start.width, target.width), height: mix(start.height, target.height)), display: true)
            let fade = min(1, t * (expand ? 3 : 2.5))
            self.surface.card.alphaValue = cardAlpha + ((expand ? 1 : 0) - cardAlpha) * fade
            self.surface.capsule.alphaValue = capsuleAlpha + ((expand ? 0 : 1) - capsuleAlpha) * min(1, t * 4)
            for (index, view) in self.surface.card.subviews.enumerated() {
                let delay = min(0.28, Double(view.frame.minY / self.surface.card.contentHeight) * 0.28)
                let local = max(0, min(1, (t - delay) / (1 - delay)))
                let reveal = 1 - pow(1 - local, 3)
                let fromAlpha = cardAlpha < 0.01 ? 0 : itemAlphas[index]
                view.alphaValue = expand ? fromAlpha + (1 - fromAlpha) * reveal : itemAlphas[index] * (1 - reveal)
                let fromY = cardAlpha < 0.01 ? 16 : itemTransforms[index].ty
                let offset = expand ? fromY * (1 - reveal) : fromY - 10 * reveal
                view.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: offset))
            }
            if t >= 1 { timer.invalidate(); self.transitionTimer = nil; finish() }
        }
        transitionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func render() {
        guard !dragging else { return }
        statusItem.button?.title = state.menuTitle
        let details = state.windows.map { "\($0.name) " + tr("剩余", "remaining") + " \($0.remaining)%" }.joined(separator: " · ")
        let benefit = state.benefitReset.map { "\n" + tr("下次福利重置预测", "Next bonus reset (est.)") + ": \(benefitResetDateLabel($0)) (\(benefitResetStatus($0)))" } ?? ""
        let warning = state.error.map { usesEnglish ? "\nQuota unavailable. Please refresh." : "\n\($0)" } ?? ""
        statusItem.button?.toolTip = details + benefit + warning + "\n" + state.freshness + "\n" + displayTimeZone.identifier + "\n" + tr("左键：显示/隐藏小窗；右键：菜单", "Left click: show/hide panel; right click: menu")
        statusItem.button?.setAccessibilityLabel("Codex Quota: " + (details.isEmpty ? tr("暂无数据", "No data") : details))
        surface.update(state: state, target: self, refresh: #selector(refresh), pin: #selector(togglePinned), more: #selector(showMenu(_:)), hide: #selector(togglePanel))
        setExpanded(expanded)
    }
}

if let previewIndex = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.count > previewIndex + 1 {
    _ = NSApplication.shared
    try renderQuotaPreviews(to: URL(fileURLWithPath: CommandLine.arguments[previewIndex + 1]))
} else if CommandLine.arguments.contains("--self-test") {
    let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    var testArguments = originalArguments
    testArguments["displayLanguage"] = "zh"
    UserDefaults.standard.setVolatileDomain(testArguments, forName: UserDefaults.argumentDomain)
    func window(_ used: Double, _ minutes: Int) -> [String: Any] { ["usedPercent": used, "windowDurationMins": minutes, "resetsAt": 1789367143.0] }
    precondition(validatedRefreshInterval(0) == 60)
    precondition(validatedRefreshInterval(.nan) == 60)
    precondition(validatedRefreshInterval(9) == 60)
    precondition(validatedRefreshInterval(3601) == 60)
    precondition(validatedRefreshInterval(10) == 10)
    precondition(validatedRefreshInterval(3600) == 3600)
    let r = quotaWindows(["rateLimitsByLimitId": ["codex": ["primary": window(63, 10080), "secondary": NSNull()]]])
    precondition(r.count == 1 && r[0].remaining == 37 && r[0].name == "本周额度")
    precondition(quotaWindows([:]).isEmpty)
    precondition(QuotaWindow(window(150, 300))?.remaining == 0)
    precondition(QuotaWindow(window(-3, 300))?.remaining == 100)
    precondition(QuotaWindow(["windowDurationMins": 300]) == nil)
    let both = quotaWindows(["rateLimits": ["primary": window(8, 300), "secondary": window(63, 10080)]])
    precondition(both.count == 2 && both[0].remaining == 92)
    let now = Date(timeIntervalSince1970: 1000)
    precondition(resetCountdown(now.addingTimeInterval(65), now: now) == "2分钟后")
    precondition(resetCountdown(now.addingTimeInterval(-1), now: now) == tr("等待重置", "Awaiting reset"))
    precondition(resetCountdown(nil, now: now) == "")
    let predicted = parseBenefitReset("2026-09-08 10:30:00\n")!
    var shanghai = Calendar(identifier: .gregorian); shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let predictedParts = shanghai.dateComponents([.year, .month, .day, .hour, .minute, .second], from: predicted)
    precondition(predictedParts.year == 2026 && predictedParts.month == 9 && predictedParts.day == 8 && predictedParts.hour == 10 && predictedParts.minute == 30)
    precondition(parseBenefitReset("not-a-date") == nil)
    precondition(displayFormatter("yyyy-MM-dd HH:mm", zone: TimeZone(identifier: "UTC")!).string(from: predicted) == "2026-09-08 02:30")
    precondition(displayFormatter("yyyy-MM-dd HH:mm", zone: TimeZone(identifier: "America/Los_Angeles")!).string(from: predicted) == "2026-09-07 19:30")
    let winter = parseBenefitReset("2026-01-08 10:30:00")!
    precondition(displayFormatter("yyyy-MM-dd HH:mm", zone: TimeZone(identifier: "America/Los_Angeles")!).string(from: winter) == "2026-01-07 18:30")
    precondition(QuotaDisplayState(windows: both).menuTitle == "Codex 37%")
    precondition(QuotaDisplayState(windows: both, error: "离线").menuTitle == "Codex 37% ⚠︎")
    precondition(QuotaDisplayState(error: "离线").menuTitle == "Codex —")
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let left = quotaFrame(origin: NSPoint(x: 20, y: 830), expandedSize: NSSize(width: 280, height: 216), area: screen)
    precondition(!left.anchorRight && left.frame.minX == 20 && left.frame.maxY == 864)
    let right = quotaFrame(origin: NSPoint(x: 1324, y: 830), expandedSize: NSSize(width: 280, height: 216), area: screen)
    precondition(right.anchorRight && right.frame.maxX == 1420 && right.frame.maxY == 864)
    for origin in [NSPoint(x: -500, y: -200), NSPoint(x: 2000, y: 1200), NSPoint(x: 5, y: 1)] {
        let layout = quotaFrame(origin: origin, expandedSize: NSSize(width: 280, height: 338), area: screen)
        precondition(screen.contains(layout.frame), "Expanded panel must stay on screen")
        let compact = quotaFrame(origin: layout.capsuleOrigin, expandedSize: NSSize(width: 96, height: 34), area: screen)
        precondition(screen.contains(compact.frame) && compact.frame.maxY == layout.frame.maxY)
    }
    testArguments["displayLanguage"] = "en"
    testArguments["displayTimeZone"] = "UTC"
    UserDefaults.standard.setVolatileDomain(testArguments, forName: UserDefaults.argumentDomain)
    precondition(both[0].name == "5-hour")
    precondition(resetCountdown(now.addingTimeInterval(65), now: now) == "in 2m")
    precondition(benefitResetDateLabel(predicted) == "9/8 02:30")
    precondition(benefitResetStatus(now, now: now) == "Awaiting new forecast")
    testArguments["displayTheme"] = "light"
    UserDefaults.standard.setVolatileDomain(testArguments, forName: UserDefaults.argumentDomain)
    precondition(displayTheme == .light && configuredAppearance?.name == .aqua)
    testArguments["displayTheme"] = "dark"
    UserDefaults.standard.setVolatileDomain(testArguments, forName: UserDefaults.argumentDomain)
    precondition(displayTheme == .dark && configuredAppearance?.name == .darkAqua)
    testArguments["displayTheme"] = "invalid"
    UserDefaults.standard.setVolatileDomain(testArguments, forName: UserDefaults.argumentDomain)
    precondition(displayTheme == .system && configuredAppearance == nil)
    UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
    print("Passed: quotas, language, appearance modes, Beijing parsing, time zones, DST, countdowns and screen geometry.")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    if delegate.smokeTest && !delegate.resultSucceeded { exit(1) }
}
