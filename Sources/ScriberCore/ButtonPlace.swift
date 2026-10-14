import CoreGraphics

/// Where the writer dragged the field button, kept so it comes back to the same spot. Across: from the field's nearer
/// side, so it follows a chat box that's centred in a resizing window. Up and down: from the window's nearer edge,
/// because web text fields report their height and position loosely (Claude's box moves its field when an image is
/// attached or the text wraps) while the window holds still.
public struct ButtonPlace: Codable, Equatable, Sendable {
    public var fromRight: Bool
    public var dx: Double
    public var fromTop: Bool
    public var dy: Double

    public init(fromRight: Bool, dx: Double, fromTop: Bool, dy: Double) {
        self.fromRight = fromRight
        self.dx = dx
        self.fromTop = fromTop
        self.dy = dy
    }

    /// The place for a button of side `size` dropped with its origin at `origin` (AppKit screen coordinates).
    public init(dropped origin: CGPoint, size: CGFloat, field: CGRect, window: CGRect?) {
        let center = CGPoint(x: origin.x + size / 2, y: origin.y + size / 2)
        let rows = window ?? field
        fromRight = center.x > field.midX
        dx = Double(origin.x - (fromRight ? field.maxX : field.minX))
        fromTop = center.y > rows.midY
        dy = Double(origin.y - (fromTop ? rows.maxY : rows.minY))
    }

    /// The button's origin for this field and window.
    public func origin(field: CGRect, window: CGRect?) -> CGPoint {
        let rows = window ?? field
        return CGPoint(x: (fromRight ? field.maxX : field.minX) + CGFloat(dx),
                       y: (fromTop ? rows.maxY : rows.minY) + CGFloat(dy))
    }
}
