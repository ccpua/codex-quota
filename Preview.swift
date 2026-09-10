import AppKit

func renderQuotaPreviews(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let now = Date()
    func window(_ used: Double, minutes: Int = 10080, reset: TimeInterval = 86400 * 3 + 3600 * 4) -> QuotaWindow {
        QuotaWindow(["usedPercent": used, "windowDurationMins": minutes, "resetsAt": now.addingTimeInterval(reset).timeIntervalSince1970])!
    }
    let states: [(String, QuotaDisplayState)] = [
        ("normal", QuotaDisplayState(windows: [window(64)], lastUpdated: now)),
        ("dual", QuotaDisplayState(windows: [window(13, minutes: 300, reset: 3600 * 2), window(76)], lastUpdated: now)),
        ("low", QuotaDisplayState(windows: [window(94)], lastUpdated: now)),
        ("empty", QuotaDisplayState(windows: [window(100, reset: -10)], lastUpdated: now)),
        ("full", QuotaDisplayState(windows: [window(0)], lastUpdated: now)),
        ("loading", QuotaDisplayState(refreshing: true)),
        ("offline", QuotaDisplayState(windows: [window(64)], lastUpdated: now.addingTimeInterval(-180), error: "查询超时，保留上次数据；稍后自动重试。")),
        ("login", QuotaDisplayState(error: "请在 Codex 中登录后，再点刷新。")),
        ("refreshing", QuotaDisplayState(windows: [window(64)], lastUpdated: now, refreshing: true))
    ]
    var checked = 0
    for theme in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = NSAppearance(named: theme)!
        for (name, baseState) in states {
            var state = baseState
            state.benefitReset = now.addingTimeInterval(86400 * 6 + 3600 * 20)
            state.benefitResetConfidence = 0.29
            state.benefitResetReason = usesEnglish ? "No official notice; estimated from recent reset intervals and capacity pressure." : "无明确预告；基于近期重置间隔、窄范围补发及容量压力推测。"
            let view = HoverSurface(frame: NSRect(x: 0, y: 0, width: 280, height: 216))
            view.expanded = true
            view.update(state: state, target: nil, refresh: nil, pin: nil, more: nil, hide: nil)
            view.setFrameSize(NSSize(width: 280, height: view.card.contentHeight))
            let host = NSView(frame: view.frame)
            host.addSubview(view)
            view.appearance = appearance
            view.layoutSubtreeIfNeeded()
            for subview in view.card.subviews {
                precondition(view.bounds.contains(subview.frame), "Out of bounds: \(name), \(subview)")
                if let field = subview as? NSTextField, field.maximumNumberOfLines != 2 {
                    let textWidth = (field.stringValue as NSString).size(withAttributes: [.font: field.font!]).width
                    precondition(textWidth <= field.frame.width - 2, "Text clipped: \(name), \(field.stringValue), \(textWidth) > \(field.frame.width)")
                }
            }
            precondition(view.card.refreshButton.isEnabled != state.refreshing)
            let eye = view.card.reasonButton!
            for point in [NSPoint(x: 1, y: 1), NSPoint(x: 12, y: 12), NSPoint(x: 23, y: 23)] {
                precondition(view.card.button(at: eye.convert(point, to: view.card)) === eye, "Eye button must capture its full area")
                precondition(view.hitTest(eye.convert(point, to: host)) === eye, "Eye button must not start dragging")
            }
            var opened = false
            view.card.onShowReason = { _ in opened = true }
            eye.performClick(nil)
            precondition(opened, "Eye click must open the reason")
            precondition(!view.card.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(state.benefitResetReason!) }, "Reason must stay hidden on the card")
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * 2, pixelsHigh: Int(view.bounds.height) * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = view.bounds.size
            appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
            let data = rep.representation(using: .png, properties: [:])!
            let filename = "\(theme == .aqua ? "light" : "dark")-\(name).png"
            try data.write(to: directory.appendingPathComponent(filename))
            checked += 1
            view.expanded = false
            view.update(state: state, target: nil, refresh: nil, pin: nil, more: nil, hide: nil)
            view.setFrameSize(NSSize(width: 96, height: 34))
            view.layoutSubtreeIfNeeded()
            let compact = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 192, pixelsHigh: 68, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            compact.size = view.bounds.size
            appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: compact) }
            try compact.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("capsule-" + filename))
            checked += 1
        }
    }
    let longReason = String(repeating: "A detailed forecast reason. 预测理由详情。\n", count: 100)
    let reasonController = ForecastReasonController(reason: longReason)
    precondition(reasonController.reasonText.string == longReason)
    precondition(reasonController.preferredContentSize.height <= 308)
    precondition(reasonController.reasonText.enclosingScrollView?.hasVerticalScroller == true)
    print("Rendered \(checked) previews; bounds, single-line text widths and refresh-button states passed.")
}
