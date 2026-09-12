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
    String(format: "%.0f%%", locale: Locale(identifier: "en_US_POSIX"), confidence * 100)
}

func appVersionLabel(_ version: String) -> String {
    version.hasPrefix("v") ? version : "v\(version)"
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
    var planType: String?
    var lastUpdated: Date?
    var error: String?
    var refreshing = false
    var pinned = true
    var benefitReset: Date?
    var benefitResetConfidence: Double?
    var benefitResetReason: String?
    var benefitResetLoading = false
    var benefitResetUnavailable = false
    var availableVersion: String?
    var checkingForUpdate = false
    var installingUpdate = false
    var codeActivity: CodeActivitySnapshot?
    var codeActivityError: String?
    var remaining: Int? { windows.map({ $0.remaining }).min() }
    var menuTitle: String {
        let update = availableVersion == nil ? "" : " ↑"
        guard let remaining = remaining else { return (refreshing ? "Codex ···" : "Codex —") + update }
        return "Codex \(remaining)%\(error == nil ? "" : " ⚠︎")" + update
    }
    var freshness: String {
        if refreshing { return tr("正在更新", "Updating") }
        guard let date = lastUpdated else { return refreshIntervalLabel }
        let format = displayFormatter("HH:mm:ss")
        return "\(statePrefix) \(format.string(from: date))"
    }
    private var statePrefix: String { error == nil ? tr("已更新", "Updated") : tr("上次更新", "Last update") }
}

