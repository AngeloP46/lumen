import Foundation

// MARK: - Building blocks

struct Pt: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
}

struct HSLBand: Codable, Equatable, Hashable {
    var hue: Double = 0
    var sat: Double = 0
    var lum: Double = 0
}

struct HSLSettings: Codable, Equatable, Hashable {
    static let names = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
    var bands: [HSLBand] = Array(repeating: HSLBand(), count: 8)
    var isNeutral: Bool { bands.allSatisfy { $0 == HSLBand() } }
}

/// One colour-grading wheel. hue 0...360, sat 0...100, lum -100...100.
struct GradeZone: Codable, Equatable, Hashable {
    var hue: Double = 0
    var sat: Double = 0
    var lum: Double = 0
}

struct ColorGrading: Codable, Equatable, Hashable {
    var shadows = GradeZone()
    var midtones = GradeZone()
    var highlights = GradeZone()
    var blending: Double = 50
    var balance: Double = 0

    var isNeutral: Bool {
        [shadows, midtones, highlights].allSatisfy { $0.sat == 0 && $0.lum == 0 }
    }
}

// MARK: - Masks

enum MaskKind: String, Codable, CaseIterable, Identifiable {
    case subject, sky, background, brush, linear, radial, luminance, color
    var id: String { rawValue }

    var title: String {
        switch self {
        case .subject: "Subject"
        case .sky: "Sky"
        case .background: "Background"
        case .brush: "Brush"
        case .linear: "Linear"
        case .radial: "Radial"
        case .luminance: "Luminance"
        case .color: "Colour"
        }
    }
    var icon: String {
        switch self {
        case .subject: "person.crop.rectangle"
        case .sky: "cloud.sun"
        case .background: "mountain.2"
        case .brush: "paintbrush.pointed"
        case .linear: "square.tophalf.filled"
        case .radial: "circle.dashed"
        case .luminance: "circle.lefthalf.filled"
        case .color: "eyedropper"
        }
    }
    /// Kinds that are found automatically and need no shape editing.
    var isAutomatic: Bool { self == .subject || self == .sky || self == .background }
}

enum MaskOp: String, Codable, CaseIterable, Identifiable {
    case add, subtract, intersect
    var id: String { rawValue }
    var title: String {
        switch self {
        case .add: "Add"
        case .subtract: "Subtract"
        case .intersect: "Intersect"
        }
    }
    var symbol: String {
        switch self {
        case .add: "plus"
        case .subtract: "minus"
        case .intersect: "multiply"
        }
    }
}

struct BrushStroke: Codable, Equatable, Hashable {
    var points: [Pt]
    var size: Double   // brush diameter as a fraction of the long edge
    var erase: Bool
}

struct ColorSample: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
}

/// Adjustments that only apply inside a mask. Same scale as the global sliders.
struct LocalAdjust: Codable, Equatable, Hashable {
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var saturation: Double = 0
    var clarity: Double = 0
    var texture: Double = 0
    var dehaze: Double = 0
    var sharpness: Double = 0
    var noise: Double = 0

    var isNeutral: Bool { self == LocalAdjust() }
}

/// One shape inside a mask. A mask is built by combining components (add / subtract / intersect).
struct MaskComponent: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var kind: MaskKind
    var op: MaskOp = .add
    var invert = false
    var feather: Double = 50          // softness, %
    // linear: (x0,y0) = full effect, (x1,y1) = no effect.  radial: centre (x0,y0), radii (x1,y1) as fractions of width/height.
    var x0 = 0.5, y0 = 0.5, x1 = 0.5, y1 = 0.5
    var angle: Double = 0             // radial rotation, degrees
    var strokes: [BrushStroke] = []
    var autoMask = false              // brush: only stick to areas similar to what you painted over
    var lumLow = 0.0, lumHigh = 0.5   // luminance range (display brightness, 0...1)
    var lumLowFeather = 0.1, lumHighFeather = 0.1
    var samples: [ColorSample] = []   // colour range
    var tolerance = 0.18              // colour range

    static func make(_ kind: MaskKind, op: MaskOp = .add) -> MaskComponent {
        var c = MaskComponent(kind: kind, op: op)
        switch kind {
        case .linear: c.x0 = 0.5; c.y0 = 0.25; c.x1 = 0.5; c.y1 = 0.55
        case .radial: c.x0 = 0.5; c.y0 = 0.5; c.x1 = 0.3; c.y1 = 0.3
        case .luminance: c.lumLow = 0.0; c.lumHigh = 0.35
        default: break
        }
        return c
    }
}

