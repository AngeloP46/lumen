import SwiftUI

enum Theme {
    static let accent = Color(red: 0.25, green: 0.62, blue: 1.0)
    static let panel = Color(white: 0.075)
    static let bar = Color(white: 0.09)
    static let chip = Color(white: 0.16)
    static let separator = Color.white.opacity(0.07)
}

// MARK: - Navigation between photos

private struct OpenItemKey: EnvironmentKey { static let defaultValue: (LibraryItem) -> Void = { _ in } }
extension EnvironmentValues {
    /// Set by the library: replaces the open photo (used by swipe / next / previous in the editor).
    var openItem: (LibraryItem) -> Void {
        get { self[OpenItemKey.self] }
        set { self[OpenItemKey.self] = newValue }
    }
}

// MARK: - Slider layout (decided by the editor from the free space under the photo)

enum SliderLayout { case strip, list }

private struct SliderLayoutKey: EnvironmentKey { static let defaultValue: SliderLayout = .strip }
private struct RowHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 40 }
extension EnvironmentValues {
    var listRowHeight: CGFloat {
        get { self[RowHeightKey.self] }
        set { self[RowHeightKey.self] = newValue }
    }
    var sliderLayout: SliderLayout {
        get { self[SliderLayoutKey.self] }
        set { self[SliderLayoutKey.self] = newValue }
    }
}

// MARK: - Slider

/// The slider's haptics (Apple's sliders, owner 25 Oct: sliding should feel more satisfying): a firm click when the value
/// arrives at its neutral point, a soft bump at either end, light ticks along the way. Prepared when a finger lands, so
/// the first one is on time.
final class SliderHaptics {
    private let tick = UISelectionFeedbackGenerator()
    private let detent = UIImpactFeedbackGenerator(style: .rigid)
    private let end = UIImpactFeedbackGenerator(style: .soft)
    func prepare() { tick.prepare(); detent.prepare(); end.prepare() }
    func ticked() { tick.selectionChanged(); tick.prepare() }
    func atNeutral() { detent.impactOccurred(intensity: 0.8); detent.prepare() }
    func atEnd() { end.impactOccurred(intensity: 0.9); end.prepare() }
}

