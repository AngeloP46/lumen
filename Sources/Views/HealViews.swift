import SwiftUI

/// Heal on the photo: paint over something with one finger and lift to remove it. Earlier fixes show as small pins;
/// tap one to select it (the panel can then delete it). Two fingers still zoom and move the photo.
struct HealOverlay: View {
    @ObservedObject var vm: EditorViewModel
    let xform: ViewXform
    let geo: SourceGeometry
    @State private var cursor: CGPoint?
    @State private var painting = false

    var body: some View {
        let diameter = CGFloat(vm.healSize) * max(geo.source.width, geo.source.height) * scale
        ZStack {
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("healSpace"))
                    .onChanged { v in
                        guard !vm.pinching, !vm.healBusy, !vm.smartBusy else { return }
                        cursor = v.location
                        guard xform.rect.contains(v.location) else { return }
                        let p = norm(v.location)
                        if painting { vm.healExtend(p) } else { painting = true; vm.healBegin(p) }
                    }
                    .onEnded { _ in
                        cursor = nil
                        if painting { painting = false; vm.healEnd() }
                    })
                .accessibilityIdentifier("heal-layer")

            // the stroke being painted (and kept up while the AI works on it)
            if !vm.healStroke.isEmpty {
                Path { p in
                    let pts = vm.healStroke.map(screen)
                    p.move(to: pts[0]); p.addLine(to: pts[0])
                    for q in pts.dropFirst() { p.addLine(to: q) }
                }
                .stroke(Color.white.opacity(vm.healBusy ? 0.35 : 0.55),
                        style: StrokeStyle(lineWidth: max(diameter, 3), lineCap: .round, lineJoin: .round))
                .allowsHitTesting(false)
            }
            if let cursor {
                Circle().stroke(Color.white, lineWidth: 1.5).frame(width: diameter, height: diameter)
                    .position(cursor).allowsHitTesting(false)
            }

            // earlier fixes: a pin each; the selected one also shows what was painted
            ForEach(vm.settings.heals) { h in
                let on = vm.selectedHealID == h.id
                if on {
                    Path { p in
                        for st in h.strokes {
                            let pts = st.points.map(screen)
                            guard let f = pts.first else { continue }
                            p.move(to: f); p.addLine(to: f)
                            for q in pts.dropFirst() { p.addLine(to: q) }
                        }
                    }
                    .stroke(Theme.accent.opacity(0.45),
                            style: StrokeStyle(lineWidth: max(CGFloat(h.strokes.first?.size ?? 0.03) * max(geo.source.width, geo.source.height) * scale, 3),
                                               lineCap: .round, lineJoin: .round))
                    .allowsHitTesting(false)
                }
                Circle()
                    .fill(on ? Theme.accent : Color.white.opacity(0.85))
                    .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                    .frame(width: 16, height: 16)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
                    .onTapGesture { vm.selectedHealID = on ? nil : h.id }
                    .accessibilityIdentifier("heal-pin")
                    .position(screen(pinPoint(h)))
            }

            if vm.healBusy || vm.smartBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(vm.smartBusy ? "Smart fill \(Int(vm.smartProgress * 100))%" : "Removing…").font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .position(x: xform.canvas.width / 2, y: max(xform.rect.minY, 0) + 70)
                .allowsHitTesting(false)
                .accessibilityIdentifier("heal-busy")
            }
        }
        .frame(width: xform.canvas.width, height: xform.canvas.height)
        .coordinateSpace(name: "healSpace")
    }

    /// Screen points per source pixel.
    private var scale: CGFloat { xform.rect.width / max(geo.output.width, 1) }
    private func screen(_ p: Pt) -> CGPoint {
        let o = geo.toOutput(p)
        return xform.point(o.x, o.y)
    }
    private func norm(_ p: CGPoint) -> Pt {
        let s = geo.toSource(xform.unclamped(p, limit: -10...10))
        return Pt(x: min(max(s.x, 0), 1), y: min(max(s.y, 0), 1))
    }
    /// The middle of what was painted (the patch rectangle has extra room around it).
    private func pinPoint(_ h: HealSpot) -> Pt {
        let pts = h.strokes.flatMap(\.points)
        guard !pts.isEmpty else { return h.centre }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return Pt(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
    }
}

