# AI adjustment reliability follow-up

SideStore **0.1.756** is published. Main #176 merged `737e4fe`, source `f6e3465`, publish run `40738521966`.
Fresh feed, publish log and GitHub IPA size/digest agree: 356082659 bytes, SHA256
`b13e5cc8200f6b9a1d8493a2d92147de0fbbf8154c5b73089734e695f8cf7365`.
Sandbox #177 merged `a54fa93` after `40737807973` passed both builds, export policy and all four StoreKit tests.
Earlier Clarity port #175 merged `8649421` after the same checks passed in `40732458311`.

## Corrected behaviour

- Requested AI Denoise cannot silently disappear from export if its model and result are missing. Valid cached
  results still work without a model. Existing UI failure handling is used.
- Older PNG result/preview caches need a complete structure, correct dimensions and a loadable image. Metadata
  verdicts are capped at 128 entries, invalidated by file replacement/date/size, with no retained decoded bitmap.
  This is structural validation, not exhaustive compressed-pixel corruption detection.
- Automatic-mask failure remains distinct from successful empty detection across export, detail and undo/history
  transfers. Failed Background and inverted selections cannot become whole-photo adjustments; affected exports
  stop with an explicit message. Valid empty results and successful Sky fallback remain usable.
- Failed Scene-derived Landscape keys are invalidated for retry. Disabled/zero/neutral selections do not request
  unnecessary analysis. Lens Blur retains its specific missing-depth failure handling.

No model weights, inference settings, control gains, original photos, layout, Pro gates or Store code changed.
The Clarity correction from 0.1.747 is retained. All old recipes still use the one current renderer.

## Validation and limits

- `40737695135`: all **132** focused GPU failure/cache/transfer regressions pass on final source. Missing and valid
  cached results are tested through production export, including a measurable cached-denoise pixel change.
- `40734657158`: all six related UI methods pass: zoom-preview release, undo/redo, history, Heal deletion/privacy,
  selected-tool copy and multi-photo paste. Source `249a228`; subsequent production change only bounds finite
  mask resampling support, independently checked in the focused native/scaled/alpha regressions.
- Logic and protected iPhone Release readiness pass. Independent agents reviewed Clarity, AI reliability and mask
  integration; two additional integration edges were found and corrected before publication.
- Prior full engine `40734509335` passed 1638/1639. Its sole failure was an incorrect new test-fixture assumption:
  CIColor .7 was colour-converted, yielding Background .552009, not .3. Native and scaled values agree. A raw
  unmanaged scalar .7 gives .300002 native and .299992 scaled. Thresholds were retained. The old unclamped transfer
  also agrees in this fixture; clamping is finite-edge support hardening, not the demonstrated cause of that failure.
- Small-car native/complement probes now pass; the earlier four broad-suite failures were finite test-probe
  resampling and an invalid upscaling expectation. The zoom reload log existed at the old fixed timeout boundary;
  the UI test now awaits actual completion within 30 seconds.
- Final full engine quality **40738195410** passes all **1644** checks. Its later long memory sequences are ongoing;
  do not claim those passed until their results are recorded.
  The prior 32 repeated 24 MP RAW/Lens Blur thumbnails settled around 1306–1307 MB (one 1311 MB observation),
  without an upward trend. These are Mac measurements, not phone limits or phone speed evidence.

Phone: LocalDevVPN on → SideStore My Apps → pull to refresh → Update Lumen. Do not delete/reinstall.
Owner already confirmed thumbnail recovery works. New Clarity response and long phone sessions remain to verify.

## Still open

The current task list remains in QUALITY-CHECKLIST.md: brush compositing when softness changes, Lens Blur manual
focus/refinement and full HDR radiance, Grain Size/Vignette ranges, missing Heal patch/detection error paths,
photographic AI/detail/edge/geometry interactions and the larger-library visible-first/basic-refined scheduler.
Those have useful source findings and reproduction plans; they are not all fixed or photographically validated.
No literal 2,000-photo test was required or run.