/// A wide, forgiving slider. Drag anywhere to move relative to where you started; drag your finger *away* from the
/// track (up or down) to scrub in finer steps; double-tap anywhere on it to reset.
/// Neutral is a detent (25 Oct): passing through it, the value rests there for a short stretch of finger travel with a
/// click, then carries on, so 0 is easy to land on and the values right next to it can still be chosen. Before, anything
/// within 1.2 % of the span snapped to neutral: on -100...100 nothing between -2 and 2, on Exposure nothing within 0.12 EV.
struct ScrubSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var neutral: Double?
    var decimals = 0
    var track: [Color]?
    var height: CGFloat = 40
    var bubble = true
    var onActive: ((Bool) -> Void)?
    var axID = ""

    @State private var detent: DetentDrag?
    @State private var lastX: CGFloat = 0
    @State private var dragging = false
    @State private var moved = false
    @State private var ignoring = false
    @State private var fine: Double = 1
    @State private var lastTap: Date?
    @State private var lastTapX: CGFloat = 0
    @State private var lastTick = 0
    @State private var haptics = SliderHaptics()
    /// True while a finger is on the slider. A gesture the system cancels (incoming call, Control Centre) never
    /// calls onEnded; this resets either way, so the slider can tidy up and the list can scroll again.
    @GestureState private var touching = false

    /// How far the finger travels through the neutral detent before the value moves on.
    private let detentPoints: CGFloat = 12

    private var neutralValue: Double { neutral ?? (range.contains(0) ? 0 : range.lowerBound) }
    private var span: Double { range.upperBound - range.lowerBound }
    /// A haptic tick (and a mark on the track while dragging) every twentieth of the range: 10 on -100...100, half a
    /// stop on Exposure.
    private var tickStep: Double { span / 20 }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let frac = CGFloat((value - range.lowerBound) / span)
            let nFrac = CGFloat((neutralValue - range.lowerBound) / span)
            let thick: CGFloat = moved ? 6 : 4
            ZStack(alignment: .leading) {
                if let track {
                    LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing)
                        .frame(height: thick + 1).clipShape(Capsule())
                } else {
                    Capsule().fill(Color.white.opacity(moved ? 0.2 : 0.14)).frame(height: thick)
                    Capsule().fill(Theme.accent)
                        .frame(width: max(abs(frac - nFrac) * w, 0), height: thick)
                        .offset(x: min(frac, nFrac) * w)
                }
                // while dragging, faint marks where the ticks are felt
                if moved {
                    ForEach(1..<20, id: \.self) { i in
                        Capsule().fill(Color.white.opacity(0.28)).frame(width: 1, height: 5)
                            .offset(x: w * CGFloat(i) / 20 - 0.5, y: 8)
                    }
                    .transition(.opacity)
                }
                Capsule().fill(Color.white.opacity(0.5)).frame(width: 2, height: moved ? 14 : 10).offset(x: nFrac * w - 1)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                    .frame(width: 24, height: 24)
                    .scaleEffect(moved ? 1.18 : 1)
                    .shadow(color: .black.opacity(moved ? 0.45 : 0.35), radius: moved ? 4 : 2, y: 1)
                    .offset(x: frac * w - 12)
                if moved && bubble {
                    Text(bubbleText)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Color(white: 0.2), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                        .foregroundStyle(.white)
                        .offset(x: min(max(frac * w - 24, 0), w - 50), y: -36)
                        .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                    if fine < 1 {
                        Text(fine < 0.3 ? "Fine ×0.2" : "Fine ×0.5")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .offset(x: min(max(frac * w - 20, 0), w - 60), y: 30)
                    }
                }
            }
            .frame(height: geo.size.height)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: moved)
            .contentShape(Rectangle())
            // simultaneous, so a vertical swipe on a slider still scrolls the list it is in; the list only stops
            // scrolling (onActive) once a drag has turned out to be sideways
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { v in drag(v, width: w) }
                    .onEnded { v in
                        if !moved && !ignoring && abs(v.translation.height) < 12 {
                            lastTap = Date()
                            lastTapX = v.startLocation.x
                        } else if moved {
                            lastTap = nil
                        }
                        if moved { onActive?(false) }
                        dragging = false
                        moved = false
                        ignoring = false
                        fine = 1
                        detent = nil
                    }
            )
        }
        .frame(height: height)
        .onChange(of: touching) { _, down in
            guard !down else { return }
            // next turn, so a normal onEnded (which may come after this) always goes first and keeps the tap logic
            DispatchQueue.main.async {
                guard dragging else { return }
                if moved { onActive?(false) }
                dragging = false
                moved = false
                ignoring = false
                fine = 1
                detent = nil
                lastTap = nil
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(axID.isEmpty ? "slider" : "slider-\(axID)")
        .accessibilityLabel(axID)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { dir in
            let step = decimals == 0 ? 1.0 : pow(10.0, -Double(decimals))
            value = clamp(value + (dir == .increment ? step : -step))
        }
    }

    private func drag(_ v: DragGesture.Value, width w: CGFloat) {
        if !dragging {
            dragging = true
            moved = false
            ignoring = false
            detent = nil
            haptics.prepare()
            // a second touch shortly after a tap means reset
            if let t = lastTap, Date().timeIntervalSince(t) < 0.4, abs(v.startLocation.x - lastTapX) < 44 {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { value = neutralValue }
                haptics.atNeutral()
                ignoring = true
                lastTap = nil
            }
            lastX = v.startLocation.x
            lastTick = tickIndex(value)
        }
        if ignoring { return }
        let dx = v.location.x - v.startLocation.x
        if !moved {
            // dead zone: taps never nudge the value. Then the first real movement decides: sideways
            // is this slider, up/down is a scroll of the list it sits in (the slider then lets go).
            let dy = v.location.y - v.startLocation.y
            guard abs(dx) > 6 || abs(dy) > 6 else { return }
            if abs(dy) >= abs(dx) { ignoring = true; return }
            moved = true
            lastX = v.location.x
            onActive?(true)
            return
        }
        let dy = abs(v.location.y - v.startLocation.y)
        fine = dy < 36 ? 1 : (dy < 96 ? 0.5 : 0.2)
        let step = v.location.x - lastX
        lastX = v.location.x
        // the neutral detent and the end stops (DetentDrag): no snap zone, no overshoot kept
        var d = detent ?? DetentDrag(value: value, neutral: neutralValue, range: range, hold: Double(detentPoints))
        d.move(points: Double(step), perPoint: span / Double(w) * fine)
        detent = d
        let f = pow(10.0, Double(decimals))
        let nv = (d.value * f).rounded() / f
        guard nv != value else { return }
        let old = value
        value = nv
        if nv == neutralValue && old != neutralValue {
            haptics.atNeutral()
        } else if (nv == range.lowerBound || nv == range.upperBound) && old != nv {
            haptics.atEnd()
        } else {
            let t = tickIndex(nv)
            if t != lastTick { haptics.ticked() }
        }
        lastTick = tickIndex(nv)
    }

    /// Which tick interval the value is in (ticks every twentieth of the range, counted from neutral).
    private func tickIndex(_ v: Double) -> Int { Int(((v - neutralValue) / tickStep).rounded(.towardZero)) + (v < neutralValue ? -1 : 0) }

    private var valueText: String {
        decimals == 0 ? "\(Int(value.rounded()))" : String(format: "%.\(decimals)f", value)
    }

    /// The bubble shows the direction too (+12, -0.35), as the value buttons do in Photos.
    private var bubbleText: String { value > neutralValue && neutralValue == 0 ? "+" + valueText : valueText }

    private func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }
}

