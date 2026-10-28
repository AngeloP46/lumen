# Adjustment engine quality, 27 October 2026

Angelo approved implementing the adjustment review and publishing the verified personal build to SideStore.
The layout and controls stay the same. Main remains unlocked; shared code is ported to the sandbox separately.

## Compatibility and rollback

- Starting main revision: `2ad11b89995c3ff30ea2ec6ba8336486c6aa8006` (last personal release 0.1.703).
- `EditSettings.processingVersion`: newly created/reset recipes use 2; absent keys in old recipes/history/presets
  read as 1, including the tolerant sidecar loader. Version 1 retains the original tone/colour formulas and
  Gaussian analysis. Original photo files are never rewritten.
- Existing edits keep version 1 until Reset all or replacement by a new preset/look. Reset is undoable. To test the
  improved engine without disturbing an edited photo, import another copy, or Reset all then undo afterwards.
- The edits format is 2. A rollback to the earlier app recognises a newer-format sidecar, keeps a copy before
  saving, and explains the mismatch. A rollback restores code; edits made with version 2 cannot have identical
  appearance in an older app that does not contain those algorithms. Do not delete/reinstall Lumen to roll back.
- Whole-look paste/presets carry their processing generation. A partial paste onto an already-edited photo keeps
  that destination's generation to avoid changing tools that were not selected. Cross-generation preset Strength
  restores the original recipe exactly at zero; intermediate amounts use the preset's engine.

## Implemented processing

- Compose individually increasing, bounded tone maps rather than add overlapping corrections at a fixed
  coordinate. Shadows/Highlights are now point curves, deliberately trading some regional adaptivity for
  predictable tone ordering and avoiding broad Gaussian tone halos. Brightness still protects small bright patches.
- Two-scale, amplitude-aware ordinary luminance noise reduction, with stronger shadow gates. Negative Texture and
  Noise combine as nonnegative remaining-detail gains. Sharpening avoids re-amplifying suppressed weak noise.
  This remains a fast photographic approximation, not camera-calibrated noise estimation or AI Denoise.
- Clarity uses a fast self-guided log-light analysis (coefficients computed at <=640 px, applied to the detailed
  guide) and sign-safe residual separation. Strong boundaries are protected better than a broad Gaussian blur.
- Signed quadratic Dehaze response gives fine control near zero. Atmospheric colour shares white adaptation;
  its post-exposure brightness is bounded so HDR lamps cannot wash out deep shadows at a -1 tick. Positive haze
  removal also protects luminance from going negative. The endpoints remain intentionally strong effects.
- Relative white balance uses Bradford cone adaptation in linear Display P3. The eyedropper and Auto solve the
  same transformation. This is a relative correction around Apple's decoded white, not a Kelvin control.
- Saturation/HSL/grading use an OkLab constant-hue/lightness chroma shoulder near the P3 gamut boundary, with a
  knee anchored to original chroma so tiny adjustments remain continuous. Ordinary in-gamut pixels have a cheap
  bypass. Signed cube roots handle temporary negative RGB from adaptation/removal until gamut mapping.
- B&W can be toned and lightened with Grade. Grading preserves true black/white endpoints and its combined
  luminance curve is bounded to remain increasing.
- Requested HDR exports fail with an actionable explanation if HDR encoding fails, instead of silently returning
  an SDR file. Explicit SDR export and TIFF remain available.

## RAW base: deliberate boundary

Apple's CIRAWFilter still supplies camera-specific base rendering, baseline exposure, default RAW noise reduction
and tone/gamut processing (Apple sharpening remains off). A linear-P3 buffer is not necessarily scene-referred
sensor data. Disabling that base or moving white balance into RAW decoding would change the pixel basis of saved
Heal patches and AI Denoise residuals, require cache identity/migrations, and change every default render. This
release improves the relative editor without invalidating those results. Noise 0 means no extra Lumen noise
reduction, not necessarily an entirely un-denoised RAW decode.

## Sources and validation

- [Apple: Capture and process ProRAW images](https://developer.apple.com/videos/play/wwdc2021/10160/) — default look
  versus scene-referred output; why a full RAW-base change needs deliberate validation.
- [He et al.: Guided image filtering](https://people.csail.mit.edu/kaiming/eccv10/) — local linear edge-aware model.
- [ICC: Chromatic adaptation](https://www.color.org/chadtag.xalter) — linear Bradford adaptation.
- [Bjorn Ottosson: Gamut clipping](https://bottosson.github.io/posts/gamutclipping/) — perceptual constant-hue
  mapping; the implementation targets Display P3 and adds a soft chroma shoulder.
- [Adobe: Tone and colour controls](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/image-tone-color.html)
  — intended photographic behaviour, not a claim to duplicate proprietary algorithms or numerical slider values.

Meaningful regressions are in `Tests/engine/imaging.swift` (real Metal renders of known synthetic images, legacy
golden vectors, tone ordering, overlapping local planes, detail/noise, Dehaze, white balance, guided edges, gamut,
grading, preview scale) and `Tests/logic/main.swift` (sidecar generation and rollback). The engine run also writes
`imaging-compare-*.jpg` with version 1/2 pairs on the Sony RAW and general sample JPEGs. CPU mathematical checks
are useful but are not Metal/device proof. CI results and phone follow-up are recorded below when available.

Validation status: implementation and independent code review complete; Apple compilation, engine renders,
memory run, full UI suite and sandbox OFF/ON builds pending. Real-phone HDR appearance and editing feel remain
Angelo's final check.
