import Foundation

/// Keeping the crop on real photo (Lightroom's Constrain to Image), done exactly (crop rework part 2, 25 Oct 2026).
///
/// The crop frame is stored as fractions of the *frame*: the picture after its 90° turns, before straighten, at full size.
/// Straighten and the perspective transform leave some of that frame empty. `region` is the part that still has photo: a
/// convex polygon in the same fractions. `fit` turns the frame the user asked for into the frame that is used: kept as it
/// is when it is all photo, else slid and only then shrunk (same shape) until it is. So a crop never loses more photo than
/// it must, and it grows back when the straighten angle is reduced. Foundation only: the logic tests cover it.
///
/// Before this (settings without `cropVersion`) the frame was a share of the largest same-shaped rectangle inside the
/// straightened picture, and Fill frame zoomed the perspective separately: the two zooms multiplied and a wide crop could
/// not reach the photo's corners. Those edits still render that way (`EditSession.geometry`) until the Crop tool opens them.
enum CropFit {
    typealias P = (x: Double, y: Double)

    /// The part of the frame that is photo, in frame fractions (0...1, y down), counter-clockwise.
    /// - source: the photo's size before anything; warp: where its corners go (TL, TR, BR, BL, fractions of the source,
    ///   y down) for a perspective transform, nil for none; then flips, `turns` quarter turns clockwise, and `straighten`
    ///   degrees clockwise, the order `EditSession.geometry` applies them.
    static func region(source: (w: Double, h: Double), turns: Int, flipH: Bool, flipV: Bool,
                       straighten: Double, warp: [P]?) -> [P] {
        guard source.w > 0, source.h > 0 else { return [] }
        let unit: [P] = [(0, 0), (1, 0), (1, 1), (0, 1)]
        // the transform's output is cut to the photo's own rectangle
        var poly = warp.map { clip(ordered($0), to: unit) } ?? unit
        // to centred pixels of the source
        poly = poly.map { ((($0.x - 0.5) * source.w), (($0.y - 0.5) * source.h)) }
        if flipH { poly = poly.map { (-$0.x, $0.y) } }
        if flipV { poly = poly.map { ($0.x, -$0.y) } }
        let k = ((turns % 4) + 4) % 4
        for _ in 0..<k { poly = poly.map { (-$0.y, $0.x) } }          // a quarter turn clockwise (y down)
        let frame = k % 2 == 0 ? source : (w: source.h, h: source.w)
        let a = straighten * .pi / 180, c = cos(a), s = sin(a)
        poly = poly.map { ($0.x * c - $0.y * s, $0.x * s + $0.y * c) }   // clockwise (y down)
        return ordered(poly.map { ($0.x / frame.w + 0.5, $0.y / frame.h + 0.5) })
    }

    /// The frame used for `desired` (fractions): itself when it is all photo; else the largest frame of its shape that is,
    /// as close to where it was asked for as possible. `margin` (fractions, x and y) keeps a fitted frame that far inside
    /// the photo's edge, so the soft edge of a turned or warped picture never shows.
    static func fit(_ desired: CropRect, in region: [P], margin: P = (0, 0)) -> CropRect {
        guard region.count >= 3, desired.w > 0, desired.h > 0 else { return desired }
        if contains(region, desired) { return desired }
        let inner = (margin.x > 0 || margin.y > 0) ? eroded(region, margin.x, margin.y) : region
        guard inner.count >= 3 else { return desired }
        let hw = desired.w / 2, hh = desired.h / 2
        var k = 1.0
        if eroded(inner, hw, hh).isEmpty {
            var lo = 0.0, hi = 1.0
            for _ in 0..<40 { let mid = (lo + hi) / 2; if eroded(inner, hw * mid, hh * mid).isEmpty { hi = mid } else { lo = mid } }
            k = lo
        }
        guard k > 1e-6 else { return desired }
        let room = eroded(inner, hw * k, hh * k)
        let c = nearest(in: room, to: ((desired.l + desired.r) / 2, (desired.t + desired.b) / 2))
        return CropRect(l: c.x - hw * k, t: c.y - hh * k, r: c.x + hw * k, b: c.y + hh * k)
    }

