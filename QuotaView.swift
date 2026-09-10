import AppKit

func resetCountdown(_ reset: Date?, now: Date = Date()) -> String {
    guard let reset = reset else { return "" }
    let seconds = reset.timeIntervalSince(now)
    if seconds <= 0 { return tr("等待重置", "Awaiting reset") }
    let minutes = max(1, Int(ceil(seconds / 60)))
    if usesEnglish {
        if minutes >= 1440 { return "in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "in \(minutes / 60)h \(minutes % 60)m" }
        return "in \(minutes)m"
    }
    if minutes >= 1440 { return "\(minutes / 1440)天\((minutes % 1440) / 60)小时后" }
    if minutes >= 60 { return "\(minutes / 60)小时\(minutes % 60)分钟后" }
    return "\(minutes)分钟后"
}

func benefitResetDateLabel(_ date: Date) -> String {
    let format = displayFormatter("M/d HH:mm")
    return format.string(from: date)
}

func benefitResetStatus(_ date: Date, now: Date = Date()) -> String {
    date <= now ? tr("等待预测更新", "Awaiting new forecast") : resetCountdown(date, now: now)
}

func benefitConfidenceLabel(_ confidence: Double) -> String {
    String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), confidence)
}

func validatedRefreshInterval(_ value: Double) -> Double {
    value.isFinite && value >= 10 && value <= 3600 ? value : 60
}
var refreshIntervalSeconds: Double {
    validatedRefreshInterval(UserDefaults.standard.double(forKey: "refreshIntervalSeconds"))
}
var refreshIntervalLabel: String { tr("每 \(Int(refreshIntervalSeconds)) 秒自动刷新", "Refresh every \(Int(refreshIntervalSeconds))s") }

struct QuotaDisplayState {
    var windows: [QuotaWindow] = []
    var lastUpdated: Date?
    var error: String?
    var refreshing = false
    var pinned = true
    var benefitReset: Date?
    var benefitResetConfidence: Double?
    var benefitResetReason: String?
    var benefitResetLoading = false
    var benefitResetUnavailable = false
    var remaining: Int? { windows.map({ $0.remaining }).min() }
    var menuTitle: String {
        guard let remaining = remaining else { return refreshing ? "Codex ···" : "Codex —" }
        return "Codex \(remaining)%\(error == nil ? "" : " ⚠︎")"
    }
    var freshness: String {
        if refreshing { return tr("正在更新", "Updating") }
        guard let date = lastUpdated else { return refreshIntervalLabel }
        let format = displayFormatter("HH:mm:ss")
        return "\(statePrefix) \(format.string(from: date))"
    }
    private var statePrefix: String { error == nil ? tr("已更新", "Updated") : tr("上次更新", "Last update") }
}

private let primaryInk = NSColor.labelColor
private let secondaryInk = NSColor.secondaryLabelColor
private func quotaIsDark(_ appearance: NSAppearance = .currentDrawing()) -> Bool {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}
func quotaAccent(_ remaining: Int) -> NSColor {
    NSColor(name: nil) { appearance in
        let dark = quotaIsDark(appearance)
        if remaining <= 10 { return NSColor(srgbRed: dark ? 1.0 : 0.82, green: dark ? 0.49 : 0.22, blue: dark ? 0.48 : 0.20, alpha: 1) }
        if remaining <= 25 { return NSColor(srgbRed: dark ? 0.93 : 0.72, green: dark ? 0.74 : 0.43, blue: dark ? 0.44 : 0.10, alpha: 1) }
        return NSColor(srgbRed: dark ? 0.51 : 0.12, green: dark ? 0.83 : 0.48, blue: dark ? 0.73 : 0.37, alpha: 1)
    }
}

func drawQuotaSurface(_ bounds: NSRect, radius: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
    shape.addClip()
    let dark = quotaIsDark()
    let gradient = dark
        ? NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.135, blue: 0.15, alpha: 0.97), ending: NSColor(srgbRed: 0.065, green: 0.073, blue: 0.084, alpha: 0.97))!
        : NSGradient(starting: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.98), ending: NSColor(srgbRed: 0.91, green: 0.93, blue: 0.95, alpha: 0.98))!
    gradient.draw(in: bounds, angle: 90)
    (dark ? NSColor.white.withAlphaComponent(0.13) : NSColor.black.withAlphaComponent(0.12)).setStroke()
    let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
    edge.lineWidth = 1; edge.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

