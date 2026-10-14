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
print("Pro policy failures: \(failures)")
exit(failures == 0 ? 0 : 1)
