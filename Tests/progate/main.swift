import Foundation

var failures = 0
func expect(_ name: String, pro: Bool, edits: (inout EditSettings) -> Void) {
    var settings = EditSettings()
    edits(&settings)
    if settings.usesProFeatures != pro {
        print("FAIL: \(name)")
        failures += 1
    } else { print("PASS: \(name)") }
}

expect("untouched photo", pro: false) { _ in }
expect("active Lens Blur", pro: true) { $0.lensBlur.amount = 30 }
expect("focus controls without blur", pro: false) { $0.lensBlur.focusDistance = 0.8 }
expect("disabled Lens Blur", pro: false) { $0.lensBlur.amount = 30; $0.setOn(.lensBlur, false) }
expect("preset cannot exempt Lens Blur", pro: true) { Preset.all[0].apply(&$0); $0.lensBlur.amount = 30 }

expect("free light/color/crop", pro: false) { $0.exposure = 1; $0.saturation = 12; $0.cropL = 0.1 }
expect("neutral grading controls", pro: false) { $0.grading.shadows.hue = 180; $0.grading.balance = 20 }
expect("visible grading", pro: true) { $0.grading.shadows.sat = 15 }
expect("disabled grading", pro: false) { $0.grading.shadows.sat = 15; $0.setOn(.grade, false) }
expect("curve edit", pro: true) { $0.curves.master = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)] }
expect("disabled curve", pro: false) { $0.curves.master = []; $0.setOn(.curve, false) }
expect("detail edit", pro: true) { $0.texture = 15 }
expect("disabled detail", pro: false) { $0.texture = 15; $0.setOn(.detail, false) }
expect("sharpen mask without sharpening", pro: false) { $0.sharpenMasking = 40 }
expect("sharpening", pro: true) { $0.sharpness = 20; $0.sharpenMasking = 40 }
expect("neutral mask", pro: false) { $0.masks = [Mask.make(.linear)] }
expect("visible mask", pro: true) {
    var mask = Mask.make(.linear); mask.adjust.exposure = 1; $0.masks = [mask]
}
expect("zero opacity mask", pro: false) {
    var mask = Mask.make(.linear); mask.adjust.exposure = 1; mask.amount = 0; $0.masks = [mask]
}
expect("disabled masks", pro: false) {
    var mask = Mask.make(.linear); mask.adjust.exposure = 1; $0.masks = [mask]; $0.setOn(.masks, false)
}
expect("HDR", pro: true) { $0.hdr = true }
expect("heal", pro: true) { $0.heals = [HealSpot(strokes: [], x: 0, y: 0, w: 0.2, h: 0.2)] }
expect("disabled heal", pro: false) {
    $0.heals = [HealSpot(strokes: [], x: 0, y: 0, w: 0.2, h: 0.2)]; $0.setOn(.heal, false)
}

// A mixed batch must be gated even if its first photo is free.
var pro = EditSettings(); pro.texture = 15
let mixed = [EditSettings(), pro]
if !mixed.contains(where: { $0.usesProFeatures }) { failures += 1; print("FAIL: mixed batch") }
if [EditSettings(), EditSettings()].contains(where: { $0.usesProFeatures }) {
    failures += 1; print("FAIL: free batch")
}
for preset in Preset.all {
    for amount in [0.0, 0.25, 0.5, 0.75, 1.0] {
        expect("free built-in \(preset.name) strength \(amount)", pro: false) {
            var look = EditSettings(); preset.apply(&look)
            $0 = EditSettings.blend(EditSettings(), look, amount)
            $0.exposure = 0.7; $0.cropL = 0.1; $0.saturation = 8
        }
    }
    expect("\(preset.name) cannot exempt extra detail", pro: true) {
        preset.apply(&$0); $0.texture = 17
    }
    expect("\(preset.name) cannot exempt HDR", pro: true) {
        preset.apply(&$0); $0.hdr = true
    }
    expect("\(preset.name) cannot exempt masks", pro: true) {
        preset.apply(&$0); var mask = Mask.make(.linear); mask.adjust.exposure = 1; $0.masks = [mask]
    }
    expect("\(preset.name) cannot exempt heal", pro: true) {
        preset.apply(&$0); $0.heals = [HealSpot(strokes: [], x: 0, y: 0, w: 0.2, h: 0.2)]
    }
}
expect("custom advanced preset is not free", pro: true) {
    $0.texture = 17; $0.grading.shadows = GradeZone(hue: 130, sat: 22, lum: 3)
}
expect("preset followed by advanced curve is Pro", pro: true) {
    Preset.all[1].apply(&$0); $0.curves.master = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)]
}
expect("preset followed by independent grading change is Pro", pro: true) {
    Preset.all[4].apply(&$0); $0.grading.shadows.hue = 220
}
expect("preset followed by vignette tuning is Pro", pro: true) {
    Preset.all[4].apply(&$0); $0.vignetteFeather = 20
}
expect("preset cannot mix unrelated advanced sections", pro: true) {
    Preset.all[1].apply(&$0); var cinema = EditSettings(); Preset.all[4].apply(&cinema); $0.grading = cinema.grading
}
expect("free preset survives sidecar reload", pro: false) {
    Preset.all[1].apply(&$0)
    let encoded = try! JSONEncoder().encode($0)
    $0 = try! JSONDecoder().decode(EditSettings.self, from: encoded)
}
expect("pasted extra edits remain Pro", pro: true) {
    Preset.all[1].apply(&$0); var copied = EditSettings(); copied.texture = 17; $0.take(.detail, from: copied)
}
var freeLook = EditSettings(); Preset.all[1].apply(&freeLook)
if [freeLook, pro].contains(where: { $0.usesProFeatures }) == false {
    failures += 1; print("FAIL: free preset in mixed Pro batch")
}
for preset in Preset.all {
    expect("switch free looks then reduce \(preset.name) strength", pro: false) {
        var before = EditSettings(); Preset.all[1].apply(&before)
        var after = EditSettings(); preset.apply(&after)
        $0 = EditSettings.blend(before.builtinPresetStrengthBase, after, 0.25)
    }
}
expect("preset strength cannot launder existing Pro edits", pro: true) {
    var before = EditSettings(); before.texture = 17
    var after = EditSettings(); Preset.all[1].apply(&after)
    $0 = EditSettings.blend(before.builtinPresetStrengthBase, after, 0.5)
}
print("Pro policy failures: \(failures)")
exit(failures == 0 ? 0 : 1)
