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
            if let people = vm.peopleFound {
                peopleLayer(people)
            } else {
                paintLayer(diameter)
            }
        }
        .frame(width: xform.canvas.width, height: xform.canvas.height)
        .coordinateSpace(name: "healSpace")
    }

    /// Remove people: a tap on someone picks or keeps them; a pin on each (red = will be removed).
    @ViewBuilder private func peopleLayer(_ people: [FoundPerson]) -> some View {
        Color.clear.contentShape(Rectangle())
            .gesture(SpatialTapGesture(coordinateSpace: .named("healSpace")).onEnded { v in
                guard xform.rect.contains(v.location) else { return }
                vm.togglePerson(at: norm(v.location))
            })
            .accessibilityIdentifier("people-layer")
        ForEach(people) { p in
            let on = vm.peopleChosen.contains(p.id)
            ZStack {
                Circle().fill(on ? Color.red : Color.white.opacity(0.9))
                Image(systemName: on ? "xmark" : "person.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(on ? Color.white : Color.black.opacity(0.7))
            }
            .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
            .frame(width: 24, height: 24)
            .frame(width: 40, height: 40)
            .contentShape(Circle())
            .onTapGesture { vm.togglePerson(p.id) }
            .accessibilityIdentifier("person-pin")
            .position(screen(Pt(x: p.box.midX, y: p.box.midY)))
        }
        busyBadge
    }

    @ViewBuilder private func paintLayer(_ diameter: CGFloat) -> some View {
        Color.clear.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("healSpace"))
                .onChanged { v in
                    guard !vm.pinching, !vm.healBusy else { return }
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

        // earlier fixes: a pin each; the selected one also shows what was painted (or the person's box)
        ForEach(vm.settings.heals) { h in
            let on = vm.selectedHealID == h.id
            if on, let b = h.person, b.count == 4 {
                Path { p in
                    let c = [Pt(x: b[0], y: b[1]), Pt(x: b[0] + b[2], y: b[1]), Pt(x: b[0] + b[2], y: b[1] + b[3]), Pt(x: b[0], y: b[1] + b[3])].map(screen)
                    p.move(to: c[0]); for q in c.dropFirst() { p.addLine(to: q) }; p.closeSubpath()
                }
                .stroke(Theme.accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .allowsHitTesting(false)
            } else if on {
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

        busyBadge
    }

    @ViewBuilder private var busyBadge: some View {
        if vm.healBusy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(vm.healBusyText).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .position(x: xform.canvas.width / 2, y: max(xform.rect.minY, 0) + 160)   // below the histogram
            .allowsHitTesting(false)
            .accessibilityIdentifier("heal-busy")
        }
        // A19: while people are being removed, a Stop button goes below the badge (what's removed stays removed).
        if vm.healBusy, vm.removingPeople {
            Button("Stop") { vm.cancelRemovingPeople() }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .position(x: xform.canvas.width / 2, y: max(xform.rect.minY, 0) + 192)
                .accessibilityIdentifier("people-remove-cancel")
        }
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
        if let b = h.person, b.count == 4 { return Pt(x: b[0] + b[2] / 2, y: b[1] + b[3] / 2) }
        let pts = h.strokes.flatMap(\.points)
        guard !pts.isEmpty else { return h.centre }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return Pt(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
    }
}

/// Heal panel: brush size, what to do with a selected fix, and how many there are.
struct HealPanel: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        Group {
            if let people = vm.peopleFound {
                picker(people)
            } else {
                controls
            }
        }
        // load the Heal model in the background as soon as the tool opens (it takes a while the first time)
        .onAppear { vm.prepareHeal() }
    }

    /// Remove people, after the search: who goes.
    private func picker(_ people: [FoundPerson]) -> some View {
        let n = vm.peopleChosen.count
        let found = people.count == 1 ? "Found 1 person." : "Found \(people.count) people."
        return VStack(alignment: .leading, spacing: 10) {
            Text(n == 0 ? "\(found) Tap the ones you want removed."
                        : "\(found) Red ones will be removed: tap a person to keep or remove them.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("people-note")
            HStack(spacing: 8) {
                Button("Cancel") { vm.cancelPeople() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("people-cancel")
                Button(n == people.count ? "None" : "All") { vm.chooseAllPeople(n != people.count) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("people-all")
                Spacer()
                Button {
                    vm.removeChosenPeople()
                } label: {
                    Label(n == 1 ? "Remove 1 person" : "Remove \(n) people", systemImage: "person.2.slash")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(n == 0 || vm.healBusy)
                .accessibilityIdentifier("people-remove")
            }
            .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !EditSession.hasHealModel {
                note("Heal isn't available in this build.")
            } else if vm.healPreparing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing Heal… the first time after an update can take up to a minute.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("heal-preparing")
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
            // the same pill row as every tool's actions, page-wide reset on the right (design pass, 21 Oct)
            HStack(spacing: 6) {
                PillButton(title: "Remove people", system: "person.2.slash") { vm.findPeople() }
                    .disabled(vm.healBusy)
                    .opacity(vm.healBusy ? 0.45 : 1)
                    .accessibilityIdentifier("heal-people")
                if let id = vm.selectedHealID {
                    PillButton(title: "Delete this fix", system: "trash") { vm.deleteHeal(id) }
                        .accessibilityIdentifier("heal-delete")
                }
                Spacer(minLength: 6)
                if !vm.settings.heals.isEmpty {
                    PillButton(title: "Clear all (\(vm.settings.heals.count))", system: "arrow.counterclockwise") {
                        vm.settings.reset(.heal); vm.selectedHealID = nil
                    }
                    .accessibilityIdentifier("heal-clear")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    private func note(_ s: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
            Text(s).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("heal-note")
    }
}
