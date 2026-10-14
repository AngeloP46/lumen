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
    /// Tints every tone (Lightroom's 4th wheel). Added 2026-10-11; older files load with it neutral.
    @Defaulted<DefaultZone> var global: GradeZone

    var isNeutral: Bool {
        [shadows, midtones, highlights, global].allSatisfy { $0.sat == 0 && $0.lum == 0 }
    }
}

// MARK: - Masks

enum MaskKind: String, Codable, CaseIterable, Identifiable {
    case subject, sky, background, people, landscape, brush, linear, radial, luminance, color, depth
    var id: String { rawValue }

    var title: String {
        switch self {
        case .subject: "Subject"
        case .sky: "Sky"
        case .background: "Background"
        case .people: "People"
        case .landscape: "Landscape"
        case .brush: "Brush"
        case .linear: "Linear"
        case .radial: "Radial"
        case .luminance: "Luminance"
        case .color: "Colour"
        case .depth: "Depth"
        }
    }
    var icon: String {
        switch self {
        case .subject: "person.crop.rectangle"
        case .sky: "cloud.sun"
        case .background: "mountain.2"
        case .people: "person.2"
        case .landscape: "photo"   // a whole scene (water, buildings, ground...), not just plants
        case .brush: "paintbrush.pointed"
        case .linear: "square.tophalf.filled"
        case .radial: "circle.dashed"
        case .luminance: "circle.lefthalf.filled"
        case .color: "eyedropper"
        case .depth: "square.3.layers.3d"
        }
    }
    /// Kinds that are found automatically and need no shape editing.
    var isAutomatic: Bool { self == .subject || self == .sky || self == .background || self == .people || self == .landscape }
    /// Kinds that need an on-device model run before they can be drawn (depth also has a range to edit).
    var needsAnalysis: Bool { isAutomatic || self == .depth }
}

/// Lightroom's Landscape mask parts, each a group of the scene-segmentation model's classes (COCO panoptic).
enum ScenePart: String, Codable, CaseIterable, Identifiable {
    case sky, water, vegetation, mountains, architecture, naturalGround, artificialGround
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sky: "Sky"
        case .water: "Water"
        case .vegetation: "Vegetation"
        case .mountains: "Mountains"
        case .architecture: "Architecture"
        case .naturalGround: "Natural ground"
        case .artificialGround: "Artificial ground"
        }
    }
    var icon: String {
        switch self {
        case .sky: "cloud.sun"
        case .water: "water.waves"
        case .vegetation: "leaf"
        case .mountains: "mountain.2"
        case .architecture: "building.2"
        case .naturalGround: "square.stack.3d.down.forward"
        case .artificialGround: "road.lanes"
        }
    }
    /// Label indices in DETRResnet50SemanticSegmentationF16 (its metadata lists 201 labels; checked by the engine test).
    /// Parts offered by the Landscape mask. Sky is its own mask (same AI), so it isn't repeated here; older edits
    /// that picked it still work.
    static let landscapeParts: [ScenePart] = [.water, .vegetation, .mountains, .architecture, .naturalGround, .artificialGround]

    /// "tree-merged": the only class looked at for sky seen through leaves.
    static let treeClass: Int32 = 184

    var classes: [Int32] {
        switch self {
        case .sky: [187]
        case .water: [148, 155, 178]                                   // river, sea, water (other)
        case .vegetation: [184, 193, 119]                              // tree, grass, flower
        case .mountains: [192, 198]                                    // mountain, rock
        case .architecture: [197, 128, 151, 171, 175, 176, 177, 199, 95, 181, 180, 112]  // buildings, roofs, walls, bridge, windows, doors
        case .naturalGround: [154, 159, 194, 125, 145]                 // sand, snow, dirt, gravel, playing field
        case .artificialGround: [149, 191, 147, 144]                   // road, pavement, railroad, platform
        }
    }
}

