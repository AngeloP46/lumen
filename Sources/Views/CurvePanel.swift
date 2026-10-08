import SwiftUI

struct CurvePanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var channel = 0
    @State private var dragIndex: Int?
    private let side: CGFloat = 196

    private var channelColor: Color {
        switch channel {
        case 1: return .red
        case 2: return .green
        case 3: return .blue
        default: return .white
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            curveCanvas
                .frame(width: side, height: side)
                .background(Color.black.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                .gesture(dragGesture)
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in removePoint(near: v.location) })
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach([(0, Color.white), (1, Color.red), (2, Color.green), (3, Color.blue)], id: \.0) { c, col in
                        Button { channel = c } label: {
                            ZStack {
                                Circle().fill(col.opacity(0.9)).frame(width: 24, height: 24)
                                if !isNeutral(c) { Circle().fill(Color.black.opacity(0.55)).frame(width: 7, height: 7) }
                            }
                            .padding(4)
                            .overlay(Circle().stroke(channel == c ? Theme.accent : Color.clear, lineWidth: 2))
                        }
                    }
                }
                Text("Presets").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Chip(title: "Contrast") { set([(0, 0), (0.25, 0.19), (0.75, 0.82), (1, 1)]) }
                    Chip(title: "Fade") { set([(0, 0.07), (0.5, 0.5), (1, 0.95)]) }
                }
                HStack(spacing: 6) {
                    Chip(title: "Lift") { set([(0, 0), (0.3, 0.38), (1, 1)]) }
                    Chip(title: "Reset channel") { vm.settings.curves.set(channel, ToneCurves.identity) }
                }
                Chip(title: "Reset all curves") { vm.settings.curves = ToneCurves() }
                Text("Drag to bend the curve. Double-tap a point to remove it.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.top, 8)
    }

    private func isNeutral(_ c: Int) -> Bool { vm.settings.curves.points(c) == ToneCurves.identity }

    private func set(_ pts: [(Double, Double)]) {
        vm.settings.curves.set(channel, pts.map { CurvePoint(x: $0.0, y: $0.1) })
    }

    private var curveCanvas: some View {
        Canvas { ctx, size in
            if let h = vm.histogram?.luma {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in h.enumerated() {
                    p.addLine(to: CGPoint(x: size.width * CGFloat(i) / CGFloat(h.count - 1), y: size.height * (1 - CGFloat(v) * 0.8)))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                ctx.fill(p, with: .color(Color.white.opacity(0.14)))
            }
            for i in 1..<4 {
                let t = CGFloat(i) / 4
                var h = Path(); h.move(to: CGPoint(x: 0, y: size.height * t)); h.addLine(to: CGPoint(x: size.width, y: size.height * t))
                var v = Path(); v.move(to: CGPoint(x: size.width * t, y: 0)); v.addLine(to: CGPoint(x: size.width * t, y: size.height))
                ctx.stroke(h, with: .color(Color.white.opacity(0.13)), lineWidth: 0.5)
                ctx.stroke(v, with: .color(Color.white.opacity(0.13)), lineWidth: 0.5)
            }
            var diag = Path(); diag.move(to: CGPoint(x: 0, y: size.height)); diag.addLine(to: CGPoint(x: size.width, y: 0))
            ctx.stroke(diag, with: .color(Color.white.opacity(0.1)), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
            let pts = vm.settings.curves.points(channel)
            let lut = ToneCurves.lut(for: pts, size: 64)
            var curve = Path()
            for (i, y) in lut.enumerated() {
                let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(lut.count - 1),
                                 y: size.height * (1 - CGFloat(y)))
                if i == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
            }
            ctx.stroke(curve, with: .color(channelColor), lineWidth: 2)
            for p in pts {
                let c = CGPoint(x: size.width * p.x, y: size.height * (1 - p.y))
                let dot = Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12))
                ctx.fill(dot, with: .color(channelColor))
                ctx.stroke(dot, with: .color(.black.opacity(0.5)), lineWidth: 1)
            }
        }
    }

    private func clamp01(_ v: CGFloat) -> Double { Double(min(max(v, 0), 1)) }

    private func nearest(_ pts: [CurvePoint], to loc: CGPoint) -> (Int, CGFloat)? {
        var best: (Int, CGFloat)?
        for (i, p) in pts.enumerated() {
            let c = CGPoint(x: p.x * side, y: (1 - p.y) * side)
            let d = hypot(c.x - loc.x, c.y - loc.y)
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                var p = vm.settings.curves.points(channel)
                if dragIndex == nil {
                    if let (i, d) = nearest(p, to: v.startLocation), d < 28 {
                        dragIndex = i
                    } else {
                        let np = CurvePoint(x: clamp01(v.startLocation.x / side), y: clamp01(1 - v.startLocation.y / side))
                        p.append(np)
                        p.sort { $0.x < $1.x }
                        dragIndex = p.firstIndex(of: np)
                    }
                }
                guard let i = dragIndex, i < p.count else { return }
                let nx = clamp01(v.location.x / side)
                let ny = clamp01(1 - v.location.y / side)
                var np = CurvePoint(x: nx, y: ny)
                if i == 0 {
                    np.x = 0
                } else if i == p.count - 1 {
                    np.x = 1
                } else {
                    np.x = min(max(nx, p[i - 1].x + 0.01), p[i + 1].x - 0.01)
                }
                p[i] = np
                vm.settings.curves.set(channel, p)
            }
            .onEnded { _ in dragIndex = nil }
    }

    private func removePoint(near loc: CGPoint) {
        var p = vm.settings.curves.points(channel)
        guard let (i, d) = nearest(p, to: loc), d < 28, i > 0, i < p.count - 1 else { return }
        p.remove(at: i)
        vm.settings.curves.set(channel, p)
    }
}
