# Vignette and Grain quality review

28 October 2026. Read-only review of the production formulas while the Clarity and recipe-migration release is
being validated. No Vignette or Grain code was changed. Findings below are code-derived; they have not yet been
reproduced as new Metal fixtures or judged on the owner's phone.

## Main findings

1. **Grain Size has measurable dead ranges at preview sizes.** The 0.8-pixel cell floor can make several distinct
   slider values produce exactly the same procedural field. This is a concrete control-response issue.
2. **Vignette Midpoint interacts strongly with aspect and Roundness.** Midpoint 100 producing no effect can be a
   reasonable endpoint convention; the much larger aspect-dependent dead zone at circular Roundness needs review.
3. The remaining findings are rendering choices or validation gaps, rather than established defects: grain
   antialiasing, Roughness changing variance, film-like character, highlight preservation, and the ordering of grain,
   colour looks and HDR gain.

These belong in a subsequent effects batch. They do not expand the current release.

## Actual processing order

`Sources/Edit/Graph.swift:19,53-75` takes the decoded source's long edge, applies the main adjustments and Lens Blur,
then geometry/crop, then Vignette and Grain together in `lumenFinish`, then the colour/curve look LUT, then HDR gain.
The finish pass uses the **post-crop frame dimensions** for the vignette and the **pre-crop source long edge** for
grain cell size. Geometry returns a normalized origin, so the finish pass's centre calculation is correctly based
on that frame.

`Sources/Edit/Graph.swift:347-352` makes smaller exports by downsampling the already-developed full-resolution
image. A preview instead develops its smaller source directly. `Sources/MemoryBudget.swift:40` uses 1600 px in
careful mode, 2048 px normally, or 2560 px on the high-memory tier. Thumbnails commonly use 640 px.

## Grain

### Confirmed: cell-size floor collapses part of the Size slider

`Sources/Edit/Graph.swift:60` calculates:

```
cell = max(0.8, (0.5 + 2.5 * GrainSize / 100) * sourceLongEdge / 2000)
```

`Sources/Edit/Kernels.metal:380` has a second floor of 0.5, which is already exceeded by the Swift floor. At fixed
source size and other settings, every Size value in the following ranges therefore supplies exactly the same cell:

| Source long edge | Grain Size values collapsed to cell 0.8 |
| --- | --- |
| 640 px thumbnail | 0 through 80 |
| 1600 px careful preview | 0 through 20 |
| 2048 px normal preview | 0 through approximately 11.25 |
| 2560 px high-memory preview | 0 through 5 |
| 6000 px full-size source | none; minimum cell is 1.5 |

For Size 0, the 2048 px preview has cell 0.8, versus 1.5 at 6000 px. Relative to frame size, the preview cell is
approximately **56% larger**. For Size 25, a 640 px thumbnail uses cell 0.8 instead of the proportional 0.36, a
factor of **2.22**. These are exact parameter differences, not measurements of perceived grain strength.

Removing the floor alone is insufficient: subpixel procedural noise must be filtered. Otherwise the controls
would change numerically while introducing aliasing. A better implementation would define a stable grain field
and filter its footprint at each output scale. Analytic filtering, a few samples, or a reusable filtered texture
are possible approaches. Cost ranges from modest extra shader arithmetic to an additional small texture; AI is
not required.

### Preview and export need statistical, not unconditional pixel-equality tests

`lumenFinish` samples interpolated value noise at the current render's pixels. Full-size export later averages
those pixels when resized. A direct small preview does not necessarily integrate the same high-frequency field.
Some difference is consequently expected even without the cell floor. A properly filtered smaller output should
lose high-frequency grain; forcing its pixels or variance to match a point-sampled preview would not be a sound
target by itself.

Compare equivalent final display sizes, spatial spectra, autocorrelation and tone changes. Check whether the
preview gives a useful prediction of the exported appearance, with explicit expectations for downsampling.

### Character and Roughness: deliberate approximation, incompletely calibrated

`Sources/Edit/Kernels.metal:110-118,382-385` uses smooth, grid-interpolated value noise, plus a second octave at 2.3
times the frequency. The same fixed seed 7 is used for every image (`Graph.swift:63`). It is deterministic and
cheap, but it is not a measured film-stock or photographic-density model. Reusing a field on every same-sized
photo is a choice, not a functional failure; a stable per-photo seed would also be inexpensive.

For normalized Roughness `r`, the octave weights are `1 - 0.5r` and `0.7r`. Increasing Roughness therefore changes
both spectrum and total variance. If the octaves had equal independent variance, RMS at Roughness 50 would be
approximately 83% of Roughness 0, and at Roughness 100 approximately 86%. Actual sampled covariance must be measured
before treating those estimates as image results. A variance-normalized mix could separate character from Amount.