/// One thing removed with Heal: what was painted over (photo-normalised, x right, y down, like brush masks) and the
/// rectangle the AI rebuilt. The rebuilt pixels live in a file named after `id` (see `HealStore`), so the edit stays
/// small; `scale` undoes the brightness squeeze used to fit HDR highlights into the AI's 8-bit picture.
struct HealSpot: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var strokes: [BrushStroke]
    var x: Double, y: Double, w: Double, h: Double
    var scale: Double = 1
    /// Remove people: the box of the person removed (x, y, w, h as fractions of the photo, y down); nil for painted fixes.
    var person: [Double]? = nil
    var centre: Pt { Pt(x: x + w / 2, y: y + h / 2) }
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
    /// Softness this stroke was painted with (0...100). nil = older strokes: they follow the component's feather.
    /// Changing the Feather slider only affects strokes painted afterwards.
    var feather: Double?
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
    var lumLow = 0.0, lumHigh = 0.5   // luminance range (display brightness, 0...1); depth: range 0 = nearest ... 1 = farthest
    var lumLowFeather = 0.1, lumHighFeather = 0.1
    var samples: [ColorSample] = []   // colour range
    var tolerance = 0.18              // colour range
    var scene: [String] = []          // landscape: which ScenePart raw values it selects
    var amount: Double = 100          // this part's own opacity, % (a half-strength Subtract only takes half away)
    var subjectPoint: Pt? = nil       // optional selected Vision instance; nil protects all detected subjects

    static func make(_ kind: MaskKind, op: MaskOp = .add) -> MaskComponent {
        var c = MaskComponent(kind: kind, op: op)
        switch kind {
        case .linear: c.x0 = 0.5; c.y0 = 0.25; c.x1 = 0.5; c.y1 = 0.55
        case .radial: c.x0 = 0.5; c.y0 = 0.5; c.x1 = 0.3; c.y1 = 0.3
        case .luminance: c.lumLow = 0.0; c.lumHigh = 0.35
        case .depth: c.lumLow = 0.0; c.lumHigh = 0.35; c.lumLowFeather = 0; c.lumHighFeather = 0.15
        default: break
        }
        // AI masks start crisp (their edges are refined); Soften is there to blur them on purpose
        if kind.isAutomatic { c.feather = 0 }
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

/// Photo-specific focus in the estimated depth field (0 = near, 1 = far).
struct LensBlurSettings: Codable, Equatable {
    var amount: Double = 0
    var focusDistance: Double = 0.3
    var focusWidth: Double = 0.12
    /// Optional editable mask: depth plus painted Add/Subtract refinements.
    var maskID: UUID? = nil
    var subjectPoint: Pt? = nil
    var activated = false

    init() {}
    private enum CodingKeys: String, CodingKey { case amount, focusDistance, focusWidth, maskID, subjectPoint, activated }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        focusDistance = try c.decodeIfPresent(Double.self, forKey: .focusDistance) ?? 0.3
        focusWidth = try c.decodeIfPresent(Double.self, forKey: .focusWidth) ?? 0.12
        maskID = try c.decodeIfPresent(UUID.self, forKey: .maskID)
        subjectPoint = try c.decodeIfPresent(Pt.self, forKey: .subjectPoint)
        // A saved old Lens Blur object is already a user choice, including zero.
        activated = try c.decodeIfPresent(Bool.self, forKey: .activated) ?? true
    }
}

// MARK: - Keys that may be missing in older files

protocol DefaultValue { associatedtype Value: Codable & Equatable; static var value: Value { get } }
enum DefaultFalse: DefaultValue { static let value = false }
enum DefaultTrue: DefaultValue { static let value = true }
enum DefaultHDRStops: DefaultValue { static let value = 2.0 }
enum DefaultNoSections: DefaultValue { static let value: [String] = [] }
enum DefaultNoHeals: DefaultValue { static let value: [HealSpot] = [] }
enum DefaultZero: DefaultValue { static let value = 0.0 }
enum DefaultHundred: DefaultValue { static let value = 100.0 }
enum DefaultZone: DefaultValue { static let value = GradeZone() }
enum DefaultLensBlur: DefaultValue { static let value = LensBlurSettings() }