// MARK: - Parameter panel

struct ParamItem: Identifiable {
    let id: String
    var title: String
    var value: Binding<Double>
    var range: ClosedRange<Double> = -100...100
    var decimals = 0
    var neutral: Double?
    var track: [Color]?
    var tint: Color?
    var dot: Color?
    /// Small heading shown above the first slider of a group in the full list (e.g. "Sharpening").
    var section: String?

    var isNeutral: Bool { abs(value.wrappedValue - (neutral ?? (range.contains(0) ? 0 : range.lowerBound))) < 0.0001 }
    var display: String {
        let v = value.wrappedValue
        if decimals == 0 { return String(format: "%d", Int(v.rounded())) }
        return String(format: "%.\(decimals)f", v)
    }
}

/// Either the compact strip (names scroll, one big slider) or the full list (every slider visible),
/// depending on how much room the photo leaves.
struct ParamPanel: View {
    let items: [ParamItem]
    @Binding var selected: String
    var header: AnyView?
    /// Extra control shown beside a section heading (e.g. the white balance picker next to "White balance").
    /// In the one-at-a-time layout, where there are no headings, it sits in the chip row instead.
    var accessories: [String: AnyView] = [:]
    /// Page reset with nothing else to sit beside: in the list it rides on the first heading's row (no row of its
    /// own), in the one-at-a-time strip it is a small round icon in front of the slider names.
    var pageReset: (() -> Void)?
    var pageResetEnabled = true
    @Environment(\.sliderLayout) private var layout
    @Environment(\.listRowHeight) private var rowHeight
    @State private var sliding = false

    var body: some View {
        if layout == .list { listBody } else { stripBody }
    }

