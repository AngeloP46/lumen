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

/// A wide, forgiving slider. Drag anywhere to move relative to where you started; drag your finger *away* from the
/// track (up or down) to scrub in finer steps; double-tap anywhere on it to reset; a light tick marks the neutral point.
struct ScrubSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var neutral: Double?
    var decimals = 0
    var track: [Color]?
    var height: CGFloat = 40
    var bubble = true
    var onActive: ((Bool) -> Void)?

    @State private var base: Double = 0
    @State private var acc: Double = 0
    @State private var lastX: CGFloat = 0
    @State private var dragging = false
    @State private var moved = false
    @State private var ignoring = false
    @State private var wasAtNeutral = false
    @State private var fine: Double = 1
    @State private var lastTap: Date?
    @State private var lastTapX: CGFloat = 0

    private var neutralValue: Double { neutral ?? (range.contains(0) ? 0 : range.lowerBound) }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let span = range.upperBound - range.lowerBound
            let frac = CGFloat((value - range.lowerBound) / span)
            let nFrac = CGFloat((neutralValue - range.lowerBound) / span)
            ZStack(alignment: .leading) {
                if let track {
                    LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing)
                        .frame(height: 5).clipShape(Capsule())
                } else {
                    Capsule().fill(Color.white.opacity(0.16)).frame(height: 3)
                    Capsule().fill(Theme.accent)
                        .frame(width: abs(frac - nFrac) * w, height: 3)
                        .offset(x: min(frac, nFrac) * w)
                }
                Rectangle().fill(Color.white.opacity(0.45)).frame(width: 1.5, height: 10).offset(x: nFrac * w - 0.75)
                Circle()
                    .fill(Color.white)
                    .frame(width: moved ? 26 : 22, height: moved ? 26 : 22)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(x: frac * w - (moved ? 13 : 11))
                if moved && bubble {
                    Text(valueText)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Color(white: 0.2), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                        .foregroundStyle(.white)
                        .offset(x: min(max(frac * w - 22, 0), w - 46), y: -34)
                    if fine < 1 {
                        Text(fine < 0.3 ? "Fine ×0.2" : "Fine ×0.5")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .offset(x: min(max(frac * w - 20, 0), w - 60), y: 30)
                    }
                }
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            // simultaneous, so a vertical swipe on a slider still scrolls a list underneath it
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !dragging {
                            dragging = true
                            moved = false
                            ignoring = false
                            // a second touch shortly after a tap means reset
                            if let t = lastTap, Date().timeIntervalSince(t) < 0.4, abs(v.startLocation.x - lastTapX) < 44 {
                                value = neutralValue
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                ignoring = true
                                lastTap = nil
                            }
                            base = value
                            acc = 0
                            lastX = v.startLocation.x
                            onActive?(true)
                        }
                        if ignoring { return }
                        let dx = v.location.x - v.startLocation.x
                        if !moved {
                            guard abs(dx) > 5 else { return }   // dead zone: taps and scrolling never nudge the value
                            moved = true
                            lastX = v.location.x
                            return
                        }
                        let dy = abs(v.location.y - v.startLocation.y)
                        fine = dy < 36 ? 1 : (dy < 96 ? 0.5 : 0.2)
                        acc += Double((v.location.x - lastX) / w) * span * fine
                        lastX = v.location.x
                        var nv = clamp(base + acc)
                        if abs(nv - neutralValue) < span * 0.012 {
                            nv = neutralValue
                            if !wasAtNeutral { UISelectionFeedbackGenerator().selectionChanged() }
                            wasAtNeutral = true
                        } else {
                            wasAtNeutral = false
                        }
                        let f = pow(10.0, Double(decimals))
                        nv = (nv * f).rounded() / f
                        if nv != value { value = nv }
                    }
                    .onEnded { v in
                        if !moved && !ignoring && abs(v.translation.height) < 12 {
                            lastTap = Date()
                            lastTapX = v.startLocation.x
                        } else if moved {
                            lastTap = nil
                        }
                        dragging = false
                        moved = false
                        ignoring = false
                        fine = 1
                        onActive?(false)
                    }
            )
        }
        .frame(height: height)
    }

    private var valueText: String {
        decimals == 0 ? "\(Int(value.rounded()))" : String(format: "%.\(decimals)f", value)
    }

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
                ForEach(items) { it in
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            if let dot = it.dot { Circle().fill(dot).frame(width: 8, height: 8) }
                            Text(it.title).font(.system(size: 13)).lineLimit(1)
                        }
                        .frame(width: 80, alignment: .leading)
                        .foregroundStyle(Color(white: 0.82))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { reset(it) }
                        ScrubSlider(value: it.value, range: it.range, neutral: it.neutral, decimals: it.decimals,
                                    track: it.track, height: 34, bubble: false) { sliding = $0 }
                        // the value doubles as a reset button once the slider has been moved
                        Button { reset(it) } label: {
                            HStack(spacing: 3) {
                                if !it.isNeutral { Image(systemName: "arrow.counterclockwise").font(.system(size: 9, weight: .bold)) }
                                Text(it.display).font(.system(size: 13, weight: .medium).monospacedDigit())
                            }
                            .foregroundStyle(it.isNeutral ? Color.secondary : Theme.accent)
                            .frame(width: 58, height: rowHeight, alignment: .trailing)
                            .contentShape(Rectangle())
                        }
                        .disabled(it.isNeutral)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: rowHeight)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollDisabled(sliding)
    }

    // MARK: strip

    private var stripBody: some View {
        let current = items.first { $0.id == selected } ?? items.first
        return VStack(spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let header { header }
                        ForEach(items) { it in
                            Button { selected = it.id } label: {
                                VStack(spacing: 1) {
                                    HStack(spacing: 4) {
                                        if let dot = it.dot { Circle().fill(dot).frame(width: 8, height: 8) }
                                        Text(it.title).font(.system(size: 12, weight: .medium))
                                    }
                                    Text(it.display)
                                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(it.isNeutral ? Color.secondary : Theme.accent)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .frame(minWidth: 62)
                                .background(it.id == current?.id ? Color.white.opacity(0.16) : Theme.chip,
                                            in: RoundedRectangle(cornerRadius: 9))
                                .foregroundStyle(it.id == current?.id ? Color.white : Color(white: 0.75))
                            }
                            .id(it.id)
                            .contextMenu { Button("Reset \(it.title)") { reset(it) } }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .onChange(of: selected) { _, new in withAnimation { proxy.scrollTo(new, anchor: .center) } }
            }
            if let c = current {
                HStack(spacing: 6) {
                    ScrubSlider(value: c.value, range: c.range, neutral: c.neutral, decimals: c.decimals, track: c.track)
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

    var body: some View {
        Canvas { ctx, size in
            guard let d = data else { return }
            func path(_ bins: [Float]) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in bins.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(bins.count - 1)
                    p.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(v))))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                return p
            }
            ctx.blendMode = .plusLighter
            ctx.fill(path(d.r), with: .color(Color.red.opacity(0.6)))
            ctx.fill(path(d.g), with: .color(Color.green.opacity(0.6)))
            ctx.fill(path(d.b), with: .color(Color.blue.opacity(0.6)))
        }
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.2), lineWidth: 0.5))
    }
}

enum Tracks {
    static let temperature: [Color] = [Color(red: 0.25, green: 0.5, blue: 1), Color(red: 1, green: 0.85, blue: 0.2)]
    static let tint: [Color] = [Color(red: 0.2, green: 0.8, blue: 0.3), Color(red: 0.9, green: 0.2, blue: 0.8)]
    static let hue: [Color] = (0...12).map { Color(hue: Double($0) / 12, saturation: 0.85, brightness: 1) }
    static let saturation: [Color] = [.gray, Color(red: 1, green: 0.3, blue: 0.3)]
}
