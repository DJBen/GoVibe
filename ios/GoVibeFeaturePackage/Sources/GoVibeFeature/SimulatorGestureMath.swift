import CoreGraphics

enum SimulatorGestureMath {
    static func normalizedTranslation(_ translation: CGPoint, in bounds: CGRect) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let dim = min(bounds.width, bounds.height)
        return CGPoint(x: translation.x / dim, y: translation.y / dim)
    }

    static func normalizedDelta(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGPoint? {
        normalizedTranslation(CGPoint(x: end.x - start.x, y: end.y - start.y), in: bounds)
    }
}
