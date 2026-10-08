import SwiftUI

struct AdjustSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var decimals = 0
    var tint: Color?
    var track: [Color]?

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: "%.\(decimals)f", value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(value == 0 ? .secondary : .primary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value = range.contains(0) ? 0 : range.lowerBound } // double-tap the label to reset
            ZStack {
                if let track {
                    LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing)
                        .frame(height: 4)
                        .clipShape(Capsule())
                        .padding(.horizontal, 4)
                }
                Slider(value: $value, in: range)
                    .tint(track == nil ? tint : Color.clear)
            }
        }
        .padding(.top, 6)
    }
}

/// A slider bound to one Double on EditSettings.
struct KPSlider: View {
    @ObservedObject var vm: EditorViewModel
    let title: String
    let kp: WritableKeyPath<EditSettings, Double>
    var range: ClosedRange<Double> = -100...100
    var decimals = 0
    var track: [Color]?

    var body: some View {
        AdjustSlider(title: title,
                     value: Binding(get: { vm.settings[keyPath: kp] }, set: { vm.settings[keyPath: kp] = $0 }),
                     range: range, decimals: decimals, track: track)
    }
}

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
