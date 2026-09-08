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
        for (name, state) in states {
            let view = HoverSurface(frame: NSRect(x: 0, y: 0, width: 280, height: 216))
            view.expanded = true
            view.update(state: state, target: nil, refresh: nil, pin: nil, more: nil, hide: nil)
            view.setFrameSize(NSSize(width: 280, height: view.card.contentHeight))
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
    print("Rendered \(checked) previews; bounds, single-line text widths and refresh-button states passed.")
}