final class QuotaProgressView: NSView {
    let remaining: Int
    init(frame: NSRect, remaining: Int) { self.remaining = remaining; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        (quotaIsDark() ? NSColor.white.withAlphaComponent(0.09) : NSColor.black.withAlphaComponent(0.10)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        if remaining > 0 {
            let fill = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(remaining) / 100, height: bounds.height)
            quotaAccent(remaining).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
        }
    }
}

final class QuotaCapsuleView: NSView {
    let state: QuotaDisplayState
    var onDrag: ((NSEvent) -> Void)?
    init(state: QuotaDisplayState) {
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: 96, height: 34))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tr("Codex 剩余额度", "Codex remaining quota") + " " + (state.remaining.map { "\($0)%" } ?? "—"))
        toolTip = tr("悬停查看详情 · 拖动调整位置", "Hover for details · Drag to move")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onDrag?(event) }
    override func draw(_ dirtyRect: NSRect) {
        let ring = NSBezierPath(ovalIn: NSRect(x: 13, y: 10, width: 14, height: 14))
        ring.lineWidth = 2; (quotaIsDark() ? NSColor.white.withAlphaComponent(0.15) : NSColor.black.withAlphaComponent(0.16)).setStroke(); ring.stroke()
        if let remaining = state.remaining, remaining > 0 {
            let arc = NSBezierPath(); arc.lineWidth = 2; arc.lineCapStyle = .round
            arc.appendArc(withCenter: NSPoint(x: 20, y: 17), radius: 7, startAngle: 90, endAngle: 90 - CGFloat(remaining) * 3.6, clockwise: true)
            (state.error == nil ? quotaAccent(remaining) : quotaAccent(20)).setStroke(); arc.stroke()
        }
        let value = state.remaining.map { "\($0)%" } ?? (state.refreshing ? "···" : "—")
        let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: primaryInk]
        let size = (value as NSString).size(withAttributes: attributes)
        (value as NSString).draw(at: NSPoint(x: 36, y: (bounds.height - size.height) / 2 + 0.5), withAttributes: attributes)
        if state.error != nil {
            quotaAccent(20).setFill(); NSBezierPath(ovalIn: NSRect(x: 81, y: 15, width: 4, height: 4)).fill()
        }
    }
}

private final class QuotaIconButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit supplies hitTest points in the superview's coordinates.
        let localPoint = convert(point, from: superview)
        guard !isHidden, alphaValue > 0.01, bounds.contains(localPoint) else { return nil }
        return self
    }
}

final class QuotaCardView: NSView {
    override var isFlipped: Bool { true }
    let state: QuotaDisplayState
    let contentHeight: CGFloat
    private(set) var refreshButton: NSButton!
    private(set) var pinButton: NSButton!
    private(set) var moreButton: NSButton!
    private(set) var hideButton: NSButton!
    private(set) var reasonButton: NSButton?
    var onShowReason: ((NSButton) -> Void)?
    var onDrag: ((NSEvent) -> Void)?

