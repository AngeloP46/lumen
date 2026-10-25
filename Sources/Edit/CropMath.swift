import Foundation

/// The crop frame as fractions of the straightened picture (0...1, y down), and the moves a finger makes on it.
/// Foundation only, so the logic tests cover it. See docs/CROP-REWORK.md.
struct CropRect: Equatable {
    var l: Double, t: Double, r: Double, b: Double
    var w: Double { r - l }
    var h: Double { b - t }
    static let full = CropRect(l: 0, t: 0, r: 1, b: 1)
}

enum CropMath {
    /// The smallest side (fraction of the picture) the frame may have; the same limit `EditSession.geometry` applies.
    static let minSide = 0.04

    /// Moved by (dx, dy) in picture fractions, kept inside the picture. Size is unchanged.
    static func panned(_ r: CropRect, dx: Double, dy: Double) -> CropRect {
        let l = min(max(r.l + dx, 0), 1 - r.w), t = min(max(r.t + dy, 0), 1 - r.h)
        return CropRect(l: l, t: t, r: l + r.w, b: t + r.h)
    }

    /// Zoomed by `factor` (2 = the photo twice as big under the frame, so the frame covers half as much of it).
    /// `anchor` is the picture point (fractions) the fingers hold; `rel` is where that point sits inside the frame
    /// afterwards (0...1 across and down; it moves when the fingers move). The shape is kept, the size stays between
    /// the smallest frame and the whole picture, and the result stays inside the picture.
    static func zoomed(_ r: CropRect, factor: Double, anchor: (x: Double, y: Double), rel: (x: Double, y: Double)) -> CropRect {
        guard factor > 0, r.w > 0, r.h > 0 else { return r }
        var w = r.w / factor, h = r.h / factor
        let up = min(1 / w, 1 / h)                       // no bigger than the picture
        if up < 1 { w *= up; h *= up }
        let down = max(minSide / w, minSide / h)         // no smaller than the smallest frame
        if down > 1 { w *= down; h *= down }
        w = min(w, 1); h = min(h, 1)
        let l = min(max(anchor.x - rel.x * w, 0), 1 - w), t = min(max(anchor.y - rel.y * h, 0), 1 - h)
        return CropRect(l: l, t: t, r: l + w, b: t + h)
    }
}