/// Heal panel: brush size, what to do with a selected fix, and how many there are.
struct HealPanel: View {
    @ObservedObject var vm: EditorViewModel
    @ObservedObject private var smart = SmartFillDownloader.shared
    @State private var askDownload = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !EditSession.hasHealModel {
                note("Heal isn't available in this build.")
            } else if case .failed(let why) = smart.state {
                note(why)
            } else if let msg = vm.healMessage {
                note(msg)
            } else {
                Text(vm.settings.heals.isEmpty
                     ? "Paint over what you want gone and lift your finger. Tap a pin to pick an earlier fix."
                     : "Paint over the next thing, or tap a pin to pick a fix.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // size shown 1...100 (100 = a quarter of the photo's long edge), like the mask brush
            LabeledSlider(title: "Size", value: Binding(get: { (vm.healSize * 400).rounded() },
                                                        set: { vm.healSize = max($0, 1) / 400 }),
                          range: 1...100, neutral: 12)
            if let id = vm.selectedHealID { selectedRow(id) }
            HStack(spacing: 8) {
                if let id = vm.selectedHealID {
                    Button(role: .destructive) { vm.deleteHeal(id) } label: {
                        Label("Delete", systemImage: "trash").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("heal-delete")
                }
                Spacer()
                if !vm.settings.heals.isEmpty {
                    Text("\(vm.settings.heals.count) fix\(vm.settings.heals.count == 1 ? "" : "es")")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button { vm.settings.reset(.heal); vm.selectedHealID = nil } label: {
                        Label("Clear all", systemImage: "arrow.counterclockwise").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("heal-clear")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    /// The picked fix: its versions (quick heal first) and Smart fill.
    @ViewBuilder
    private func selectedRow(_ id: UUID) -> some View {
        let versions = vm.versions(of: id)
        let at = versions.firstIndex { $0.id == id } ?? 0
        HStack(spacing: 8) {
            if versions.count > 1 {
                Button { vm.useVersion(versions[at - 1]) } label: { Image(systemName: "chevron.left") }
                    .disabled(at == 0 || vm.smartBusy).accessibilityIdentifier("heal-version-prev")
                Text(at == 0 ? "Quick fix" : "Smart \(at) of \(versions.count - 1)")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit().frame(minWidth: 80)
                    .accessibilityIdentifier("heal-version")
                Button { vm.useVersion(versions[at + 1]) } label: { Image(systemName: "chevron.right") }
                    .disabled(at >= versions.count - 1 || vm.smartBusy).accessibilityIdentifier("heal-version-next")
            }
            Spacer()
            smartButton(id, again: versions.count > 1)
        }
        .confirmationDialog("Download Smart fill?", isPresented: $askDownload, titleVisibility: .visible) {
            Button("Download \(smart.megabytes) MB") { smart.start() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Smart fill is a bigger AI that understands scenes better than the quick fix. It downloads once (\(smart.megabytes) MB, Wi-Fi recommended) and stays in the app. Each fill takes several seconds; the first one also prepares the AI and takes longer.")
        }
    }

    @ViewBuilder
    private func smartButton(_ id: UUID, again: Bool) -> some View {
        switch smart.state {
        case .ready:
            if vm.smartBusy {
                ProgressView(value: vm.smartProgress).frame(width: 110).accessibilityIdentifier("smart-progress")
            } else {
                Button { vm.smartFill(id) } label: {
                    Label(again ? "Another" : "Smart fill", systemImage: "sparkles").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.healBusy)
                .accessibilityIdentifier("smart-fill")
            }
        case .downloading:
            HStack(spacing: 6) {
                ProgressView(value: smart.fraction).frame(width: 90)
                Text("\(Int(smart.fraction * 100))%").font(.system(size: 11)).monospacedDigit()
                Button { smart.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel("Stop download")
            }
            .accessibilityIdentifier("smart-downloading")
        case .idle, .failed:
            Button { askDownload = true } label: {
                Label("Smart fill", systemImage: "arrow.down.circle").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("smart-get")
        }
    }

    private func note(_ s: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
            Text(s).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("heal-note")
    }
}