    init(state: QuotaDisplayState, target: AnyObject?, refresh: Selector?, pin: Selector?, more: Selector?, hide: Selector?) {
        self.state = state
        let blockCount = max(1, state.windows.count)
        let errorHeight: CGFloat = state.error == nil ? 0 : 44
        let benefitHeight: CGFloat = 58
        contentHeight = 52 + CGFloat(blockCount) * 122 + errorHeight + benefitHeight + 44
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: contentHeight))
        setAccessibilityElement(false)
        let brand = text("CODEX", x: 20, y: 17, width: 110, size: 10, color: primaryInk, weight: .semibold)
        brand.attributedStringValue = NSAttributedString(string: "CODEX", attributes: [.font: brand.font!, .foregroundColor: primaryInk, .kern: 1.8])
        pinButton = icon("pin\(state.pinned ? ".fill" : "")", label: state.pinned ? tr("取消置顶", "Unpin") : tr("置顶小窗", "Pin panel"), x: 175, y: 10, target: target, action: pin)
        pinButton.contentTintColor = state.pinned ? quotaAccent(80) : secondaryInk
        moreButton = icon("ellipsis", label: tr("更多选项", "More options"), x: 207, y: 10, target: target, action: more)
        hideButton = icon("xmark", label: tr("隐藏小窗", "Hide panel"), x: 239, y: 10, target: target, action: hide)
        if state.windows.isEmpty {
            text(tr("账户剩余额度", "Remaining quota"), x: 20, y: 53, width: 240, size: 11, color: secondaryInk)
            text("—", x: 18, y: 73, width: 160, height: 50, size: 39, weight: .medium)
            text(state.refreshing ? tr("正在连接你的 Codex…", "Connecting to Codex…") : tr("暂无可用额度数据", "No quota data available"), x: 20, y: 142, width: 240, size: 11, color: secondaryInk)
        }
        let dateFormat = displayFormatter("M/d HH:mm")
        for (index, window) in state.windows.enumerated() {
            let y = 53 + CGFloat(index) * 122
            let name = window.name.replacingOccurrences(of: "额度", with: "")
            text(tr("\(name)剩余", "\(name) remaining"), x: 20, y: y, width: 170, size: 11, color: secondaryInk)
            let number = text("\(window.remaining)", x: 18, y: y + 17, width: 140, height: 49, size: 39, weight: .medium)
            number.font = .monospacedDigitSystemFont(ofSize: 39, weight: .medium)
            let numberWidth = (number.stringValue as NSString).size(withAttributes: [.font: number.font!]).width
            text("%", x: 21 + numberWidth, y: y + 36, width: 26, height: 26, size: 18, color: secondaryInk)
            let condition = state.error != nil ? tr("待更新", "Stale") : window.remaining == 0 ? tr("已用尽", "Used up") : window.remaining <= 10 ? tr("即将用尽", "Very low") : window.remaining <= 25 ? tr("额度偏低", "Low") : tr("可用", "Available")
            let badge = text(condition, x: 187, y: y + 38, width: 73, size: 10, color: state.error == nil ? quotaAccent(window.remaining) : secondaryInk)
            badge.alignment = .right
            let progress = QuotaProgressView(frame: NSRect(x: 20, y: y + 76, width: 240, height: 4), remaining: window.remaining)
            progress.setAccessibilityElement(true); progress.setAccessibilityLabel(tr("\(name)剩余百分比", "\(name) remaining percent")); progress.setAccessibilityValue("\(window.remaining)%")
            addSubview(progress)
            if let reset = window.reset {
                text(tr("\(dateFormat.string(from: reset)) 重置", "Resets \(dateFormat.string(from: reset))"), x: 20, y: y + 91, width: 137, size: 10, color: secondaryInk)
                let countdown = text(resetCountdown(reset), x: 157, y: y + 91, width: 103, size: 10, color: secondaryInk)
                countdown.alignment = .right
                countdown.toolTip = displayFormatter("yyyy-MM-dd HH:mm:ss zzz").string(from: reset)
            } else {
                text(tr("暂未提供重置时间", "Reset time unavailable"), x: 20, y: y + 91, width: 240, size: 10, color: secondaryInk)
            }
        }
        let errorY = 52 + CGFloat(blockCount) * 122
        if let error = state.error {
            let message = text(usesEnglish ? "Quota unavailable. Check your connection and Codex login, then refresh." : error, x: 20, y: errorY, width: 240, height: 39, size: 10, color: quotaAccent(20))
            message.maximumNumberOfLines = 2; message.lineBreakMode = .byWordWrapping; message.toolTip = message.stringValue
        }
        let benefitY = errorY + (state.error == nil ? 0 : 44)
        let benefitSeparator = NSBox(frame: NSRect(x: 20, y: benefitY, width: 240, height: 1)); benefitSeparator.boxType = .separator; addSubview(benefitSeparator)
        text(tr("下次福利重置（预测）", "Next bonus reset (est.)"), x: 20, y: benefitY + 10, width: 150, size: 10, color: secondaryInk, weight: .medium)
        if let reset = state.benefitReset {
            let date = text(benefitResetDateLabel(reset), x: 178, y: benefitY + 10, width: 82, size: 10, color: primaryInk)
            date.alignment = .right
            var reasonX: CGFloat = 20
            if let confidence = state.benefitResetConfidence {
                let label = text(tr("置信度", "Confidence") + "  " + benefitConfidenceLabel(confidence), x: 20, y: benefitY + 28, width: 94, size: 10, color: secondaryInk, weight: .medium)
                let width = ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width) + 4
                label.setFrameSize(NSSize(width: width, height: 18))
                reasonX = label.frame.maxX + 2
            }
            if state.benefitResetReason != nil {
                reasonButton = icon("eye", label: tr("查看预测理由", "View forecast reason"), x: reasonX, y: benefitY + 24, target: self, action: #selector(showReason(_:)))
                reasonButton?.setFrameSize(NSSize(width: 24, height: 24))
            }
            let hasDetails = state.benefitResetConfidence != nil || state.benefitResetReason != nil
            let status = text(benefitResetStatus(reset), x: hasDetails ? 144 : 20, y: benefitY + 28, width: hasDetails ? 116 : 240, size: 10, color: reset > Date() ? quotaAccent(80) : secondaryInk)
            status.alignment = .right
            status.toolTip = displayFormatter("yyyy-MM-dd HH:mm:ss zzz").string(from: reset) + " · " + displayTimeZone.identifier
        } else {
            let message = state.benefitResetLoading ? tr("正在获取预测…", "Loading forecast…") : state.benefitResetUnavailable ? tr("预测暂不可用", "Forecast unavailable") : tr("暂未提供预测", "No forecast available")
            text(message, x: 20, y: benefitY + 27, width: 240, size: 10, color: secondaryInk)
        }
        let footerY = benefitY + benefitHeight
        let separator = NSBox(frame: NSRect(x: 20, y: footerY, width: 240, height: 1)); separator.boxType = .separator; addSubview(separator)
        text(state.freshness, x: 20, y: footerY + 13, width: 202, size: 10, color: secondaryInk)
        refreshButton = icon("arrow.clockwise", label: tr("立即刷新", "Refresh now") + " · " + refreshIntervalLabel, x: 235, y: footerY + 6, target: target, action: refresh)
        refreshButton.isEnabled = !state.refreshing

    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func showReason(_ sender: NSButton) { onShowReason?(sender) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onDrag?(event) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard !isHidden, alphaValue > 0.01, bounds.contains(localPoint) else { return nil }
        if let button = button(at: localPoint) { return button }
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let candidate = view, candidate !== self {
            if let button = candidate as? NSButton { return button }
            view = candidate.superview
        }
        return self
    }
    func button(at point: NSPoint) -> NSButton? {
        guard !isHidden, alphaValue > 0.01 else { return nil }
        return subviews.reversed().compactMap { $0 as? NSButton }.first {
            !$0.isHidden && $0.alphaValue > 0.01 && $0.bounds.contains($0.convert(point, from: self))
        }
    }
    @discardableResult private func text(_ string: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 18, size: CGFloat, color: NSColor = primaryInk, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
        field.frame = NSRect(x: x, y: y, width: width, height: height)
        field.lineBreakMode = .byTruncatingTail
        addSubview(field)
        return field
    }
    private func icon(_ symbol: String, label: String, x: CGFloat, y: CGFloat, target: AnyObject?, action: Selector?) -> NSButton {
        let button = QuotaIconButton(frame: NSRect(x: x, y: y, width: 30, height: 30))
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        button.imagePosition = .imageOnly; button.isBordered = false
        button.contentTintColor = secondaryInk; button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = target; button.action = action
        addSubview(button)
        return button
    }
}

