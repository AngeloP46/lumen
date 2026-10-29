# What the adjustment review found

Lumen now has a conventional, coherent photo-processing pipeline. It does not copy Lightroom's private formulas
or promise that Lightroom +20 equals Lumen +20. The significant faults found were real: the old Clarity protection
could exclude most of a detailed scene, differently feathered brush strokes could change earlier erasing, some
Lens Blur controls changed the wrong depth region, and several effect sliders had ranges that did little or nothing.
Those behaviours were corrected rather than explained away as artistic preference.

## What was reviewed

| Area | Current approach and result | Practical limit or tradeoff |
|---|---|---|
| Exposure, Brightness, Contrast, Highlights, Shadows, Whites, Blacks | Bounded tone curves and ordered composition; monotonicity, small movement, endpoints and combinations rendered. | Mostly point curves; Lightroom uses more proprietary regional processing. The current choice is cheap, predictable and avoids broad tone halos. |
| Temperature, Tint, eyedropper and Auto | Relative Bradford white adaptation in linear Display P3; solver and renderer agree. | A relative correction around Apple's decoded white, not a calibrated camera Kelvin setting. |
| Saturation, Vibrance, HSL, colour grading, B&W and curves | Rendered colour/ramp and channel tests; perceptual gamut compression; B&W can be toned without accidentally restoring original colours. | Very saturated colours eventually meet the output gamut. Matching another editor's numbers is not a correctness criterion. |
| Texture, Clarity, Dehaze, Sharpening/Masking, ordinary noise reduction | Fine and medium detail treated separately. Clarity's broad veto is gone; the owner's approved car crop responds across surfaces. Dehaze and Clarity have fine travel near zero and stronger endpoints. Active Sharpen Masking is tested against weak noise and a strong edge. | Ordinary noise reduction is an efficient approximation, not a sensor-specific noise model. Extreme clarity/dehaze can look stylized. |
| Vignette and Grain | Source-relative filtered grain, usable Size travel and aspect-aware vignette. Midpoint, Feather and Roundness rendered, including wide/portrait images. | Grain is a filtered synthetic field, not a physical film simulation. Grain must get finer when a photo is reduced. |
| Manual and automatic masks | Consistent feathered paint/erase composition; failed automatic selections stay distinct from successful empty results through preview/export. | Local offsets sum before their shared limits. They are not separate sequential developments; pushing overlapping edits to a limit can saturate their response. |
| Lens Blur | Manual focus stays sharp, entering Refine preserves the existing map, Add/Subtract work in useful regions, and HDR colour lights spread their actual RGB radiance. | Estimated depth is approximate, especially hair, glass and complex boundaries. It cannot reconstruct real lens optics or hidden geometry perfectly. |
| AI Denoise | Current SCUNet runtime/model retained; strength mixes the stored removed noise without rerunning the model. Preview borders, interrupted-cache identity, invalid cache/export failures reviewed and fixed. Actual model output inspected. | Full strength can smooth texture. Real high-ISO camera and phone-GPU quality need photographic evidence; the synthetic cat test cannot establish that. |
| Heal and Remove People | Actual fills inspected; missing/corrupt saved fixes block export instead of disappearing. Failed search has an honest message; useful successful detector results survive another detector's failure. | LaMa invents the hidden content. Large gravel patches can be soft, and bus/windows/lines can be reconstructed incorrectly. Changing models or simply restoring texture transfer is not proven to improve this. |
| Crop, straightening, turns, mirrors and perspective | Shared geometry and overlays checked, plus fine-detail comparisons to a 4x analytic reference. Perspective cases exercise the actual warp. | Resampling cannot preserve detail above the output resolution; this is not recovery of missing sharpness. |
| HDR and exports | Explicit failures preserve requested edit fidelity; no silent SDR substitute. Full native RAW/ProRAW HDR exports are exercised under memory pressure. | Mac virtual-GPU failures and phone memory are different measurements. The identified full-size cache-pressure fix is being validated in PR184. |
| Library thumbnails and old edits | One active render, visible priority, per-photo atomic progress, bounded decoded cache, inexpensive basic images followed by editor refinement. All old recipes/history/paste use one current renderer. | Old values can look different after a processing correction, as requested. Exact recipe backups and Git history allow recovery; they do not keep another old renderer running. |

## What the evidence proves

Released0.1.774 passed1,977 complete engine quality assertions and96fullUI tests. Current0.1.782 source passes
2,014complete engine quality assertions and500focusedchecks, with actual RAW/JPEG and model outputs inspected.
New targeted probes verify active Sharpen Masking suppresses weak flat noise while retaining strong-edge response;
Vignette Feather/Roundness and two perspective-reference cases also pass. A32-photo RAW thumbnail sequence stays
around1,230–1,240MB after cleanup rather than climbing with the number of photos. No2,000-photo run was needed.

The long memory test caught a failure that the smaller quality fixtures missed: full-size HDR source preparation
and encoding could exhaust the virtual GPU. The non-caching source/export change in0.1.782 passes native24MP RAW
and12MP ProRAW open/detail/subject/Heal/HDR-export memory sequences without raising budgets or reducing output.
However, another native24MP run still aborts during encoding after heavy Heal GPU pressure, before the new
dimension/gain-map inspection. That exact case remains unresolved; the passing runs do not erase this failure.
These are Mac measurements, not guarantees about an iPhone's exact RAM usage. Checkpoint reuse is verified at
twoactualGPUbackings per12checkpoints; publication/parity and exact run IDs are in COMPLETION-CHECKPOINT-2026-10-28.md.

## What would justify more expensive processing

A fully scene-referred RAW pipeline, more regional tone mapping, stronger depth/segmentation or another inpainting
model could improve particular photographs. They would also change the base appearance, require cache/recipe
compatibility decisions, use more time or memory, or introduce different failure cases. They should be evaluated on
specific difficult original photos with a measured comparison. None is a universal professional upgrade merely
because its algorithm is more complex.

Remaining defensive limits are documented: sampled AI tile plausibility is not a full corruption scan, and PNG
metadata checks cannot certify arbitrary compressed-pixel bitrot. No current phone fault was traced to those cases.
They do not justify invalidating every user's successful AI cache or changing models during this repair.

The honest conclusion is that every adjustment family was examined, several flawed implementations were repaired,
and the remaining photographic compromises are explicit. A green synthetic test is evidence about the tested
behaviour, not certification that every extreme combination will look good or that generated detail is real.