/// Decodes to the default when the key is absent, so sidecars and saved presets from before the key existed still load.
@propertyWrapper
struct Defaulted<D: DefaultValue>: Codable, Equatable {
    var wrappedValue: D.Value = D.value
    init() {}
    init(wrappedValue: D.Value) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws { wrappedValue = try decoder.singleValueContainer().decode(D.Value.self) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(wrappedValue) }
}

extension Defaulted: Hashable where D.Value: Hashable {
    func hash(into h: inout Hasher) { h.combine(wrappedValue) }
}

extension KeyedDecodingContainer {
    func decode<D: DefaultValue>(_ type: Defaulted<D>.Type, forKey key: Key) throws -> Defaulted<D> {
        try decodeIfPresent(type, forKey: key) ?? Defaulted<D>()
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
    // HDR (off by default; hdrStops = headroom in stops, 1...3)
    @Defaulted<DefaultFalse> var hdr: Bool
    @Defaulted<DefaultHDRStops> var hdrStops: Double
    // Local
    var masks: [Mask] = []
    @Defaulted<DefaultLensBlur> var lensBlur: LensBlurSettings
    // Geometry
    var straighten: Double = 0     // degrees, positive = clockwise
    var quarterTurns: Int = 0
    var cropAspect: Double = 0     // locked ratio (width / height); 0 = free
    var cropL: Double = 0          // crop frame as fractions of the straightened picture, top-left origin
    var cropT: Double = 0
    var cropR: Double = 1
    var cropB: Double = 1
    // Flip and transform (2026-10-11). Applied to the whole photo before the turns, straighten and crop.
    @Defaulted<DefaultFalse> var flipH: Bool
    @Defaulted<DefaultFalse> var flipV: Bool
    @Defaulted<DefaultZero> var tVertical: Double     // -100...100: + makes the top wider (fixes converging verticals)
    @Defaulted<DefaultZero> var tHorizontal: Double   // -100...100: + makes the left side taller
    @Defaulted<DefaultZero> var tAspect: Double       // -100...100: + stretches sideways, - stretches up/down
    @Defaulted<DefaultHundred> var tScale: Double     // 50...150 %
    @Defaulted<DefaultZero> var tOffX: Double         // -100...100: + moves right
    @Defaulted<DefaultZero> var tOffY: Double         // -100...100: + moves up
    /// Fill frame (Lightroom's Constrain Crop): zoom the transformed photo just enough that no empty corners show.
    @Defaulted<DefaultTrue> var tFill: Bool

    // Sections switched off in the Edits sheet (their values are kept, they just don't apply)
    @Defaulted<DefaultNoSections> var disabled: [String]

    // Heal: things removed with the AI eraser. They belong to this photo only (never pasted or saved in presets).
    @Defaulted<DefaultNoHeals> var heals: [HealSpot]

    var hasCrop: Bool { cropL > 0 || cropT > 0 || cropR < 1 || cropB < 1 }
    var hasTransform: Bool { tVertical != 0 || tHorizontal != 0 || tAspect != 0 || tScale != 100 || tOffX != 0 || tOffY != 0 }

    var isDefault: Bool { self == EditSettings() }
}

// MARK: - Sections (Edits sheet: switch a tool's edits off / on, reset one tool)

enum EditSection: String, CaseIterable, Identifiable {
    case light = "Light", color = "Color", grade = "Grade", curve = "Curve", detail = "Detail", masks = "Masks", heal = "Heal", lensBlur = "Lens Blur", crop = "Crop"
    var id: String { rawValue }
    /// Crop can be reset but not switched off (masks and the crop frame are placed on the cropped photo).
    var canSwitchOff: Bool { self != .crop }
    /// Heal patches are made for one photo's pixels, so they are never pasted onto another.
    var canPaste: Bool { self != .heal && self != .lensBlur }
    var icon: String {
        switch self {
        case .light: "sun.max"
        case .color: "thermometer.medium"
        case .grade: "circle.hexagongrid"
        case .curve: "point.topleft.down.curvedto.point.bottomright.up"
        case .detail: "triangle"
        case .masks: "circle.dashed.inset.filled"
        case .heal: "bandage"
        case .lensBlur: "camera.aperture"
        case .crop: "crop.rotate"
        }
    }
}

extension EditSettings {
    func isOn(_ s: EditSection) -> Bool { !disabled.contains(s.rawValue) }

