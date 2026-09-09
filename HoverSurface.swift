import AppKit
import QuartzCore

final class HoverSurface: NSView {
    override var isFlipped: Bool { true }
    var onHover: ((Bool) -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var anchorRight = true { didSet { needsLayout = true } }
    var expanded = false
    var card: QuotaCardView!
    var capsule: QuotaCapsuleView!
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = true; layer?.cornerRadius = 17
        autoresizingMask = [.width, .height]
        layerContentsRedrawPolicy = .duringViewResize
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        card?.needsDisplay = true
        capsule?.needsDisplay = true
        card?.subviews.forEach { $0.needsDisplay = true }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) { drawQuotaSurface(bounds, radius: min(20, bounds.height / 2)) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let candidate = view, candidate !== self {
            if candidate is NSButton { return candidate }
            view = candidate.superview
        }
        return self
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) {
        beginDrag(with: event)
    }
    private func beginDrag(with event: NSEvent) {
        // Never start window dragging from a control, even if an event reaches
        // this fallback through another view during a transition.
        if let card = card,
           let button = card.button(at: card.convert(event.locationInWindow, from: nil)) {
            if button.isEnabled { button.mouseDown(with: event) }
            return
        }
        onDragStart?()
        guard let window = window else { onDragEnd?(); return }
        let start = NSEvent.mouseLocation
        let origin = window.frame.origin
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let current = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: origin.x + current.x - start.x,
                                          y: origin.y + current.y - start.y))
        }
        onDragEnd?()
    }
    override func rightMouseDown(with event: NSEvent) { onHover?(true) }
    override func layout() {
        super.layout()
        if let card = card { card.setFrameOrigin(NSPoint(x: anchorRight ? bounds.width - card.frame.width : 0, y: 0)) }
        if let capsule = capsule { capsule.setFrameOrigin(NSPoint(x: anchorRight ? bounds.width - 96 : 0, y: 0)) }
        needsDisplay = true
    }
    func update(state: QuotaDisplayState, target: AnyObject?, refresh: Selector?, pin: Selector?, more: Selector?, hide: Selector?) {
        card?.removeFromSuperview(); capsule?.removeFromSuperview()
        card = QuotaCardView(state: state, target: target, refresh: refresh, pin: pin, more: more, hide: hide)
        capsule = QuotaCapsuleView(state: state)
        card.onDrag = { [weak self] event in self?.beginDrag(with: event) }
        capsule.onDrag = { [weak self] event in self?.beginDrag(with: event) }
        card.wantsLayer = true; capsule.wantsLayer = true
        card.alphaValue = expanded ? 1 : 0
        capsule.alphaValue = expanded ? 0 : 1
        card.isHidden = !expanded
        capsule.isHidden = expanded
        addSubview(card); addSubview(capsule)
        needsLayout = true
    }
    func prepareImmediateLayout(expand: Bool) {
        expanded = expand
        card.isHidden = false; capsule.isHidden = false
        layer?.cornerRadius = expand ? 20 : 17
    }
    func finishImmediateLayout() {
        card.isHidden = !expanded; capsule.isHidden = expanded
        for view in card.subviews {
            view.alphaValue = 1
            view.layer?.setAffineTransform(.identity)
        }
        needsDisplay = true
        needsLayout = true
    }
}
