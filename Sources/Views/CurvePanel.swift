import SwiftUI

/// Point curve that fills the panel. Drag anywhere: the nearest point is picked up (or a new one is put on the curve
/// where you touched) and moves with your finger *relative* to where you started, so your finger never hides it and
/// small moves stay precise. The in → out values show while dragging. Double-tap a point to remove it.
/// Since 25 Oct (owner, from Darkroom and Photomator): the plot sits inside a margin so the end points are whole, the
/// zones are named along the top, an untouched curve shows five points evenly along the line (saved only once one is
/// moved; a curve dragged back onto the line counts as untouched again), and points are rings, filled while held.
struct CurvePanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var channel = 0
    @State private var drag: (index: Int, start: CurvePoint)?
    @State private var readout: CurvePoint?
    /// Press and hold a point (owner, 25 Oct): after a moment a "Remove point" button shows over it. Two steps, so a
    /// finger resting on a point before dragging it never deletes it.
    @State private var removeAsk: Int?
    @State private var holdTimer: DispatchWorkItem?
    @State private var pressMoved = false

    private static let channels: [(Int, String, Color)] = [(0, "RGB", .white), (1, "Red", .red), (2, "Green", .green), (3, "Blue", .blue)]
    /// What an untouched channel shows: blacks, shadows, midtones, highlights, whites, on the line.
    private static let starter: [CurvePoint] = [0, 0.25, 0.5, 0.75, 1].map { CurvePoint(x: $0, y: $0) }
    private static let zones: [(Double, String)] = [(0, "Blacks"), (0.25, "Shadows"), (0.5, "Midtones"), (0.75, "Highlights"), (1, "Whites")]
    /// Room round the plot so a point at a corner is drawn whole, and a band above it for the zone names.
    private static let pad: CGFloat = 14
    private static let labelBand: CGFloat = 28   // tall enough that a point at the top corner clears the names

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
                PillButton(title: "Reset", system: "arrow.counterclockwise") { vm.settings.curves = ToneCurves() }
                    .opacity(vm.settings.curves == ToneCurves() ? 0.45 : 1)
                    .disabled(vm.settings.curves == ToneCurves())
                    .accessibilityIdentifier("curve-reset")
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
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                    .overlay(alignment: .top) {
                        if let r = readout {
                            Text("In \(Int((r.x * 255).rounded()))  →  Out \(Int((r.y * 255).rounded()))")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.black.opacity(0.7), in: Capsule())
                                .padding(.top, Self.pad + Self.labelBand + 4)
                                .accessibilityIdentifier("curve-readout")
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if readout == nil {
                            Text("Drag to bend · double-tap a point to remove it")
                                .font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.4))
                                .padding(.trailing, Self.pad + 4).padding(.bottom, Self.pad + 2)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        if let i = removeAsk, i < shown(channel).count {
                            let c = Self.place(shown(channel)[i], Self.plot(size))
                            Button {
                                removeAt(i)
                            } label: {
                                Label("Remove point", systemImage: "trash")
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Color(white: 0.18), in: Capsule())
                                    .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                                    .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.4))
                            }
                            .position(x: min(max(c.x, 70), size.width - 70), y: c.y > 60 ? c.y - 32 : c.y + 32)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                            .accessibilityIdentifier("curve-remove-point")
                        }
                    }
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: removeAsk)
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

    /// On the line (any number of points): renders as no curve at all.
    private static func onLine(_ p: [CurvePoint]) -> Bool { p.allSatisfy { abs($0.y - $0.x) < 1e-4 } }
    private func isNeutral(_ c: Int) -> Bool { Self.onLine(vm.settings.curves.points(c)) }
    /// The points the panel shows and drags: the saved ones, or the five starters on an untouched channel.
    private func shown(_ c: Int) -> [CurvePoint] {
        let p = vm.settings.curves.points(c)
        return Self.onLine(p) ? Self.starter : p
    }

    private func set(_ pts: [(Double, Double)]) {
        vm.settings.curves.set(channel, pts.map { CurvePoint(x: $0.0, y: $0.1) })
    }

    private static func plot(_ size: CGSize) -> CGRect {
        CGRect(x: pad, y: pad + labelBand, width: max(size.width - 2 * pad, 1), height: max(size.height - 2 * pad - labelBand, 1))
    }

    private static func place(_ p: CurvePoint, _ r: CGRect) -> CGPoint {
        CGPoint(x: r.minX + r.width * p.x, y: r.minY + r.height * (1 - p.y))
    }

    private var curveCanvas: some View {
        Canvas { ctx, size in
            let r = Self.plot(size)
            if let h = vm.histogram?.luma {
                var p = Path()
                p.move(to: CGPoint(x: r.minX, y: r.maxY))
                for (i, v) in h.enumerated() {
                    p.addLine(to: CGPoint(x: r.minX + r.width * CGFloat(i) / CGFloat(h.count - 1), y: r.maxY - r.height * CGFloat(v) * 0.8))
                }
                p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                ctx.fill(p, with: .color(Color.white.opacity(0.12)))
            }
            // the zones: a line under each name, and the quarters across
            for (x, name) in Self.zones {
                let px = r.minX + r.width * x
                var v = Path(); v.move(to: CGPoint(x: px, y: r.minY)); v.addLine(to: CGPoint(x: px, y: r.maxY))
                ctx.stroke(v, with: .color(Color.white.opacity(x == 0 || x == 1 ? 0.18 : 0.13)), lineWidth: 0.5)
                let anchor: UnitPoint = x == 0 ? .leading : (x == 1 ? .trailing : .center)
                ctx.draw(Text(name).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.white.opacity(0.45)),
                         at: CGPoint(x: px, y: Self.pad + Self.labelBand / 2 - 2), anchor: anchor)
            }
            for i in 1..<4 {
                let y = r.minY + r.height * CGFloat(i) / 4
                var h = Path(); h.move(to: CGPoint(x: r.minX, y: y)); h.addLine(to: CGPoint(x: r.maxX, y: y))
                ctx.stroke(h, with: .color(Color.white.opacity(0.13)), lineWidth: 0.5)
            }
            var diag = Path(); diag.move(to: CGPoint(x: r.minX, y: r.maxY)); diag.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            ctx.stroke(diag, with: .color(Color.white.opacity(0.14)), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
            // the other channels' curves, faintly, so you can see what is already bent
            for (c, _, col) in Self.channels where c != channel && !isNeutral(c) {
                ctx.stroke(curvePath(vm.settings.curves.points(c), r), with: .color(col.opacity(0.3)), lineWidth: 1)
            }
            let pts = shown(channel)
            ctx.stroke(curvePath(pts, r), with: .color(channelColor), lineWidth: 2.2)
            // points: rings (Darkroom), the one held is bigger with a dot in it
            for (i, p) in pts.enumerated() {
                let c = Self.place(p, r)
                let held = drag?.index == i
                let rad: CGFloat = held ? 11 : 8.5
                let ring = Path(ellipseIn: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
                ctx.fill(ring, with: .color(Color.black.opacity(0.8)))
                ctx.stroke(ring, with: .color(channelColor), lineWidth: 2)
                if held {
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)), with: .color(channelColor))
                }
            }
        }
    }

    private func curvePath(_ pts: [CurvePoint], _ r: CGRect) -> Path {
        let lut = ToneCurves.lut(for: pts, size: 96)
        var path = Path()
        for (i, y) in lut.enumerated() {
            let pt = CGPoint(x: r.minX + r.width * CGFloat(i) / CGFloat(lut.count - 1), y: r.minY + r.height * (1 - CGFloat(y)))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }

    private func nearest(_ pts: [CurvePoint], to loc: CGPoint, _ size: CGSize) -> (Int, CGFloat)? {
        let r = Self.plot(size)
        var best: (Int, CGFloat)?
        for (i, p) in pts.enumerated() {
            let c = Self.place(p, r)
            let d = hypot(c.x - loc.x, c.y - loc.y)
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best
    }

    private func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let r = Self.plot(size)
                let w = r.width, h = r.height
                var p = shown(channel)
                if drag == nil {
                    removeAsk = nil
                    pressMoved = false
                    if let (i, d) = nearest(p, to: v.startLocation, size), d < 36 {
                        drag = (i, p[i])
                        // held still on a point that can go (not an end, not an untouched curve's starter): offer Remove
                        if i > 0 && i < p.count - 1 && !isNeutral(channel) {
                            holdTimer?.cancel()
                            let work = DispatchWorkItem {
                                guard drag?.index == i, !pressMoved else { return }
                                removeAsk = i
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            }
                            holdTimer = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                        }
                    } else {
                        // a new point goes *on* the curve where you touched, so nothing jumps
                        let x = min(max(Double((v.startLocation.x - r.minX) / w), 0.02), 0.98)
                        let lut = ToneCurves.lut(for: p, size: 256)
                        let y = Double(lut[min(max(Int((x * 255).rounded()), 0), 255)])
                        let np = CurvePoint(x: x, y: y)
                        p.append(np)
                        p.sort { $0.x < $1.x }
                        guard let i = p.firstIndex(of: np) else { return }
                        drag = (i, np)
                        pressMoved = true                   // a new point follows the finger at once
                        vm.settings.curves.set(channel, p)  // and is there for the next step of the drag
                    }
                }
                guard let d = drag, d.index < p.count else { return }
                // a finger still resting on the point (waiting for Remove) does not move it
                if !pressMoved {
                    guard hypot(v.translation.width, v.translation.height) > 4 else { return }
                    pressMoved = true
                    holdTimer?.cancel()
                    removeAsk = nil
                }
                let i = d.index
                let tx = Double(v.translation.width / w), ty = Double(v.translation.height / h)
                var np = CurvePoint(x: d.start.x + tx, y: min(max(d.start.y - ty, 0), 1))
                if i == 0 { np.x = 0 } else if i == p.count - 1 { np.x = 1 } else {
                    np.x = min(max(np.x, p[i - 1].x + 0.01), p[i + 1].x - 0.01)
                }
                p[i] = np
                // held at an edge or a neighbour: moving back responds at once (no overshoot kept, as with EndStop)
                if i > 0 && i < p.count - 1 { drag = (i, CurvePoint(x: np.x - tx, y: np.y + ty)) } else { drag = (i, CurvePoint(x: d.start.x, y: np.y + ty)) }
                readout = np
                vm.settings.curves.set(channel, p)
            }
            .onEnded { _ in
                holdTimer?.cancel()
                drag = nil
                readout = nil
                // back on the line: untouched again (no curve to render, no edited dot)
                if Self.onLine(vm.settings.curves.points(channel)) && vm.settings.curves.points(channel) != ToneCurves.identity {
                    vm.settings.curves.set(channel, ToneCurves.identity)
                }
            }
    }

    private func removePoint(near loc: CGPoint, _ size: CGSize) {
        guard let (i, d) = nearest(shown(channel), to: loc, size), d < 36 else { return }
        removeAt(i)
    }

    private func removeAt(_ i: Int) {
        var p = shown(channel)
        removeAsk = nil
        guard i > 0, i < p.count - 1 else { return }
        p.remove(at: i)
        vm.settings.curves.set(channel, Self.onLine(p) ? ToneCurves.identity : p)
    }
}