func membershipPlanLabel(_ plan: String?) -> String {
    guard let plan else { return "—" }
    switch plan {
    case "free": return "Free"
    case "go": return "Go"
    case "plus": return "Plus"
    case "pro": return "Pro"
    case "team": return "Team"
    case "business": return "Business"
    case "enterprise": return "Enterprise"
    case "edu": return "Edu"
    default: return plan.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private final class MembershipBadge: NSView {
    let title: String
    let available: Bool
    private let font = NSFont.systemFont(ofSize: 9, weight: .semibold)

    init(plan: String?) {
        title = membershipPlanLabel(plan)
        available = plan != nil
        let width = min(84, max(32, ceil((title as NSString).size(withAttributes: [.font: font]).width) + 16))
        super.init(frame: NSRect(x: 82, y: 14, width: width, height: 20))
        toolTip = tr("会员计划", "Membership plan") + " · " + (available ? title : tr("暂未获取", "Unavailable"))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(toolTip)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let color = available ? quotaAccent(80) : NSColor.secondaryLabelColor
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        color.withAlphaComponent(0.10).setFill(); shape.fill()
        color.withAlphaComponent(0.20).setStroke(); shape.lineWidth = 0.5; shape.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        let height = (title as NSString).size(withAttributes: [.font: font]).height
        (title as NSString).draw(in: NSRect(x: 6, y: (bounds.height - height) / 2, width: bounds.width - 12, height: height), withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
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

private final class CodeActivityMetricView: NSView {
    private let title: String
    private let value: Int?
    private let accent: NSColor
    private let mark: String

    override var isFlipped: Bool { true }

    init(frame: NSRect, title: String, value: Int?, accent: NSColor, mark: String, status: String?) {
        self.title = title
        self.value = value
        self.accent = accent
        self.mark = mark
        super.init(frame: frame)
        let exactValue = value.map(String.init) ?? "—"
        toolTip = [title + " " + exactValue, status].compactMap { $0 }.joined(separator: " · ")
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
        setAccessibilityValue(exactValue)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let dark = quotaIsDark()
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        card.addClip()
        let top = accent.withAlphaComponent(dark ? 0.20 : 0.13)
        let bottom = accent.withAlphaComponent(dark ? 0.055 : 0.025)
        NSGradient(starting: top, ending: bottom)!.draw(in: bounds, angle: 90)

        // A soft oversized glow gives each metric a distinct visual identity.
        let glowRect = NSRect(x: bounds.maxX - 29, y: -19, width: 46, height: 46)
        let glow = NSBezierPath(ovalIn: glowRect)
        accent.withAlphaComponent(dark ? 0.10 : 0.07).setFill(); glow.fill()

        let highlight = NSBezierPath()
        highlight.move(to: NSPoint(x: 10, y: 1))
        highlight.line(to: NSPoint(x: bounds.width - 10, y: 1))
        highlight.lineWidth = 1; highlight.lineCapStyle = .round
        accent.withAlphaComponent(dark ? 0.32 : 0.22).setStroke(); highlight.stroke()
        NSGraphicsContext.restoreGraphicsState()

        accent.withAlphaComponent(dark ? 0.40 : 0.30).setStroke()
        card.lineWidth = 0.8; card.stroke()

        let markFont = NSFont.systemFont(ofSize: 10, weight: .bold)
        (mark as NSString).draw(at: NSPoint(x: 8, y: 7), withAttributes: [.font: markFont, .foregroundColor: accent])
        let titleFont = NSFont.systemFont(ofSize: 8.5, weight: .medium)
        (title as NSString).draw(at: NSPoint(x: 23, y: 8), withAttributes: [.font: titleFont, .foregroundColor: secondaryInk])

        let number = value.map(codeActivityNumber) ?? "—"
        let fontSize: CGFloat = number.count >= 5 ? 15 : 19
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .left
        (number as NSString).draw(in: NSRect(x: 8, y: 27, width: bounds.width - 13, height: 24), withAttributes: [
            .font: numberFont,
            .foregroundColor: value == nil ? secondaryInk : accent,
            .paragraphStyle: paragraph
        ])
    }
}

private func codeActivityNumber(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 100_000 { return String(format: "%.0fK", Double(value) / 1000) }
    return String(value)
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

private class QuotaIconButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit supplies hitTest points in the superview's coordinates.
        let localPoint = convert(point, from: superview)
        guard !isHidden, alphaValue > 0.01, bounds.contains(localPoint) else { return nil }
        return self
    }
}

/// A small lens that comes alive on interaction, without a permanent idle timer.
private final class ForecastEyeButton: QuotaIconButton {
    private var tracking: NSTrackingArea?
    private var animationTimer: Timer?
    private var hovering = false
    private var hoverStarted = Date.timeIntervalSinceReferenceDate
    private var clickedAt: TimeInterval?
    private var glow: CGFloat = 0
    private var lastFrame = Date.timeIntervalSinceReferenceDate

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        toolTip = tr("查看预测理由", "View forecast reason")
        setAccessibilityLabel(toolTip)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { animationTimer?.invalidate() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        hoverStarted = Date.timeIntervalSinceReferenceDate
        animate()
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        animate()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            animationTimer?.invalidate(); animationTimer = nil
            hovering = false; glow = 0; clickedAt = nil
        }
    }
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        clickedAt = Date.timeIntervalSinceReferenceDate
        animate()
        return super.sendAction(action, to: target)
    }
    private func animate() {
        needsDisplay = true
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            glow = hovering ? 1 : 0
            clickedAt = nil
            animationTimer?.invalidate(); animationTimer = nil
            return
        }
        guard animationTimer == nil else { return }
        lastFrame = Date.timeIntervalSinceReferenceDate
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }
    private func tick() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { animate(); return }
        let now = Date.timeIntervalSinceReferenceDate
        let step = CGFloat(min(now - lastFrame, 0.1)) / 0.18
        lastFrame = now
        glow = hovering ? min(1, glow + step) : max(0, glow - step)
        if let clickedAt, now - clickedAt > 0.65 { self.clickedAt = nil }
        needsDisplay = true
        if !hovering && glow == 0 && clickedAt == nil {
            animationTimer?.invalidate(); animationTimer = nil
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let now = Date.timeIntervalSinceReferenceDate
        let elapsed = reduced ? 0 : now - hoverStarted
        let dark = quotaIsDark()
        let accent = quotaAccent(80)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let disc = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        accent.withAlphaComponent((dark ? 0.09 : 0.07) + glow * 0.10).setFill()
        disc.fill()
        accent.withAlphaComponent(0.20 + glow * 0.20).setStroke()
        disc.lineWidth = 0.65; disc.stroke()

        if glow > 0 && !reduced {
            let orbit = NSBezierPath()
            orbit.appendArc(withCenter: center, radius: 10, startAngle: CGFloat(elapsed * 150), endAngle: CGFloat(elapsed * 150 + 100))
            orbit.lineWidth = 1; orbit.lineCapStyle = .round
            accent.withAlphaComponent(glow * 0.85).setStroke(); orbit.stroke()
        }
        // Draw the eye as two curves, gently closing the lid once per hover cycle.
        let phase = elapsed.truncatingRemainder(dividingBy: 3.4)
        let blink = hovering && !reduced ? max(0, 1 - abs(phase - 0.45) / 0.12) : 0
        let opening = CGFloat(1 - blink * 0.92)
        let pressed: CGFloat = isHighlighted ? 0.90 : 1
        let halfWidth: CGFloat = 6.4 * pressed
        let lid: CGFloat = 5.1 * opening * pressed
        let eye = NSBezierPath()
        let left = NSPoint(x: center.x - halfWidth, y: center.y)
        let right = NSPoint(x: center.x + halfWidth, y: center.y)
        eye.move(to: left)
        eye.curve(to: right, controlPoint1: NSPoint(x: center.x - 2.8, y: center.y + lid), controlPoint2: NSPoint(x: center.x + 2.8, y: center.y + lid))
        eye.curve(to: left, controlPoint1: NSPoint(x: center.x + 2.8, y: center.y - lid), controlPoint2: NSPoint(x: center.x - 2.8, y: center.y - lid))
        eye.lineWidth = 1.15; eye.lineJoinStyle = .round
        accent.withAlphaComponent(0.85 + glow * 0.15).setStroke(); eye.stroke()
        let gaze = hovering && !reduced ? CGFloat(sin(elapsed * 2.2)) * 0.8 * glow : 0
        NSGraphicsContext.saveGraphicsState()
        eye.addClip()
        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 2 + gaze, y: center.y - 2, width: 4, height: 4)).fill()
        NSColor.white.withAlphaComponent(dark ? 0.9 : 0.8).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 0.6 + gaze, y: center.y + 0.3, width: 1.2, height: 1.2)).fill()
        NSGraphicsContext.restoreGraphicsState()

        if let clickedAt, !reduced {
            let progress = CGFloat(min(1, (now - clickedAt) / 0.65))
            let radius = 5 + progress * 6.5
            let pulse = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            accent.withAlphaComponent((1 - progress) * 0.8).setStroke()
            pulse.lineWidth = 1.2 * (1 - progress) + 0.3; pulse.stroke()
        }
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
    private(set) var updateButton: NSButton?
    var onShowReason: ((NSButton) -> Void)?
    var onDrag: ((NSEvent) -> Void)?

    init(state: QuotaDisplayState, target: AnyObject?, refresh: Selector?, pin: Selector?, more: Selector?, hide: Selector?, update: Selector? = nil) {
        self.state = state
        let blockCount = max(1, state.windows.count)
        let errorHeight: CGFloat = state.error == nil ? 0 : 44
        // The 18pt label frames include bottom font padding; center the visible
        // glyphs between the separators rather than centering those frames.
        let benefitHeight: CGFloat = 60
        let updateHeight: CGFloat = state.availableVersion == nil ? 0 : 26
        let codeHeight: CGFloat = 96
        contentHeight = 52 + CGFloat(blockCount) * 122 + errorHeight + benefitHeight + codeHeight + updateHeight + 44
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: contentHeight))
        setAccessibilityElement(false)
        let brand = text("CODEX", x: 20, y: 17, width: 60, size: 10, color: primaryInk, weight: .semibold)
        brand.attributedStringValue = NSAttributedString(string: "CODEX", attributes: [.font: brand.font!, .foregroundColor: primaryInk, .kern: 1.8])
        addSubview(MembershipBadge(plan: state.planType))
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
        // Center the visible two-line text block, allowing for NSTextField's font insets.
        let predictionTitleY = benefitY + 13
        let predictionDetailsY = predictionTitleY + 21
        let benefitSeparator = NSBox(frame: NSRect(x: 20, y: benefitY, width: 240, height: 1)); benefitSeparator.boxType = .separator; addSubview(benefitSeparator)
        text(tr("下次福利重置（预测）", "Next bonus reset (est.)"), x: 20, y: predictionTitleY, width: 150, size: 10, color: secondaryInk, weight: .medium)
        if let reset = state.benefitReset {
            let date = text(benefitResetDateLabel(reset), x: 178, y: predictionTitleY, width: 82, size: 10, color: primaryInk)
            date.alignment = .right
            var reasonX: CGFloat = 20
            if let confidence = state.benefitResetConfidence {
                let label = text(tr("置信度", "Confidence") + "  " + benefitConfidenceLabel(confidence), x: 20, y: predictionDetailsY, width: 94, size: 10, color: secondaryInk, weight: .medium)
                let width = ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width) + 4
                label.setFrameSize(NSSize(width: width, height: 18))
                reasonX = label.frame.maxX + 2
            }
            if state.benefitResetReason != nil {
                let eye = ForecastEyeButton(frame: NSRect(x: reasonX, y: predictionDetailsY - 6, width: 24, height: 24))
                eye.target = self; eye.action = #selector(showReason(_:))
                addSubview(eye)
                reasonButton = eye
            }
            let hasDetails = state.benefitResetConfidence != nil || state.benefitResetReason != nil
            let status = text(benefitResetStatus(reset), x: hasDetails ? 144 : 20, y: predictionDetailsY, width: hasDetails ? 116 : 240, size: 10, color: reset > Date() ? quotaAccent(80) : secondaryInk)
            status.alignment = .right
            status.toolTip = displayFormatter("yyyy-MM-dd HH:mm:ss zzz").string(from: reset) + " · " + displayTimeZone.identifier
        } else {
            let message = state.benefitResetLoading ? tr("正在获取预测…", "Loading forecast…") : state.benefitResetUnavailable ? tr("预测暂不可用", "Forecast unavailable") : tr("暂未提供预测", "No forecast available")
            text(message, x: 20, y: predictionDetailsY, width: 240, size: 10, color: secondaryInk)
        }
        let codeY = benefitY + benefitHeight
        let codeSeparator = NSBox(frame: NSRect(x: 20, y: codeY, width: 240, height: 1))
        codeSeparator.boxType = .separator; addSubview(codeSeparator)
        text(tr("今日代码变更", "Today's code changes"), x: 20, y: codeY + 10, width: 240, size: 11, weight: .medium)
        let codeCounts = state.codeActivity?.total
        let status: String?
        if state.codeActivityError != nil { status = tr("刷新失败，显示上次结果", "Refresh failed; showing the previous result") }
        else if state.codeActivity?.incomplete == true { status = tr("部分目录不可用", "Some directories are unavailable") }
        else { status = nil }
        let green = NSColor(name: nil) { quotaIsDark($0) ? NSColor(srgbRed: 0.35, green: 0.92, blue: 0.76, alpha: 1) : NSColor(srgbRed: 0.05, green: 0.56, blue: 0.42, alpha: 1) }
        let orange = NSColor(name: nil) { quotaIsDark($0) ? NSColor(srgbRed: 1.0, green: 0.62, blue: 0.27, alpha: 1) : NSColor(srgbRed: 0.90, green: 0.39, blue: 0.04, alpha: 1) }
        let red = NSColor(name: nil) { quotaIsDark($0) ? NSColor(srgbRed: 1.0, green: 0.34, blue: 0.40, alpha: 1) : NSColor(srgbRed: 0.86, green: 0.13, blue: 0.20, alpha: 1) }
        let values: [(String, Int?, NSColor, String)] = [
            (tr("新增", "Added"), codeCounts?.added, green, "+"),
            (tr("修改", "Edited"), codeCounts?.modified, orange, "✦"),
            (tr("删除", "Deleted"), codeCounts?.deleted, red, "−")
        ]
        for (index, value) in values.enumerated() {
            let card = CodeActivityMetricView(frame: NSRect(x: 20 + CGFloat(index) * 85, y: codeY + 32, width: 70, height: 56), title: value.0, value: value.1, accent: value.2, mark: value.3, status: status)
            addSubview(card)
        }
        let footerY = codeY + codeHeight
        let separator = NSBox(frame: NSRect(x: 20, y: footerY, width: 240, height: 1)); separator.boxType = .separator; addSubview(separator)
        text(state.freshness, x: 20, y: footerY + 13, width: 202, size: 10, color: secondaryInk)
        refreshButton = icon("arrow.clockwise", label: tr("立即刷新", "Refresh now") + " · " + refreshIntervalLabel, x: 235, y: footerY + 6, target: target, action: refresh)
        refreshButton.isEnabled = !state.refreshing

        let updateY = footerY + 36
        if let version = state.availableVersion {
            let displayVersion = appVersionLabel(version)
            let title = tr("发现新版本 \(displayVersion)", "Update \(displayVersion) available")
            let label = text(title, x: 0, y: updateY + 3, width: 200, size: 10, color: quotaAccent(80), weight: .semibold)
            let labelWidth = ceil((title as NSString).size(withAttributes: [.font: label.font!]).width) + 10
            label.frame = NSRect(x: 20, y: updateY + 3, width: labelWidth, height: 18)
            // Match the visible text center, excluding the label's bottom font padding.
            // Overlap only the label's trailing padding so the visible icon sits
            // close to the version while retaining its full 24pt hit area.
            updateButton = icon("arrow.down.circle.fill", label: tr("点击下载并安装更新", "Download and install the update"), x: label.frame.maxX - 8, y: label.frame.minY - 6, target: target, action: update)
            updateButton?.setFrameSize(NSSize(width: 24, height: 24))
            updateButton?.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            updateButton?.contentTintColor = quotaAccent(80)
            updateButton?.isEnabled = !state.installingUpdate
        }

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
