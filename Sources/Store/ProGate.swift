// DRAFT — sandbox: free built-in preset recipes are allowed; arbitrary advanced edits are Pro.
// Validate the actual settings, never a preset name or user-editable entitlement flag.
#if APP_STORE
import Foundation

extension EditSettings {
    var usesProFeatures: Bool {
        let s = effective
        if s.hdr || !s.heals.isEmpty || s.lensBlur.amount > 0 { return true }
        if s.masks.contains(where: { !$0.adjust.isNeutral && $0.amount > 0 && !$0.components.isEmpty }) { return true }
        if s.matchesFreeRecipe(EditSettings()) { return false }

        // A whole built-in look, or its strength between neutral and that look, is free.
        // Light/Color/crop remain unrestricted. Disabled Pro sections are compared as rendered.
        // Presets never exempt HDR, masks or healing, including edits already on the photo.
        for preset in Preset.all {
            var recipe = EditSettings()
            preset.apply(&recipe)
            recipe.disabled = disabled
            let enabled = recipe.effective
            if s.matchesFreeRecipe(enabled) { return false }
            let pairs = zip(s.recipeAmounts, enabled.recipeAmounts)
            guard let anchor = pairs.first(where: { abs($0.1) > 0.000000001 }) else { continue }
            let strength = anchor.0 / anchor.1
            guard strength.isFinite, strength >= 0, strength <= 1 else { continue }
            var scaled = EditSettings.blend(EditSettings(), recipe, strength)
            scaled.disabled = disabled
            if s.matchesFreeRecipe(scaled.effective) { return false }
        }
        return true
    }

    /// Built-in Strength fades advanced settings from neutral on a free photo, so switching
    /// between free looks cannot accidentally create a paid blend. Existing Pro edits are
    /// retained as the starting point and remain gated whenever they still affect the result.
    var builtinPresetStrengthBase: EditSettings {
        guard !usesProFeatures else { return self }
        var base = self
        base.reset(.grade); base.reset(.curve); base.reset(.detail)
        return base
    }
    // Coupled amounts infer one common strength; each remaining parameter must match it.
    // This prevents using a preset to exempt a separately changed advanced slider.
    private var recipeAmounts: [Double] {
        [texture, clarity, dehaze, vignette, grain, sharpness, noiseReduction, colorNoise,
         grading.shadows.sat, grading.shadows.lum, grading.midtones.sat, grading.midtones.lum,
         grading.highlights.sat, grading.highlights.lum, grading.global.sat, grading.global.lum]
    }

    private func matchesFreeRecipe(_ other: EditSettings) -> Bool {
        func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000000001 }
        func zone(_ a: GradeZone, _ b: GradeZone) -> Bool {
            same(a.sat, b.sat) && same(a.lum, b.lum) && (a.sat == 0 || same(a.hue, b.hue))
        }
        guard curves == other.curves else { return false }
        if !(grading.isNeutral && other.grading.isNeutral) {
            guard zone(grading.shadows, other.grading.shadows),
                  zone(grading.midtones, other.grading.midtones),
                  zone(grading.highlights, other.grading.highlights),
                  zone(grading.global, other.grading.global),
                  same(grading.blending, other.grading.blending),
                  same(grading.balance, other.grading.balance) else { return false }
        }
        guard zip(recipeAmounts, other.recipeAmounts).allSatisfy({ same($0.0, $0.1) }) else { return false }
        if sharpness != 0 && !same(sharpenMasking, other.sharpenMasking) { return false }
        if vignette != 0 {
            guard same(vignetteMidpoint, other.vignetteMidpoint),
                  same(vignetteFeather, other.vignetteFeather),
                  same(vignetteRoundness, other.vignetteRoundness) else { return false }
        }
        if grain != 0 {
            guard same(grainSize, other.grainSize), same(grainRoughness, other.grainRoughness) else { return false }
        }
        return true
    }
}
#endif
