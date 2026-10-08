import SwiftUI

struct CurvePanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var channel = 0
    @State private var dragIndex: Int?
    private let side: CGFloat = 170

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
                .background(Color.black.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .gesture(dragGesture)
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in removePoint(near: v.location) })
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach([(0, "RGB"), (1, "R"), (2, "G"), (3, "B")], id: \.0) { c, name in
                        Chip(title: name, selected: channel == c) { channel = c }
                    }
                }
                Button { vm.settings.curves.set(channel, ToneCurves.identity) } label: {
                    Label("Reset curve", systemImage: "arrow.counterclockwise").font(.caption)
                }
                .buttonStyle(.bordered)
                Text("Drag to bend. Double-tap a point to remove it.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
    }

    private var curveCanvas: some View {
        Canvas { ctx, size in
            for i in 1..<4 {
                let t = CGFloat(i) / 4
                var h = Path(); h.move(to: CGPoint(x: 0, y: size.height * t)); h.addLine(to: CGPoint(x: size.width, y: size.height * t))
                var v = Path(); v.move(to: CGPoint(x: size.width * t, y: 0)); v.addLine(to: CGPoint(x: size.width * t, y: size.height))
                ctx.stroke(h, with: .color(Color.white.opacity(0.15)), lineWidth: 0.5)
                ctx.stroke(v, with: .color(Color.white.opacity(0.15)), lineWidth: 0.5)
            }
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
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(channelColor))
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
