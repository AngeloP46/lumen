// DRAFT — sandbox, review required: the free/Pro line is Angelo's locked decision
// (plan §4.1 / §11). Verify against real edit states: a photo edited only with Light & Color
// + crop must return false; any Pro feature must return true.
//
// Free export: Light & Color + crop/rotate/straighten + presets.
// Pro: everything else — Grade, Curve, Detail, HDR, all masks, heal.
//
// Presets are free *to apply*, but a preset that sets e.g. curves leaves curve values in the
// photo — the photo then exports as Pro. That matches "export only the most basic features".
#if APP_STORE
import Foundation

extension EditSettings {
    /// True when the photo used anything outside the free set, so export requires Pro.
    /// Respects the Edits-sheet switches: a turned-off section keeps its values but doesn't
    /// apply them, so it doesn't count.
    var usesProFeatures: Bool {
        if isOn(.curve) && !curves.isNeutral { return true }
        if isOn(.grade) && !grading.isNeutral { return true }
        if isOn(.detail) {
            let detailActive = texture != 0 || clarity != 0 || dehaze != 0
                || vignette != 0 || grain != 0
                || sharpness != 0 || noiseReduction != 0 || colorNoise != 0
            if detailActive { return true }
        }
        if isOn(.masks) && masks.contains(where: { !$0.adjust.isNeutral && $0.amount > 0 && !$0.components.isEmpty }) { return true }
        if isOn(.heal) && !heals.isEmpty { return true }
        // HDR is photo-wide (not part of any section) — always Pro.
        if hdr { return true }
        return false
    }
}
#endif
