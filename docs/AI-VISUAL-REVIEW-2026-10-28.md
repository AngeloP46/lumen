# AI visual follow-up, 28 October 2026

Inspected the actual downloaded outputs in `.local/ai-final-renders`, whose RESULT.txt reports all 1644 checks
passed (engine quality run 40738195410). These examples test the currently accepted models; the new missing-Heal
and typed people-search reliability changes do not replace/retrain those models or change their pixel generation.
Read with AI-QUALITY-REVIEW-2026-10-28.md for algorithm/runtime decisions and AI-RELIABILITY-2026-10-28.md for cache
and export-failure fixes. This is a visual judgment of these outputs, not a claim of exhaustive camera coverage.

## What the examples show

- **Denoise (`denoise.jpg`):** the added fine colour noise is substantially reduced. Fur edges, stripes and whisker
  structure mostly remain. The cleaned panel is visibly softer/smoother than the known-clean panel around the cheek
  and dense fur. Full strength is therefore a real tradeoff; a strength between 0 and 100 is useful. Test source is
  `cat.jpg` with fixed-seed Gaussian noise of standard deviation 0.04 added to gamma-encoded RGB, stored as 16-bit PNG.
  This is NOT a real high-ISO camera RAW benchmark. It cannot prove correlated sensor-noise/chroma handling or
  detail preservation on a specific camera, and it was rendered by Mac CPU inference rather than the phone GPU.
- **Gravel Heal (`previews/gravel-heal.jpg`):** the red disc is removed and low-frequency grey colour matches the
  surroundings reasonably. The generated centre is plainly smoother than the surrounding fine texture. There is
  no source evidence here for genuine full-resolution texture reconstruction inside the hole. This matches the
  deliberately disabled texture-transfer path; simply re-enabling that path would revive previous wrong-texture
  reports. For small removals this tradeoff may be acceptable, but large grainy patches can look artificial.
- **Lines over a soft background (`previews/bokeh-heal.jpg`):** the model continues the diagonal line group through
  the missing region and removes the red disc. The filled centre has a broad lighter area and small deviations in
  reconstructed lines. It is useful inpainting, with imperfect background matching; average brightness tests alone
  do not establish an invisible seam.
- **Tall edge/gradient Heal (`previews/tall-heal.jpg`):** the tall red post is removed completely in the inspected
  frame. The green-to-blue gradient is broadly retained, with faint vertical smoothing/tonal irregularity around
  the old post. This supports the region-coverage fix, rather than certifying every edge/panorama removal.
- **Remove People (`previews/remove-people.jpg`):** the chosen person is covered by the red selection and disappears
  in the single-removal result. The bus/window area that replaces them is invented and its shapes are distorted.
  Removing everybody makes larger, more obvious structural errors in the bus front, doors and pavement. Selection
  and fill completion work on this example; a successful removal is not recovery of the hidden real bus structure.
- **Detector comparison (`previews/people-finders.jpg`):** the whole-frame segmentation contains the two central
  people and a clear partial person at the right edge. The instance image finds two central instances and much
  weaker right-edge coverage. Combining useful successful answers has merit. This does not justify reporting
  “No people found” after all detectors fail; that failure-state correction is separate from selection quality.

## Decisions from this inspection

Keep the accepted SCUNet/LaMa model/runtime choices while correcting demonstrated reliability defects. These
examples do not justify a blind model swap, stronger universal denoise, or reinstating full-resolution Heal
texture transfer. Neural results remain approximate: plausible backgrounds, preserved edges where possible and
explicit failure handling are achievable; guaranteed original hidden detail is not.

The next photographic comparison should use a small fixed set of actual noisy Sony A9, another Bayer camera and
iPhone ProRAW images: skin, paint/neon, foliage and fabric. Compare strength 0/50/100 at 100%, neutral colour, seams,
HDR on/off and full exports. Record phone time/peak memory and inspect the GPU output, because Mac CPU tests
cannot establish those. No such representative real-noise corpus is present among these inspected fixtures, so
that camera/phone evidence remains an explicit limit, not a completed test.

Large or geometrically structured removals should be evaluated separately from small distractions; extra context,
higher model resolution and colour/gradient blending each trade computation/memory against different visible
defects. Changing them requires measured examples; completion or mean-brightness assertions alone are insufficient.

## Current reliability additions awaiting this batch's CI

Saved Heal/Remove People patches are checked before export: missing, structurally truncated, dimension-mismatched
or foreign-owned files must produce a clear failure instead of silently exporting original pixels. The legacy
no-owner patch format remains supported. Metadata-based PNG completion checks do not certify arbitrary bitrot
inside an otherwise complete compressed pixel stream; no per-frame full-size decoded validation was introduced.

Remove People now distinguishes successful empty search from decode/detector/memory failure. A successful fallback
mask remains usable when another detector fails; failed retries keep the previous good selection. Cancellation
invalidates the search generation, so a late answer cannot replace the new search or clear another operation's
busy state. Deterministic no-model regressions are in Tests/engine/heal-reliability.swift; real Vision scene and UI
tests must accompany them before these candidate changes are called validated or released.