    private func reset(_ it: ParamItem) {
        it.value.wrappedValue = it.neutral ?? (it.range.contains(0) ? 0 : it.range.lowerBound)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: list

    private var listBody: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                if let header {
                    header.padding(.horizontal, 14).padding(.bottom, 4)
                }
                if pageReset != nil, items.first?.section == nil {
                    HStack { Spacer(); smallReset }.padding(.horizontal, 14).frame(height: 30)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                    if let sec = it.section, i == 0 || items[i - 1].section != sec {
                        SectionHeading(title: sec, accessory: headingAccessory(sec, first: i == 0))
                    }
                    SliderRow(item: it, height: rowHeight, onActive: { sliding = $0 }, reset: { reset(it) })
                }
            }
            .padding(.vertical, 4)
        }
        .scrollDisabled(sliding)
    }

    private func headingAccessory(_ sec: String, first: Bool) -> AnyView? {
        guard first, pageReset != nil else { return accessories[sec] }
        return AnyView(HStack(spacing: 8) { if let a = accessories[sec] { a }; smallReset })
    }

    private var smallReset: some View {
        Button { pageReset?() } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).frame(height: 26)
                .background(Theme.chip, in: Capsule())
                .foregroundStyle(.white)
        }
        .opacity(pageResetEnabled ? 1 : 0.45)
        .disabled(!pageResetEnabled)
        .accessibilityIdentifier("pill-Reset")
    }

    private var resetIcon: some View {
        Button { pageReset?() } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Theme.chip, in: Circle())
                .foregroundStyle(.white)
        }
        .opacity(pageResetEnabled ? 1 : 0.45)
        .disabled(!pageResetEnabled)
        .accessibilityLabel("Reset")
        .accessibilityIdentifier("pill-Reset")
    }

    // MARK: strip

    private var stripBody: some View {
        let current = items.first { $0.id == selected } ?? items.first
        return VStack(spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if pageReset != nil { resetIcon }
                        if let header { header }
                        ForEach(Array(accessories.keys.sorted()), id: \.self) { k in accessories[k] }
                        ForEach(items) { it in
                            Button { selected = it.id } label: {
                                VStack(spacing: 1) {
                                    HStack(spacing: 4) {
                                        if let dot = it.dot { Circle().fill(dot).frame(width: 8, height: 8) }
                                        else if !it.isNeutral { EditedDot() }
                                        Text(it.title).font(.system(size: 12, weight: .medium))
                                    }
                                    Text(it.display)
                                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(it.isNeutral ? Color.secondary : Theme.accent)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .frame(minWidth: 62)
                                // the selected slider is unmistakable: accent fill and outline
                                .background(it.id == current?.id ? Theme.accent.opacity(0.3) : Theme.chip,
                                            in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9)
                                    .stroke(it.id == current?.id ? Theme.accent : Color.clear, lineWidth: 1.6))
                                .foregroundStyle(it.id == current?.id ? Color.white : Color(white: 0.7))
                            }
                            .id(it.id)
                            .accessibilityIdentifier("chip-\(it.id)")
                            .accessibilityAddTraits(it.id == current?.id ? .isSelected : [])
                            .contextMenu { Button("Reset \(it.title)") { reset(it) } }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .onChange(of: selected) { _, new in withAnimation { proxy.scrollTo(new, anchor: .center) } }
            }
            if let c = current {
                HStack(spacing: 6) {
                    ScrubSlider(value: c.value, range: c.range, neutral: c.neutral, decimals: c.decimals, track: c.track, axID: c.id)
                    Button { reset(c) } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .foregroundStyle(c.isNeutral ? Color(white: 0.3) : Theme.accent)
                    }
                    .disabled(c.isNeutral)
                }
                .padding(.leading, 22).padding(.trailing, 10)
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Shared slider row (every slider page uses this, so they all look and behave the same)

/// Small accent dot: "this has been changed from its default".
struct EditedDot: View {
    var body: some View { Circle().fill(Theme.accent).frame(width: 5, height: 5) }
}

/// Group heading inside a slider list.
struct SectionHeading: View {
    let title: String
    var accessory: AnyView?
    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color(white: 0.5))
                // on the text only: an identifier on the whole row would rename the accessory button inside it
                .accessibilityIdentifier("section-\(title)")
            Spacer()
            if let accessory { accessory }
        }
        .padding(.horizontal, 14)
        .frame(height: 28, alignment: .bottom)
        .padding(.bottom, 2)
    }
}

/// Name (with a dot once changed) · slider · value. Tapping the value, or double-tapping the name or the slider,
/// resets it.
struct SliderRow: View {
    let item: ParamItem
    var height: CGFloat = 40
    var labelWidth: CGFloat = 84
    var inset: CGFloat = 14
    var onActive: ((Bool) -> Void)?
    let reset: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                if let dot = item.dot { Circle().fill(dot).frame(width: 8, height: 8) }
                Text(item.title).font(.system(size: 13)).lineLimit(1).minimumScaleFactor(0.8)
                if item.dot == nil && !item.isNeutral { EditedDot() }
            }
            .frame(width: labelWidth, alignment: .leading)
            .foregroundStyle(item.isNeutral ? Color(white: 0.75) : Color.white)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { reset() }
            ScrubSlider(value: item.value, range: item.range, neutral: item.neutral, decimals: item.decimals,
                        track: item.track, height: 34, bubble: false, onActive: onActive, axID: item.id)
            // the value doubles as a reset button once the slider has been moved
            Button(action: reset) {
                HStack(spacing: 3) {
                    if !item.isNeutral { Image(systemName: "arrow.counterclockwise").font(.system(size: 9, weight: .bold)) }
                    Text(item.display).font(.system(size: 13, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(item.isNeutral ? Color.secondary : Theme.accent)
                .frame(width: 58, height: max(height, 34), alignment: .trailing)
                .contentShape(Rectangle())
            }
            .disabled(item.isNeutral)
            .accessibilityIdentifier("reset-\(item.id)")
            .accessibilityValue(item.display)
        }
        .padding(.horizontal, inset)
        .frame(height: height)
    }
}

// MARK: - Buttons

struct IconButton: View {
    let system: String
    var active = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .regular))
                .frame(width: 38, height: 38)
                .foregroundStyle(disabled ? Color(white: 0.35) : (active ? Theme.accent : Color.white))
        }
        .disabled(disabled)
    }
}

