import Foundation

func quotaFrame(origin: NSPoint, expandedSize: NSSize, area: NSRect) -> (frame: NSRect, capsuleOrigin: NSPoint, anchorRight: Bool) {
    let anchorRight = origin.x + 48 >= area.midX
    var frame = NSRect(x: anchorRight ? origin.x + 96 - expandedSize.width : origin.x,
                       y: origin.y + 34 - expandedSize.height,
                       width: expandedSize.width, height: expandedSize.height)
    frame.origin.x = min(max(frame.minX, area.minX), area.maxX - expandedSize.width)
    frame.origin.y = min(max(frame.minY, area.minY), area.maxY - expandedSize.height)
    return (frame, NSPoint(x: anchorRight ? frame.maxX - 96 : frame.minX, y: frame.maxY - 34), anchorRight)
}