Grain is added equally to the three gamma-encoded RGB channels, then clipped. It has most amplitude around the
middle of the encoded brightness range, with a nonzero floor at black and white. Consequently clipping can lift
black, darken white, or shift very saturated colours. Those may be acceptable stylistic properties; they need
explicit tone/colour fixtures and visual judgement rather than an automatic claim that endpoints must remain exact.

The modulation uses Rec.709 luminance coefficients on gamma-encoded P3 values. That is an approximate brightness
weight, not linear P3 luminance. Changing the weights alone would not turn the effect into a physical grain model.

Grain also precedes curves/HSL/grading, so those controls can change its intensity or colour. HDR gain is applied
afterwards, potentially magnifying the SDR grain in bright HDR regions. These orderings are internally consistent
but need comparison material before deciding whether a final-output grain stage would be preferable.

## Vignette

### Shape and useful range

`Sources/Edit/Kernels.metal:365-373` centres an ellipse/circle on the post-crop frame. Roundness 0 uses normalized
frame coordinates, making an ellipse following the frame. Roundness 100 makes it circular in physical pixels,
scaled to the longer frame dimension. Portrait and landscape cases transpose consistently.

The final radius is always divided by `sqrt(2)`, even though Roundness changes the maximum radius reached inside
the frame. With Roundness 100 and aspect ratio `a >= 1`, the corner radius is:

```
dCorner = sqrt(1 + 1 / (a*a)) / sqrt(2)
```

At 3:1 this is approximately 0.7454. Since the feather transition starts at normalized Midpoint, **Midpoint 75
through 100 gives no vignette anywhere in that 3:1 frame**, regardless of Amount. At 3:2, the no-effect interval
starts around Midpoint 85. At Roundness 0, the mathematical corner radius is 1 and only the top endpoint is wholly
inactive. Thus Roundness changes the effective amount/range as well as shape.

Midpoint 100 being an off-like endpoint is not by itself proof of a bug. The aspect-dependent loss of a substantial
part of the range is the stronger candidate defect. Potential correction: normalize radius against the chosen
shape's frame-corner radius, then deliberately calibrate Midpoint and Feather endpoints. This is cheap arithmetic
and needs no extra image pass, but would change the look of existing vignette settings.

### Amount and photographic behaviour

Negative Amount is a linear-light exposure burn, up to -2 EV where the effect is full. This preserves RGB ratios
and is a sensible photographic approach. Positive Amount mixes up to 50% white into the image, which reduces
contrast and saturation: a white-overlay style, rather than the inverse exposure operation. The asymmetry can be
intentional. Lumen has no highlight-preservation adjustment for the dark vignette, so small lamps/specular areas
are darkened along with their surroundings.

Feather uses a smoothstep transition, with a minimum width of 0.05 normalized radius. That avoids an infinitely
hard discontinuity. The feather and midpoint mapping should be judged on real photos and multiple aspects.

## Existing coverage and proposed fixtures

Existing `Tests/engine/main.swift:696-698` writes effect examples. Lines 887-897 assert that Grain 50 changes pixels
and repeats deterministically. The slider-extremes checks include Amount, but there are no dedicated response,
aspect, frequency, Size/Roughness or preview/export assertions for these effects.

Meaningful follow-up fixtures:

- A flat mid-grey field at 640/1600/2048/6000 px, Grain Size 0/5/10/20/25/50/80/100. Measure autocorrelation and
  variance before and after equal-size output resampling; demonstrate the current identical Size intervals.
- Flat black, near-black, mid-grey, near-white and white patches with grain; record mean bias, clipping and grain
  variance. Include saturated P3 red/blue and a tone ramp to assess colour changes and smoothness.
- Roughness 0/25/50/75/100 at fixed Size and Amount. Compare frequency distribution and variance, with exact repeat
  checks retained. Distinguish desired character changes from unintended strength changes.
- Vignette on flat grey at square, 3:2, 2:3 and 3:1 aspects, sampling centre/edge centres/corners across the full
  Midpoint/Feather/Roundness ranges. Establish whether corner strength should remain comparable while shape changes.
- Cropped and quarter-turned pairs to verify the post-crop placement; transparent transform margins must remain
  transparent (the current finish kernel explicitly preserves them).
- Bright lamps in corners, a night scene, foliage and smooth skies, plus HDR on/off and smaller JPEG/HEIC exports.
  Show actual exported results at a common display size, not only full-size noise magnifications.

## Primary reference

[Adobe's Vignette and Grain documentation](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/retouch-photos.html)
describes the intended roles of Amount, Midpoint, Roundness, Feather, Size and Roughness. It also distinguishes
exposure-like vignette styles from paint overlay and describes highlight preservation. That supports treating
Lumen's positive overlay and missing highlight protection as design choices to compare, rather than claiming the
current formula duplicates Lightroom. Adobe also recommends judging grain at different zoom levels. Its public
documentation does not establish proprietary formulas or a numerical reference response for Lumen's sliders.

No new GPU tests or phone measurements were run for this review. The mathematical control-response findings above
should be reproduced and the photographic alternatives discussed before making an effects change.