    mutating func setOn(_ s: EditSection, _ on: Bool) {
        guard s.canSwitchOff else { return }
        disabled.removeAll { $0 == s.rawValue }
        if !on { disabled.append(s.rawValue) }
    }

    /// Puts one section back to its defaults (HDR is a photo-wide mode, not part of any section).
    mutating func reset(_ s: EditSection) {
        let d = EditSettings()
        switch s {
        case .light:
            exposure = d.exposure; contrast = d.contrast; highlights = d.highlights
            shadows = d.shadows; whites = d.whites; blacks = d.blacks
        case .color:
            temperature = d.temperature; tint = d.tint; vibrance = d.vibrance; saturation = d.saturation
            blackAndWhite = d.blackAndWhite; hsl = d.hsl
        case .grade:
            grading = d.grading
        case .curve:
            curves = d.curves
        case .detail:
            texture = d.texture; clarity = d.clarity; dehaze = d.dehaze
            vignette = d.vignette; vignetteMidpoint = d.vignetteMidpoint; vignetteFeather = d.vignetteFeather
            vignetteRoundness = d.vignetteRoundness
            grain = d.grain; grainSize = d.grainSize; grainRoughness = d.grainRoughness
            sharpness = d.sharpness; sharpenMasking = d.sharpenMasking
            noiseReduction = d.noiseReduction; colorNoise = d.colorNoise
        case .masks:
            masks = d.masks
        case .heal:
            heals = d.heals
        case .lensBlur:
            lensBlur = d.lensBlur
            lensBlur.activated = true
        case .crop:
            take(.crop, from: d)
        }
    }

    /// Copies one section's settings from `o` (Paste some edits; also how reset(.crop) is written).
    mutating func take(_ s: EditSection, from o: EditSettings) {
        switch s {
        case .light:
            exposure = o.exposure; contrast = o.contrast; highlights = o.highlights
            shadows = o.shadows; whites = o.whites; blacks = o.blacks
        case .color:
            temperature = o.temperature; tint = o.tint; vibrance = o.vibrance; saturation = o.saturation
            blackAndWhite = o.blackAndWhite; hsl = o.hsl
        case .grade:
            grading = o.grading
        case .curve:
            curves = o.curves
        case .detail:
            texture = o.texture; clarity = o.clarity; dehaze = o.dehaze
            vignette = o.vignette; vignetteMidpoint = o.vignetteMidpoint; vignetteFeather = o.vignetteFeather
            vignetteRoundness = o.vignetteRoundness
            grain = o.grain; grainSize = o.grainSize; grainRoughness = o.grainRoughness
            sharpness = o.sharpness; sharpenMasking = o.sharpenMasking
            noiseReduction = o.noiseReduction; colorNoise = o.colorNoise
        case .masks:
            masks = o.masks
        case .heal:
            heals = o.heals
        case .lensBlur:
            lensBlur = o.lensBlur
        case .crop:
            straighten = o.straighten; quarterTurns = o.quarterTurns; cropAspect = o.cropAspect
            cropL = o.cropL; cropT = o.cropT; cropR = o.cropR; cropB = o.cropB
            flipH = o.flipH; flipV = o.flipV
            tVertical = o.tVertical; tHorizontal = o.tHorizontal; tAspect = o.tAspect
            tScale = o.tScale; tOffX = o.tOffX; tOffY = o.tOffY; tFill = o.tFill
        }
    }

