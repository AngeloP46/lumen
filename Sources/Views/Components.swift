import SwiftUI

enum Theme {
    static let accent = Color(red: 0.25, green: 0.62, blue: 1.0)
    static let panel = Color(white: 0.085)
    static let bar = Color(white: 0.11)
    static let chip = Color(white: 0.17)
}

// MARK: - Slider

/// A wide, forgiving slider: drag anywhere to move relative to where you started, double-tap to reset,
/// light haptic tick when it passes the neutral point.
struct ScrubSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var neutral: Double?
    var decimals = 0
    var track: [Color]?

    @State private var startValue: Double?
    @State private var wasAtNeutral = false

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
                    Capsule().fill(Color.white.opacity(0.18)).frame(height: 4)
                    Capsule().fill(Theme.accent)
                        .frame(width: abs(frac - nFrac) * w, height: 4)
                        .offset(x: min(frac, nFrac) * w)
                }
                Rectangle().fill(Color.white.opacity(0.5)).frame(width: 1.5, height: 12).offset(x: nFrac * w - 0.75)
                Circle()
                    .fill(Color.white)
                    .frame(width: 26, height: 26)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(x: frac * w - 13)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if startValue == nil {
                            let thumbX = frac * w
                            if abs(v.startLocation.x - thumbX) > 36 {
                                startValue = clamp(range.lowerBound + Double(v.startLocation.x / w) * span)
                            } else {
                                startValue = value
                            }
                        }
                        guard let start = startValue else { return }
                        var nv = start + Double(v.translation.width / w) * span
                        nv = clamp(nv)
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
                    .onEnded { _ in startValue = nil }
            )
            .onTapGesture(count: 2) { value = neutralValue }
        }
        .frame(height: 40)
    }

    private func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }
}

// MARK: - Parameter strip (chips + one big slider)

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

/// Lightroom-mobile-style editing strip: scroll the parameter names, one big slider underneath.
struct ParamStrip: View {
    let items: [ParamItem]
    @Binding var selected: String
    var leading: AnyView?

    var body: some View {
        let current = items.first { $0.id == selected } ?? items.first
        VStack(spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let leading { leading }
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
                                .frame(minWidth: 64)
                                .background(it.id == current?.id ? Color.white.opacity(0.16) : Theme.chip,
                                            in: RoundedRectangle(cornerRadius: 9))
                                .foregroundStyle(it.id == current?.id ? Color.white : Color(white: 0.75))
                            }
                            .id(it.id)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .onChange(of: selected) { _, new in withAnimation { proxy.scrollTo(new, anchor: .center) } }
            }
            if let c = current {
                ScrubSlider(value: c.value, range: c.range, neutral: c.neutral, decimals: c.decimals, track: c.track)
                    .padding(.horizontal, 20)
            }
        }
    }
}

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