    /// From `inside` (all photo) towards `target`, as far as the frame stays all photo. A dragged handle stops at the
    /// photo's edge, a moved photo slides along it, a pinch stops zooming out.
    static func limit(from inside: CropRect, to target: CropRect, in region: [P]) -> CropRect {
        guard region.count >= 3, !contains(region, target) else { return target }
        guard contains(region, inside) else { return fit(target, in: region) }
        func lerp(_ t: Double) -> CropRect {
            CropRect(l: inside.l + (target.l - inside.l) * t, t: inside.t + (target.t - inside.t) * t,
                     r: inside.r + (target.r - inside.r) * t, b: inside.b + (target.b - inside.b) * t)
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<30 { let mid = (lo + hi) / 2; if contains(region, lerp(mid)) { lo = mid } else { hi = mid } }
        return lerp(lo)
    }

    /// Whether the frame is all photo (a tiny tolerance for rounding).
    static func contains(_ region: [P], _ r: CropRect, tolerance: Double = 1e-7) -> Bool {
        guard region.count >= 3 else { return true }
        let corners: [P] = [(r.l, r.t), (r.r, r.t), (r.r, r.b), (r.l, r.b)]
        return halfPlanes(region).allSatisfy { h in corners.allSatisfy { h.nx * $0.x + h.ny * $0.y <= h.d + tolerance } }
    }

    // MARK: Polygon helpers

    private struct HalfPlane { let nx: Double, ny: Double, d: Double }   // nx * x + ny * y <= d

    /// Counter-clockwise (in the maths sense of these coordinates), so every edge's outward normal is (ey, -ex).
    private static func ordered(_ p: [P]) -> [P] {
        var area = 0.0
        for i in p.indices { let a = p[i], b = p[(i + 1) % p.count]; area += a.x * b.y - b.x * a.y }
        return area < 0 ? p.reversed() : p
    }

    private static func halfPlanes(_ poly: [P]) -> [HalfPlane] {
        var out: [HalfPlane] = []
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let ex = b.x - a.x, ey = b.y - a.y, len = (ex * ex + ey * ey).squareRoot()
            guard len > 1e-12 else { continue }
            let nx = ey / len, ny = -ex / len
            out.append(HalfPlane(nx: nx, ny: ny, d: nx * a.x + ny * a.y))
        }
        return out
    }

    /// Sutherland-Hodgman: the part of `poly` on the inner side of `h`.
    private static func clip(_ poly: [P], _ h: HalfPlane) -> [P] {
        var out: [P] = []
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let fa = h.nx * a.x + h.ny * a.y - h.d, fb = h.nx * b.x + h.ny * b.y - h.d
            if fa <= 0 { out.append(a) }
            if (fa < 0 && fb > 0) || (fa > 0 && fb < 0) {
                let t = fa / (fa - fb)
                out.append((a.x + t * (b.x - a.x), a.y + t * (b.y - a.y)))
            }
        }
        return out
    }

    private static func clip(_ poly: [P], to convex: [P]) -> [P] {
        var out = poly
        for h in halfPlanes(ordered(convex)) { out = clip(out, h); if out.isEmpty { break } }
        return out
    }

    /// Where the centre of a frame of half-size (hw, hh) may go so the whole frame stays inside `poly` (empty if nowhere).
    static func eroded(_ poly: [P], _ hw: Double, _ hh: Double) -> [P] {
        var out: [P] = [(-1e3, -1e3), (1e3, -1e3), (1e3, 1e3), (-1e3, 1e3)]
        for h in halfPlanes(poly) {
            out = clip(out, HalfPlane(nx: h.nx, ny: h.ny, d: h.d - (abs(h.nx) * hw + abs(h.ny) * hh)))
            if out.count < 3 { return [] }
        }
        return out
    }

    /// The point of a convex polygon nearest to `p` (`p` itself when inside).
    private static func nearest(in poly: [P], to p: P) -> P {
        guard poly.count >= 3 else { return poly.first ?? p }
        if halfPlanes(poly).allSatisfy({ $0.nx * p.x + $0.ny * p.y <= $0.d + 1e-12 }) { return p }
        var best = poly[0], bestD = Double.infinity
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let ex = b.x - a.x, ey = b.y - a.y, l2 = ex * ex + ey * ey
            let t = l2 > 0 ? min(max(((p.x - a.x) * ex + (p.y - a.y) * ey) / l2, 0), 1) : 0
            let q: P = (a.x + t * ex, a.y + t * ey)
            let d = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
            if d < bestD { bestD = d; best = q }
        }
        return best
    }

    // MARK: Older edits

    /// The same frame for settings saved before this change: the old fractions were a share of the largest same-shaped
    /// rectangle inside the straightened picture (`kfit` of the frame), in a picture Fill frame had zoomed by `fillZoom`.
    static func upgraded(_ r: CropRect, frame: (w: Double, h: Double), straighten: Double, fillZoom: Double) -> CropRect {
        guard frame.w > 0, frame.h > 0 else { return r }
        let th = abs(straighten) * .pi / 180
        let kfit = 1 / (cos(th) + sin(th) * max(frame.w / frame.h, frame.h / frame.w))
        let k = kfit / max(fillZoom, 1e-6)
        guard abs(k - 1) > 1e-12 else { return r }   // no straighten or Fill frame zoom: the same numbers, exactly
        func f(_ v: Double) -> Double { 0.5 + (v - 0.5) * k }
        return CropRect(l: f(r.l), t: f(r.t), r: f(r.r), b: f(r.b))
    }
}