    /// The edits `before` -> `after` at `t` (0 = before, 1 = after): the preset Strength slider. Numbers are mixed;
    /// on/off settings and curves switch over halfway. Masks, crop and HDR stay as they are.
    static func blend(_ a: EditSettings, _ b: EditSettings, _ t: Double) -> EditSettings {
        func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        func z(_ x: GradeZone, _ y: GradeZone) -> GradeZone {
            GradeZone(hue: y.sat > 0 ? y.hue : x.hue, sat: m(x.sat, y.sat), lum: m(x.lum, y.lum))
        }
        var r = b
        r.exposure = m(a.exposure, b.exposure); r.contrast = m(a.contrast, b.contrast)
        r.highlights = m(a.highlights, b.highlights); r.shadows = m(a.shadows, b.shadows)
        r.whites = m(a.whites, b.whites); r.blacks = m(a.blacks, b.blacks)
        r.temperature = m(a.temperature, b.temperature); r.tint = m(a.tint, b.tint)
        r.vibrance = m(a.vibrance, b.vibrance); r.saturation = m(a.saturation, b.saturation)
        r.texture = m(a.texture, b.texture); r.clarity = m(a.clarity, b.clarity); r.dehaze = m(a.dehaze, b.dehaze)
        r.vignette = m(a.vignette, b.vignette); r.vignetteMidpoint = m(a.vignetteMidpoint, b.vignetteMidpoint)
        r.vignetteFeather = m(a.vignetteFeather, b.vignetteFeather)
        r.vignetteRoundness = m(a.vignetteRoundness, b.vignetteRoundness)
        r.grain = m(a.grain, b.grain); r.grainSize = m(a.grainSize, b.grainSize)
        r.grainRoughness = m(a.grainRoughness, b.grainRoughness)
        r.sharpness = m(a.sharpness, b.sharpness); r.sharpenMasking = m(a.sharpenMasking, b.sharpenMasking)
        r.noiseReduction = m(a.noiseReduction, b.noiseReduction); r.colorNoise = m(a.colorNoise, b.colorNoise)
        for i in r.hsl.bands.indices where i < a.hsl.bands.count {
            r.hsl.bands[i] = HSLBand(hue: m(a.hsl.bands[i].hue, b.hsl.bands[i].hue),
                                     sat: m(a.hsl.bands[i].sat, b.hsl.bands[i].sat),
                                     lum: m(a.hsl.bands[i].lum, b.hsl.bands[i].lum))
        }
        r.grading.shadows = z(a.grading.shadows, b.grading.shadows)
        r.grading.midtones = z(a.grading.midtones, b.grading.midtones)
        r.grading.highlights = z(a.grading.highlights, b.grading.highlights)
        r.grading.global = z(a.grading.global, b.grading.global)
        r.grading.blending = m(a.grading.blending, b.grading.blending)
        r.grading.balance = m(a.grading.balance, b.grading.balance)
        if t < 0.5 { r.blackAndWhite = a.blackAndWhite; r.curves = a.curves }
        r.masks = a.masks
        r.heals = a.heals
        r.lensBlur = a.lensBlur
        r.take(.crop, from: a)
        r.hdr = a.hdr; r.hdrStops = a.hdrStops
        r.disabled = a.disabled
        return r
    }

    func hasEdits(_ s: EditSection) -> Bool {
        var c = self
        c.reset(s)
        return c != self
    }

    /// What actually gets rendered: switched-off sections count as untouched.
    var effective: EditSettings {
        guard !disabled.isEmpty else { return self }
        var e = self
        for s in EditSection.allCases where s.canSwitchOff && !isOn(s) { e.reset(s) }
        e.disabled = []
        return e
    }
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