/// The complete reason stays selectable and scrollable, even for long forecasts.
final class ForecastReasonController: NSViewController {
    let reasonText = NSTextView()
    init(reason: String) {
        super.init(nibName: nil, bundle: nil)
        let width: CGFloat = 288
        let title = NSTextField(labelWithString: tr("预测理由", "Forecast reason"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.frame = NSRect(x: 18, y: 0, width: width - 36, height: 20)
        reasonText.isEditable = false
        reasonText.isSelectable = true
        reasonText.drawsBackground = false
        reasonText.font = .systemFont(ofSize: 12)
        reasonText.textColor = .labelColor
        reasonText.textContainerInset = .zero
        reasonText.textContainer?.lineFragmentPadding = 0
        reasonText.textContainer?.containerSize = NSSize(width: width - 48, height: .greatestFiniteMagnitude)
        reasonText.textContainer?.widthTracksTextView = false
        reasonText.string = reason
        reasonText.layoutManager?.ensureLayout(for: reasonText.textContainer!)
        let textHeight = ceil(reasonText.layoutManager!.usedRect(for: reasonText.textContainer!).height) + 4
        let visibleHeight = min(240, max(36, textHeight))
        let height = visibleHeight + 68
        view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        title.frame.origin.y = height - 38
        view.addSubview(title)
        let scroll = NSScrollView(frame: NSRect(x: 18, y: 18, width: width - 36, height: visibleHeight))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = textHeight > visibleHeight
        scroll.autohidesScrollers = true
        reasonText.frame = NSRect(x: 0, y: 0, width: width - 36, height: max(textHeight, visibleHeight))
        scroll.documentView = reasonText
        view.addSubview(scroll)
        preferredContentSize = view.frame.size
    }
    required init?(coder: NSCoder) { fatalError() }
}
