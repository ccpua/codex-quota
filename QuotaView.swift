import AppKit

func resetCountdown(_ reset: Date?, now: Date = Date()) -> String {
    guard let reset = reset else { return "" }
    let seconds = reset.timeIntervalSince(now)
    if seconds <= 0 { return "等待重置" }
    let minutes = max(1, Int(ceil(seconds / 60)))
    if minutes >= 1440 { return "\(minutes / 1440)天\((minutes % 1440) / 60)小时后" }
    if minutes >= 60 { return "\(minutes / 60)小时\(minutes % 60)分钟后" }
    return "\(minutes)分钟后"
}

func validatedRefreshInterval(_ value: Double) -> Double {
    value.isFinite && value >= 10 && value <= 3600 ? value : 60
}
var refreshIntervalSeconds: Double {
    validatedRefreshInterval(UserDefaults.standard.double(forKey: "refreshIntervalSeconds"))
}
var refreshIntervalLabel: String { "每 \(Int(refreshIntervalSeconds)) 秒自动刷新" }

struct QuotaDisplayState {
    var windows: [QuotaWindow] = []
    var lastUpdated: Date?
    var error: String?
    var refreshing = false
    var pinned = true
    var remaining: Int? { windows.map({ $0.remaining }).min() }
    var menuTitle: String {
        guard let remaining = remaining else { return refreshing ? "Codex ···" : "Codex —" }
        return "Codex \(remaining)%\(error == nil ? "" : " ⚠︎")"
    }
    var freshness: String {
        if refreshing { return "正在更新" }
        guard let date = lastUpdated else { return refreshIntervalLabel }
        let format = DateFormatter(); format.dateFormat = "HH:mm:ss"
        return "\(statePrefix) \(format.string(from: date))"
    }
    private var statePrefix: String { error == nil ? "已更新" : "上次更新" }
}

private let primaryInk = NSColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1)
private let secondaryInk = NSColor(srgbRed: 0.62, green: 0.65, blue: 0.69, alpha: 1)
func quotaAccent(_ remaining: Int) -> NSColor {
    if remaining <= 10 { return NSColor(srgbRed: 1.0, green: 0.49, blue: 0.48, alpha: 1) }
    if remaining <= 25 { return NSColor(srgbRed: 0.93, green: 0.74, blue: 0.44, alpha: 1) }
    return NSColor(srgbRed: 0.51, green: 0.83, blue: 0.73, alpha: 1)
}

func drawQuotaSurface(_ bounds: NSRect, radius: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
    shape.addClip()
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.135, blue: 0.15, alpha: 0.97), ending: NSColor(srgbRed: 0.065, green: 0.073, blue: 0.084, alpha: 0.97))!
    gradient.draw(in: bounds, angle: 90)
    NSColor.white.withAlphaComponent(0.13).setStroke()
    let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
    edge.lineWidth = 1; edge.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