/// Round translucent button that floats over the photo.
struct FloatButton: View {
    let system: String
    var active = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
                .background(Color.black.opacity(0.25), in: Circle())
                .foregroundStyle(disabled ? Color(white: 0.4) : (active ? Theme.accent : Color.white))
        }
        .disabled(disabled)
    }
}

struct Chip: View {
    let title: String
    var system: String?
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let system { Image(systemName: system).font(.system(size: 12)) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? Theme.accent.opacity(0.9) : Theme.chip, in: Capsule())
            .foregroundStyle(selected ? Color.white : Color(white: 0.82))
        }
    }
}

// MARK: - Histogram

struct HistogramView: View {
    let data: HistogramData?

    /// Photomator-style (owner's request 2026-10-11): brightness as a calm grey shape, red / green / blue as clean
    /// lines over it, smooth curves, on a dark rounded panel. HDR keeps its zone on the right (one segment per stop).
    var body: some View {
        Canvas { ctx, size in
            guard let d = data else { return }
            let inset: CGFloat = 4
            let plot = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
            if let f = d.sdrFraction, d.hdrStops > 0 {
                // HDR zone: one segment per stop above SDR white; what the screen can't show right now is dimmed
                let x0 = plot.minX + plot.width * CGFloat(f)
                let seg = (plot.maxX - x0) / CGFloat(d.hdrStops)
                ctx.fill(Path(CGRect(x: x0, y: 0, width: size.width - x0, height: size.height)),
                         with: .color(Color.orange.opacity(0.14)))
                for i in 0..<Int(d.hdrStops.rounded()) {
                    let x = x0 + seg * CGFloat(i)
                    ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(Color.white.opacity(0.22)))
                }
                let shown = x0 + seg * CGFloat(min(d.screenStops, d.hdrStops))
                if shown < plot.maxX - 0.5 {
                    ctx.fill(Path(CGRect(x: shown, y: 0, width: size.width - shown, height: size.height)),
                             with: .color(Color.black.opacity(0.4)))
                }
            }
            // a smooth curve through the bins (midpoint quadratic curves), closed along the bottom when filled
            func curve(_ bins: [Float], closed: Bool) -> Path {
                var p = Path()
                guard bins.count > 1 else { return p }
                let pts = bins.enumerated().map { i, v in
                    CGPoint(x: plot.minX + plot.width * CGFloat(i) / CGFloat(bins.count - 1),
                            y: plot.maxY - plot.height * CGFloat(min(max(v, 0), 1)))
                }
                if closed { p.move(to: CGPoint(x: plot.minX, y: plot.maxY)); p.addLine(to: pts[0]) } else { p.move(to: pts[0]) }
                for i in 1..<pts.count {
                    let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
                    p.addQuadCurve(to: mid, control: pts[i - 1])
                }
                p.addLine(to: pts[pts.count - 1])
                if closed { p.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY)); p.closeSubpath() }
                return p
            }
            let luma = d.lumaShown ?? d.luma
            ctx.fill(curve(luma, closed: true), with: .color(Color(white: 0.62).opacity(0.5)))
            let channels: [([Float], Color)] = [(d.r, Color(red: 1, green: 0.32, blue: 0.3)),
                                                (d.g, Color(red: 0.35, green: 0.9, blue: 0.4)),
                                                (d.b, Color(red: 0.35, green: 0.6, blue: 1))]
            for (bins, colour) in channels {
                ctx.fill(curve(bins, closed: true), with: .color(colour.opacity(0.08)))
            }
            for (bins, colour) in channels {
                ctx.stroke(curve(bins, closed: false), with: .color(colour.opacity(0.95)),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
        }
        .background(Color(white: 0.07).opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}

enum Tracks {
    static let temperature: [Color] = [Color(red: 0.25, green: 0.5, blue: 1), Color(red: 1, green: 0.85, blue: 0.2)]
    static let tint: [Color] = [Color(red: 0.2, green: 0.8, blue: 0.3), Color(red: 0.9, green: 0.2, blue: 0.8)]
    static let hue: [Color] = (0...12).map { Color(hue: Double($0) / 12, saturation: 0.85, brightness: 1) }
    static let saturation: [Color] = [.gray, Color(red: 1, green: 0.3, blue: 0.3)]
    /// Grey to colour, softer than Saturation (Vibrance lifts the duller colours most).
    static let vibrance: [Color] = [Color(white: 0.45), Color(red: 0.95, green: 0.55, blue: 0.35)]
    static let fullSaturation: [Color] = [Color(white: 0.45), Color(red: 1, green: 0.2, blue: 0.35),
                                          Color(red: 1, green: 0.75, blue: 0.1)]
}
