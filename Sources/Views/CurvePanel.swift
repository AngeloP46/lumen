import SwiftUI

/// Point curve that fills the panel. Drag anywhere: the nearest point is picked up (or a new one is put on the curve
/// where you touched) and moves with your finger *relative* to where you started, so your finger never hides it and
/// small moves stay precise. The in → out values show while dragging. Double-tap a point to remove it.
struct CurvePanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var channel = 0
    @State private var drag: (index: Int, start: CurvePoint)?
    @State private var readout: CurvePoint?

    private static let channels: [(Int, String, Color)] = [(0, "RGB", .white), (1, "Red", .red), (2, "Green", .green), (3, "Blue", .blue)]

    private var channelColor: Color { Self.channels.first { $0.0 == channel }?.2 ?? .white }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Self.channels, id: \.0) { c, name, col in
                    Button { channel = c } label: {
                        HStack(spacing: 4) {
                            Circle().fill(col.opacity(0.9)).frame(width: 10, height: 10)
                            Text(name).font(.system(size: 12, weight: .semibold))
                            if !isNeutral(c) { Circle().fill(Theme.accent).frame(width: 5, height: 5) }
                        }
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(channel == c ? Theme.accent.opacity(0.28) : Theme.chip, in: Capsule())
                        .overlay(Capsule().stroke(channel == c ? Theme.accent : Color.clear, lineWidth: 1.5))
                        .foregroundStyle(channel == c ? Color.white : Color(white: 0.7))
                    }
                    .accessibilityIdentifier("curve-channel-\(name)")
                    .accessibilityAddTraits(channel == c ? .isSelected : [])
                }
                Spacer(minLength: 4)
                Menu {
                    Button("Medium contrast") { set([(0, 0), (0.25, 0.21), (0.75, 0.8), (1, 1)]) }
                    Button("Strong contrast") { set([(0, 0), (0.25, 0.17), (0.75, 0.85), (1, 1)]) }
                    Button("Fade (matte blacks)") { set([(0, 0.07), (0.5, 0.5), (1, 0.95)]) }
                    Button("Lift shadows") { set([(0, 0), (0.3, 0.38), (1, 1)]) }
                    Divider()
                    Button("Reset this channel") { vm.settings.curves.set(channel, ToneCurves.identity) }
                    Button("Reset all curves", role: .destructive) { vm.settings.curves = ToneCurves() }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 19)).frame(width: 34, height: 30)
                }
                .accessibilityIdentifier("curve-menu")
            }
            .padding(.horizontal, 12)

            GeometryReader { geo in
                let size = geo.size
                curveCanvas
                    .frame(width: size.width, height: size.height)
                    .background(Color.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                    .overlay(alignment: .topLeading) {
                        if let r = readout {
                            Text("In \(Int((r.x * 255).rounded()))  →  Out \(Int((r.y * 255).rounded()))")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.black.opacity(0.6), in: Capsule())
                                .padding(8)
                                .accessibilityIdentifier("curve-readout")
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if readout == nil {
                            Text("Drag to bend · double-tap a point to remove it")
                                .font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.45)).padding(6)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(dragGesture(size))
                    .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in removePoint(near: v.location, size) })
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("curve")
                    .accessibilityValue(vm.settings.curves.points(channel)
                        .map { String(format: "%.2f,%.2f", $0.x, $0.y) }.joined(separator: " "))
            }
            .frame(minHeight: 140)
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .padding(.top, 6)
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
                ctx.fill(p, with: .color(Color.white.opacity(0.12)))
            }
            for i in 1..<4 {
                let t = CGFloat(i) / 4
                var h = Path(); h.move(to: CGPoint(x: 0, y: size.height * t)); h.addLine(to: CGPoint(x: size.width, y: size.height * t))
                var v = Path(); v.move(to: CGPoint(x: size.width * t, y: 0)); v.addLine(to: CGPoint(x: size.width * t, y: size.height))
                ctx.stroke(h, with: .color(Color.white.opacity(0.13)), lineWidth: 0.5)
                ctx.stroke(v, with: .color(Color.white.opacity(0.13)), lineWidth: 0.5)
            }
            var diag = Path(); diag.move(to: CGPoint(x: 0, y: size.height)); diag.addLine(to: CGPoint(x: size.width, y: 0))
            ctx.stroke(diag, with: .color(Color.white.opacity(0.12)), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
            // the other channels' curves, faintly, so you can see what is already bent
            for (c, _, col) in Self.channels where c != channel && !isNeutral(c) {
                ctx.stroke(curvePath(vm.settings.curves.points(c), size), with: .color(col.opacity(0.3)), lineWidth: 1)
            }
            let pts = vm.settings.curves.points(channel)
            ctx.stroke(curvePath(pts, size), with: .color(channelColor), lineWidth: 2.2)
            for (i, p) in pts.enumerated() {
                let c = CGPoint(x: size.width * p.x, y: size.height * (1 - p.y))
                let r: CGFloat = drag?.index == i ? 10 : 7
                let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                ctx.fill(dot, with: .color(channelColor))
                ctx.stroke(dot, with: .color(.black.opacity(0.6)), lineWidth: 1.2)
            }
        }
    }

    private func curvePath(_ pts: [CurvePoint], _ size: CGSize) -> Path {
        let lut = ToneCurves.lut(for: pts, size: 96)
        var path = Path()
        for (i, y) in lut.enumerated() {
            let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(lut.count - 1), y: size.height * (1 - CGFloat(y)))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }

    private func nearest(_ pts: [CurvePoint], to loc: CGPoint, _ size: CGSize) -> (Int, CGFloat)? {
        var best: (Int, CGFloat)?
        for (i, p) in pts.enumerated() {
            let c = CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
            let d = hypot(c.x - loc.x, c.y - loc.y)
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best
    }

    private func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let w = max(size.width, 1), h = max(size.height, 1)
                var p = vm.settings.curves.points(channel)
                if drag == nil {
                    if let (i, d) = nearest(p, to: v.startLocation, size), d < 36 {
                        drag = (i, p[i])
                    } else {
                        // a new point goes *on* the curve where you touched, so nothing jumps
                        let x = min(max(Double(v.startLocation.x / w), 0.02), 0.98)
                        let lut = ToneCurves.lut(for: p, size: 256)
                        let y = Double(lut[min(max(Int((x * 255).rounded()), 0), 255)])
                        let np = CurvePoint(x: x, y: y)
                        p.append(np)
                        p.sort { $0.x < $1.x }
                        guard let i = p.firstIndex(of: np) else { return }
                        drag = (i, np)
                    }
                }
                guard let d = drag, d.index < p.count else { return }
                let i = d.index
                var np = CurvePoint(x: d.start.x + Double(v.translation.width / w),
                                    y: min(max(d.start.y - Double(v.translation.height / h), 0), 1))
                if i == 0 { np.x = 0 } else if i == p.count - 1 { np.x = 1 } else {
                    np.x = min(max(np.x, p[i - 1].x + 0.01), p[i + 1].x - 0.01)
                }
                p[i] = np
                readout = np
                vm.settings.curves.set(channel, p)
            }
            .onEnded { _ in drag = nil; readout = nil }
    }

    private func removePoint(near loc: CGPoint, _ size: CGSize) {
        var p = vm.settings.curves.points(channel)
        guard let (i, d) = nearest(p, to: loc, size), d < 36, i > 0, i < p.count - 1 else { return }
        p.remove(at: i)
        vm.settings.curves.set(channel, p)
    }
}
