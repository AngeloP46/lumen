# Additional read-only follow-ups, 28 October

These are source-derived findings outside PR #169. No production changes or new GPU reproductions yet.

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