struct Mask: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var components: [MaskComponent]
    var invert = false
    var amount: Double = 100          // overall mask opacity, %
    var adjust = LocalAdjust()

    static func make(_ kind: MaskKind) -> Mask {
        Mask(name: kind.title, components: [MaskComponent.make(kind)])
    }
}

// MARK: - All edits

/// Every non-destructive adjustment for one photo. Stored as a JSON sidecar; the original is never touched.
struct EditSettings: Codable, Equatable {
    // Light
    var exposure: Double = 0       // EV, -5...5
    var contrast: Double = 0       // -100...100
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    // Color
    var temperature: Double = 0    // relative, positive = warmer
    var tint: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0
    var blackAndWhite = false
    // Effects
    var texture: Double = 0
    var clarity: Double = 0
    var dehaze: Double = 0
    var vignette: Double = 0       // negative = darker edges
    var vignetteMidpoint: Double = 50
    var vignetteFeather: Double = 50
    var vignetteRoundness: Double = 0
    var grain: Double = 0          // 0...100
    var grainSize: Double = 25
    var grainRoughness: Double = 50
    // Detail
    var sharpness: Double = 0      // 0...100
    var sharpenMasking: Double = 0 // 0...100
    var noiseReduction: Double = 0 // 0...100 (luminance)
    var colorNoise: Double = 0     // 0...100
    // Looks
    var curves = ToneCurves()
    var hsl = HSLSettings()
    var grading = ColorGrading()
    // Local
    var masks: [Mask] = []
    // Geometry
    var straighten: Double = 0     // degrees, positive = clockwise
    var quarterTurns: Int = 0
    var cropAspect: Double = 0     // 0 = keep original ratio, otherwise width/height
    var cropZoom: Double = 1
    var cropX: Double = 0          // -1...1 pan of the crop window
    var cropY: Double = 0

    var isDefault: Bool { self == EditSettings() }
}

// MARK: - Presets

struct Preset: Identifiable {
    let id = UUID()
    let name: String
    let apply: (inout EditSettings) -> Void

    static let all: [Preset] = [
        Preset(name: "Natural") { _ in },
        Preset(name: "Punchy") {
            $0.contrast = 25; $0.vibrance = 30; $0.saturation = 8
            $0.shadows = 20; $0.highlights = -20; $0.sharpness = 25; $0.clarity = 15
        },
        Preset(name: "Sports") {
            $0.exposure = 0.2; $0.contrast = 15; $0.vibrance = 20
            $0.shadows = 25; $0.sharpness = 35; $0.noiseReduction = 15; $0.clarity = 10
        },
        Preset(name: "Matte") {
            $0.blacks = 40; $0.contrast = -10; $0.saturation = -10
            $0.highlights = -15; $0.vibrance = 10
        },
        Preset(name: "Cinematic") {
            $0.contrast = 15; $0.saturation = -5; $0.vignette = -20
            $0.grading.shadows = GradeZone(hue: 200, sat: 35, lum: 0)
            $0.grading.highlights = GradeZone(hue: 35, sat: 30, lum: 0)
        },
        Preset(name: "Moody") {
            $0.contrast = 20; $0.shadows = -20; $0.highlights = -25
            $0.vignette = -35; $0.saturation = -8; $0.clarity = 15
        },
        Preset(name: "B&W") {
            $0.saturation = -100; $0.contrast = 25; $0.sharpness = 20; $0.clarity = 15
        },
        Preset(name: "Film") {
            $0.blacks = 25; $0.contrast = -5; $0.saturation = -8; $0.grain = 30
            $0.grading.shadows = GradeZone(hue: 190, sat: 15, lum: 0)
            $0.grading.highlights = GradeZone(hue: 45, sat: 20, lum: 0)
        },
    ]
}

struct UserPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var settings: EditSettings
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case jpeg, heic, tiff
    var id: String { rawValue }
    var ext: String { self == .jpeg ? "jpg" : rawValue }
    var label: String { rawValue.uppercased() }
}
