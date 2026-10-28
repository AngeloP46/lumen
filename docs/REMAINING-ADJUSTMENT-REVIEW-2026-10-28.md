# Additional read-only follow-ups, 28 October

## Current disposition (supersedes the original findings below)

The original source-derived findings below were outside PR #169; several are now fixed. SideStore **0.1.747**
corrected Clarity coverage with bilateral analysis; **0.1.756** fixed failed/empty automatic selections and export
gates; **0.1.774** fixed brush compositing, Lens Blur, effects and Heal/detection reliability and shipped bounded
basic/refined thumbnail work. Personal main #180 (`24c29b7`) and sandbox #181 (`079a63f`) are merged.
Full quality **40783385204 passes all 1,977 checks**; its 24 MP/ProRAW memory and full UI **40783388166** remain
follow-ups. The later `brush-checkpoint-pooling` candidate is not published or validated yet.

- Original findings **1 and 2 are fixed in 0.1.756**: successful-empty masks stay distinct from failed selections,
  inverted failures do not become whole-photo edits, outcome transfer preserves failures, and active failed
  automatic edits explicitly block export. Landscape retry invalidation is covered too.
- Original finding **3 is fixed in 0.1.774**: stored per-run feather/erase compositing no longer changes old
  boundaries when a distant differently feathered stroke is added. Rendered/checkpoint/undo/cache tests cover it;
  the variable GPU-heap retention metric is still being investigated without widening its bound.
- Original finding **4 remains a deliberate processing convention**, not a demonstrated defect. Summed local
  offsets share bounded global limits; they are not sequential independent developments. Colour/luminance
  selection uses decoded pixels plus global exposure, so later colour/tone edits do not redefine the selection.
- Original finding **5 now has rendered 4x analytic references** for crop, turns, mirrors and straighten, plus
  existing transform/overlay/bounds tests. Additional perspective fine-detail probes are in progress; this is
  verification of the existing geometry, not a claim that its resampling formula was replaced.

Read [ADJUSTMENT-COMPLETION-2026-10-28.md](ADJUSTMENT-COMPLETION-2026-10-28.md) and
[AI-VISUAL-REVIEW-2026-10-28.md](AI-VISUAL-REVIEW-2026-10-28.md) for current evidence and photographic limits.

## Remaining priorities and defensive limits

1. Finish the live full UI/memory/export evidence and final brush-retention candidate checks. Phone GPU memory,
   timing and real high-ISO camera quality remain distinct from Mac synthetic/CPU results. No literal 2,000-photo
   run is needed to validate the bounded queue design.
2. AI Denoise's output plausibility guard samples every fourth retained x/y position. An isolated non-finite value
   at an unsampled position could bypass it; this is a defensive gap, not an observed fault in the current model.
   A full retained-tile finite check should be demonstrated with injection and preserve CPU retry/original fallback.
   Any accepted-output/run-policy change needs an explicit cache-version decision under the AI-model skill; the
   sampled gap alone does not justify invalidating every existing cleaned result or swapping models blindly.
3. Denoise/Heal PNG checks reject absent, incomplete, structurally invalid and dimension-incompatible assets.
   Header/status checks and lazy image construction do not certify arbitrary bitrot inside otherwise complete
   compressed pixels. Deeper validation needs a measured export/load policy; do not add per-frame full-image
   decoding or claim exhaustive integrity from the current metadata checks. No such phone corruption is reported.
4. Finish targeted subcontrol/interaction probes and photographic assessment where current evidence is limited;
   distinguish a failed invariant from subjective calibration. Generated Heal content and model denoise texture
   remain approximations. Existing code need not be changed merely because a more expensive alternative exists.

## Original findings (historical; use dispositions above)

1. Mask failure handling: Masks.swift componentImage(.background) returns a whole-white mask when aiSubject has
   been tried without a cached result, including a request failure (storeMask records tried after computeSubject
   notes failure). This conflates successful no-subject with unavailable selection. Reproduce by injecting
   noteFailure(aiSubject), storeMask(aiSubject,nil), compare background output with successful empty detection.
2. Requested automatic masks have no export failure gate comparable to AI Denoise/Lens Blur. Graph.swift
   renderDataOutcome prepares masks then checks only lensBlurMask. A failed subject/sky/people selection can
   therefore export without those edits (or background can affect everything). For >2700px, snapshotMasks only
   carries masks/tried, not failures, so the small-source failure also becomes a final tried-empty result.
   Reproduce a failing active mask in full export and large-source transfer, then require explicit export failure.
   Preserve successful empty detections as valid, distinct outcomes; do not retry repeatedly or run all masks on UI.
3. Brush softness path: when every stroke has the same feather, layer() paints/erases first and blurs the combined
   raster. With differing feathers, runs are blurred separately then max/multiply-combined. Adding a remote stroke
   with a different feather can therefore alter pre-existing paint/erase boundaries elsewhere. Test identical
   earlier strokes before/after such a remote stroke, excluding the new stroke's support. Fix requires choosing one
   consistent compositing convention; benchmark number-of-strokes cost/cache memory before replacing fast path.
4. Local parameter planes sum mask offsets and clamp once with globals. This is a reasonable fast design, but
   overlapping masks hitting clamps cease responding and are not equivalent to sequentially developing each mask.
   Colour/luminance selections are computed from decoded pixels plus global exposure, before other colour/tone
   edits; demonstrate stable selection semantics rather than claiming Lightroom numerical equivalence.
5. Geometry source pass: transform/flip/turn/straighten/crop order shared by photo and overlay is sound in principle.
   Integral crop bounds expand to pixels and Core Image interpolation is delegated, not explicitly benchmarked for
   tilted fine detail. CropFit math/tests alone do not establish photographic resampling quality. Add slanted lines,
   tiny checks and high-frequency diagonals, all turns/mirrors, crop-edge alpha, perspective and export-size tests.

The existing crop-version migration bug was fixed and tested in #169; don't reintroduce absent
cropVersion defaults. Existing Copy/Paste intentionally retains per-photo Heal/Lens Blur/AI result identity and
rebuilds copied automatic selections. Preset numeric mixing is not pixel crossfading, a design choice to explain.