final class QuotaProgressView: NSView {
    let remaining: Int
    init(frame: NSRect, remaining: Int) { self.remaining = remaining; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.09).setFill()
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
        setAccessibilityLabel("Codex 剩余额度 \(state.remaining.map { "\($0)%" } ?? "暂无数据")；悬停展开详情")
        toolTip = "悬停查看详情 · 拖动调整位置"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onDrag?(event) }
    override func draw(_ dirtyRect: NSRect) {
        let ring = NSBezierPath(ovalIn: NSRect(x: 13, y: 10, width: 14, height: 14))
        ring.lineWidth = 2; NSColor.white.withAlphaComponent(0.15).setStroke(); ring.stroke()
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
    var onDrag: ((NSEvent) -> Void)?

    init(state: QuotaDisplayState, target: AnyObject?, refresh: Selector?, pin: Selector?, more: Selector?, hide: Selector?) {
        self.state = state
        let blockCount = max(1, state.windows.count)
        contentHeight = 52 + CGFloat(blockCount) * 122 + (state.error == nil ? 0 : 44) + 68
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: contentHeight))
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityElement(false)
        let brand = text("CODEX", x: 20, y: 17, width: 110, size: 10, color: primaryInk, weight: .semibold)
        brand.attributedStringValue = NSAttributedString(string: "CODEX", attributes: [.font: brand.font!, .foregroundColor: primaryInk, .kern: 1.8])
        pinButton = icon("pin\(state.pinned ? ".fill" : "")", label: state.pinned ? "取消置顶" : "置顶小窗", x: 175, y: 10, target: target, action: pin)
        pinButton.contentTintColor = state.pinned ? quotaAccent(80) : secondaryInk
        moreButton = icon("ellipsis", label: "更多选项", x: 207, y: 10, target: target, action: more)
        hideButton = icon("xmark", label: "隐藏小窗", x: 239, y: 10, target: target, action: hide)
        if state.windows.isEmpty {
            text("账户剩余额度", x: 20, y: 53, width: 240, size: 11, color: secondaryInk)
            text("—", x: 18, y: 73, width: 160, height: 50, size: 39, weight: .medium)
            text(state.refreshing ? "正在连接你的 Codex…" : "暂无可用额度数据", x: 20, y: 142, width: 240, size: 11, color: secondaryInk)
        }
        let dateFormat = DateFormatter(); dateFormat.dateFormat = "M/d HH:mm"
        for (index, window) in state.windows.enumerated() {
            let y = 53 + CGFloat(index) * 122
            let name = window.name.replacingOccurrences(of: "额度", with: "")
            text("\(name)剩余", x: 20, y: y, width: 170, size: 11, color: secondaryInk)
            let number = text("\(window.remaining)", x: 18, y: y + 17, width: 140, height: 49, size: 39, weight: .medium)
            number.font = .monospacedDigitSystemFont(ofSize: 39, weight: .medium)
            let numberWidth = (number.stringValue as NSString).size(withAttributes: [.font: number.font!]).width
            text("%", x: 21 + numberWidth, y: y + 36, width: 26, height: 26, size: 18, color: secondaryInk)
            let condition = state.error != nil ? "待更新" : window.remaining == 0 ? "已用尽" : window.remaining <= 10 ? "即将用尽" : window.remaining <= 25 ? "额度偏低" : "可用"
            let badge = text(condition, x: 187, y: y + 38, width: 73, size: 10, color: state.error == nil ? quotaAccent(window.remaining) : secondaryInk)
            badge.alignment = .right
            let progress = QuotaProgressView(frame: NSRect(x: 20, y: y + 76, width: 240, height: 4), remaining: window.remaining)
            progress.setAccessibilityElement(true); progress.setAccessibilityLabel("\(name)剩余百分比"); progress.setAccessibilityValue("\(window.remaining)%")
            addSubview(progress)
            if let reset = window.reset {
                text("\(dateFormat.string(from: reset)) 重置", x: 20, y: y + 91, width: 137, size: 10, color: secondaryInk)
                let countdown = text(resetCountdown(reset), x: 157, y: y + 91, width: 103, size: 10, color: secondaryInk)
                countdown.alignment = .right
                countdown.toolTip = "\(resetCountdown(reset))重置，以服务器更新时间为准"
            } else {
                text("暂未提供重置时间", x: 20, y: y + 91, width: 240, size: 10, color: secondaryInk)
            }
        }
        let errorY = 52 + CGFloat(blockCount) * 122
        if let error = state.error {
            let message = text(error, x: 20, y: errorY, width: 240, height: 39, size: 10, color: quotaAccent(20))
            message.maximumNumberOfLines = 2; message.lineBreakMode = .byWordWrapping; message.toolTip = error
        }
        let footerY = contentHeight - 68
        let separator = NSBox(frame: NSRect(x: 20, y: footerY, width: 240, height: 1)); separator.boxType = .separator; addSubview(separator)
        text(state.freshness, x: 20, y: footerY + 13, width: 202, size: 10, color: secondaryInk)
        refreshButton = icon("arrow.clockwise", label: "立即刷新（\(refreshIntervalLabel)）", x: 235, y: footerY + 6, target: target, action: refresh)
        refreshButton.isEnabled = !state.refreshing
        let signature = NSButton(title: UserDefaults.standard.string(forKey: "signatureTitle") ?? "bistar.ai ↗",
                                 target: target, action: Selector(("openSignature")))
        signature.frame = NSRect(x: 20, y: footerY + 39, width: 240, height: 20)
        signature.isBordered = false
        signature.alignment = .left
        signature.font = .systemFont(ofSize: 10, weight: .medium)
        signature.contentTintColor = quotaAccent(80)
        signature.toolTip = UserDefaults.standard.string(forKey: "signatureURL") ?? "https://bistar.ai"
        addSubview(signature)

    }
    required init?(coder: NSCoder) { fatalError() }
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
