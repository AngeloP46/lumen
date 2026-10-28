# Adjustment engine quality, 28 October 2026

Angelo approved implementing the adjustment review and publishing the verified personal build to SideStore.
The layout and controls stay the same. Main remains unlocked; shared code is ported to the sandbox separately.

## Current status (supersedes the historical validation below)

SideStore **0.1.774** is published and verified: main #180 (`24c29b7`), sandbox #181 (`079a63f`). Clarity's
bilateral correction shipped in **0.1.747**; AI selection/cache/export failure fixes in **0.1.756**; brush,
Lens Blur, Grain/Vignette, Heal/detection and bounded basic/refined thumbnails in **0.1.774**. One renderer serves
all saved recipes, with recipe format 3 and exact recovery JSON; no legacy shader dispatch was restored.
Full engine quality **40783385204 passes all 1,977 checks**. Its 24 MP/ProRAW memory stages and full UI
**40783388166** are still follow-ups, not yet recorded as passed here. The new `brush-checkpoint-pooling`
candidate is unvalidated/unpublished. Current scope, measurements and limits are in
[ADJUSTMENT-COMPLETION-2026-10-28.md](ADJUSTMENT-COMPLETION-2026-10-28.md),
[CLARITY-COVERAGE-2026-10-28.md](CLARITY-COVERAGE-2026-10-28.md), and
[AI-VISUAL-REVIEW-2026-10-28.md](AI-VISUAL-REVIEW-2026-10-28.md).

## Compatibility and rollback

- Starting main revision: `2ad11b89995c3ff30ea2ec6ba8336486c6aa8006` (last personal release 0.1.703).
- Baseline for this continuation: `0607d03` (SideStore 0.1.714). The earlier untouched engine is recoverable at the
  starting revision above. Git history retains both; the app now contains one rendering implementation.
- At Angelo's explicit request, all saved recipes, history, presets and pasted settings use current processing.
  Processing metadata reads/writes 2 but never selects a separate engine. Adjustment values, masks, Heal/AI
  references and original photos remain intact; the same values can now look different on previously edited photos.
- Before the first overwrite of an older sidecar/history/preset file, the exact original JSON is preserved once
  as `*.pre-engine-3.json`. A failed backup blocks that write and retains the pending save. These backup recipes
  also retain their Heal-patch references. Derived library thumbnails refresh for the current renderer.
- The edits format is 3, so 0.1.714 recognises newer saves and keeps a copy before editing after a rollback.
  Rollback restores code, not an identical appearance for adjustments made with newer formulas. Do not delete or
  reinstall Lumen to roll back. Backup JSON and Git history preserve recovery options without retaining old shaders.

## Implemented processing

- Compose individually increasing, bounded tone maps rather than add overlapping corrections at a fixed
  coordinate. Shadows/Highlights are now point curves, deliberately trading some regional adaptivity for
  predictable tone ordering and avoiding broad Gaussian tone halos. Brightness still protects small bright patches.
- Two-scale, amplitude-aware ordinary luminance noise reduction, with stronger shadow gates. Negative Texture and
  Noise combine as nonnegative remaining-detail gains. Sharpening avoids re-amplifying suppressed weak noise.
  This remains a fast photographic approximation, not camera-calibrated noise estimation or AI Denoise.
- Clarity uses a compact bilateral grid over a medium-scale log-light guide at <=640 px. Spatial/intensity weights
  preserve boundaries without vetoing whole surrounding surfaces. The former guided base plus broadly expanded
  edge veto failed on the owner's car and was removed in 0.1.747. A strictly immediate edge guard, bounded signed
  gains and squared slider travel retain smooth central adjustment and useful endpoints while leaving fine grain
  largely alone. Dense-edge scenes, the owner-approved car screenshot proxy, flat fields, halos and two-size
  response have rendered regressions; the original RAW and phone rendering still require owner confirmation.
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
- [Durand and Dorsey: Fast bilateral filtering](https://people.csail.mit.edu/fredo/PUBLI/Siggraph2002/) and
  [Chen, Paris and Durand: Bilateral grid](https://groups.csail.mit.edu/graphics/bilagrid/) — current Clarity's
  spatial/intensity filtering principles; independently implemented, not Lightroom's proprietary algorithm.
- [He et al.: Guided image filtering](https://people.csail.mit.edu/kaiming/eccv10/) — automatic-mask edge refinement;
  the earlier guided Clarity implementation is historical.
- [ICC: Chromatic adaptation](https://www.color.org/chadtag.xalter) — linear Bradford adaptation.
- [Bjorn Ottosson: Gamut clipping](https://bottosson.github.io/posts/gamutclipping/) — perceptual constant-hue
  mapping; the implementation targets Display P3 and adds a soft chroma shoulder.
- [Adobe: Tone and colour controls](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/image-tone-color.html)
  — intended photographic behaviour, not a claim to duplicate proprietary algorithms or numerical slider values.

Meaningful regressions are in `Tests/engine/imaging.swift` (actual Metal renders, migrated-recipe equivalence,
tone ordering, local planes, noise/detail, Dehaze, white balance, guided edges, gamut, grading and preview scale),
`Tests/engine/clarity.swift` (visible frequency-band strength, fine-grain retention, flat fields, hard boundaries,
real-photo endpoint sheets), `Tests/engine/ai-regressions.swift` (mask labels, cache identity, preview rounding and
repair), and `Tests/logic/main.swift` (recipe/history/preset migration and exact backup safety).
`imaging-compare-*.jpg` and `clarity-*.jpg` provide reviewable current-engine images from RAW/JPEG samples.
CPU prototypes alone are not Metal/device proof. See `AI-QUALITY-REVIEW-2026-10-28.md` for the separate AI audit.

Prior release evidence: 0.1.714 passed 1,270 engine checks and its memory sequences (40604699557); its full UI
run 40604410069 also passed. Historical 0.1.728 source 73c0abf: independent code reviews complete, migration logic passed,
all 89 focused GPU checks passed (40671254430), RAW/JPEG sheets inspected. Clarity mid-band amplitude at 1280 px
is .250/.350/.503 EV for -100/0/+100, versus .251/.350/.501 at 2560 px; fine band stays near .060 EV. The negative
gain remains below one; a tiny local-range fade prevents flat-field rounding bias. No test thresholds weakened.
All 1,315 broad engine quality checks and both memory sequences pass (40671575491); full UI still running. Release readiness
passes; SideStore 0.1.728 published and verified (40672946255, main #169 a44a6bd). Sandbox #168 merged 7efb41d after
OFF/ON/export-policy/StoreKit success (40671675913). Six persistence UI cases run separately in 40673361219; full UI
40671255251 remains follow-up. Phone HDR appearance, responsiveness and the owner's Clarity image remain unverified.
