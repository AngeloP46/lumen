# Lens Blur quality review — 28 October 2026

Read-only source review of `Graph.swift`, `Kernels.metal`, `Masks.swift`, `LensBlurSettings`, the focus/refinement view
model, and existing engine tests. No production or test changes in this review. The findings below are follow-up
candidates for a separate reproduced batch, not changes to the current Clarity/migration release.

## What the current implementation does well

The depth model estimates relative nearness, normalized between the photo's 2nd and 98th percentiles and flipped to
0 = near, 1 = far. It is not a measurement in metres. Portrait images are rotated for the landscape model input, then
rotated back. Sky masks can push sky to the far end. A guided edge refinement uses the photograph to improve the
coarse depth boundary. Subject masks additionally protect the detected subject, with manual brush refinement available.

Blur amount is proportional to image size: amount / 100 × long edge × 0.0063, with disc radius approximately 1.6 times
that value. Thus amount 100 gives about a 60 px disc on a 6000 px-wide photograph, and about 21 px on a 2048 px preview.
This is a photo-relative strength scale, not an aperture/f-stop calibration. Three disc-blurred layers are mixed by
the depth/radius map. Only selected background pixels feed the blur; premultiplied colour and alpha are blurred
together, then divided to avoid pulling subject colour into the background. That is a sound way to address one common
cutout halo, though it is not a complete physical depth-of-field simulation.

The settled preview/export use the full blur; slider dragging uses half-resolution blur layers while retaining the
full-size sharp image and mask. Blur happens before crop/rotation, with the same geometry applied to HDR gain.
Missing depth is stated in the panel, and export fails explicitly rather than silently omitting requested Lens Blur.
Zero amount, disabled Lens Blur and zero linked-mask opacity bypass the blur path.

## Concrete follow-up candidates

### 1. HDR colour and gain are blurred independently

`Graph.swift` applies Lens Blur separately to the SDR-developed image and its HDR gain image (lines 46–49), then
multiplies the blurred image by the blurred gain after the look LUT (lines 75–76). In general:

`blur(SDR) × blur(gain)` differs from `blur(SDR × gain)`.

Consequently bright HDR point lights can lose brightness as they spread into a darker background. This follows from
the graph ordering even with an otherwise perfect depth map. As a simple scalar averaging illustration, mix a point
with SDR = 1/gain = 4 and a background with SDR = 0.02/gain = 1, at 10% point weight. Multiplying the separate averages
gives 0.118 × 1.3 = 0.1534; averaging the actual HDR values gives 0.418. Those numbers illustrate the noncommutativity;
they are not a measurement of Core Image's bokeh filter or a phone photograph.

**Reproduce:** run the complete `develop(... hdrWeight: 1)` path on a constant far-depth field containing isolated
HDR lights, bright/dark edges and a uniform HDR patch. Compare integrated light and radial profiles against blurring
the combined linear HDR image. Include strength 0/23/100, slider-preview scale, export and a colour grade. The current
bright-point test passes a value of 8 directly to `applyLensBlur`, bypassing the SDR/gain split, so it cannot catch this.

**Potential improvement/cost:** blur combined HDR radiance and derive the resulting gain relative to the blurred SDR
base, keeping the output look semantics deliberate. The engine already evaluates two sets of blur layers in HDR;
this need not add another AI model or another set of six blur passes. It needs extra fused multiplication/division
and full-path colour/gain tests. Do not ship a change based solely on the scalar illustration.

### 2. Creating the initial refinement mask changes the depth ramp before painting

Without a linked mask, `lensBlurMask` uses `lumenLensRamp`: a linear depth radius behind `rampStart`, with detected
subject protection. `refineLensBlur` creates an initial depth mask with a smoothstep feather from `rampStart` to
`fullFrom`, plus the same subject subtraction (`EditorViewModel.swift`, `refineLensBlur`, approximately lines 1174–1183).
`lumenLensRefinedRamp` then multiplies the depth radius by that selection (`Kernels.metal`, approximately lines 515–518).

For default focus distance 0.30 and width 0.12: `fullFrom = 0.42`, `rampStart = 0.18`. At depth 0.30 outside the subject,
the original radius is (0.30 − 0.18)/(1 − 0.18) = 0.1463. The newly created mask has selection 0.5 there, so the refined
radius becomes max(0.1463, 0.15) × 0.5 = 0.075. This is a source-confirmed map difference with no brush stroke.
Near/Far controls also create that linked mask on their first adjustment.

Multiplying by a selection is a legitimate way to make partial brush corrections. The concern is the **transition
into refinement**: creating the initial automatic selection introduces a second feather on top of the original radius
ramp. It may be an intentional alternative mask interpretation, but merely entering “Refine with brush” can therefore
change the existing image before the user refines it. This is not yet rendered/reproduced in a new test or on Angelo's
phone, and should be assessed as a tool-entry consistency issue rather than declaring all mask-opacity semantics wrong.

**Reproduce:** construct a smooth depth ramp with no subject (then with a protected subject), compare the unlinked map
against the exact initial mask created by `refineLensBlur`, and render mid-scale stripes through both. A UI test should
open Refine, paint nothing, exit and compare the picture. Test Near/Far initialization separately from a real value edit.
If identity on entry is desired, start the editable representation from the exact existing radius map or apply the
feather in one place. This is mostly mask arithmetic/storage semantics, with little additional GPU cost.

### 3. Manual focus fallback does not necessarily leave the tapped depth sharp

The panel says “Tap the subject you want to keep sharp.” A tap sets `focusDistance` to the sampled depth. If subject
segmentation finds nothing, the message becomes “Manual focus set,” while the existing ramp remains. In the example
above, a tapped depth of 0.30 has nonzero radius because `rampStart` is 0.18. Automatic subject protection normally
overrides that radius, but the manual fallback lacks that protection. Thus the sampled plane itself can be softened.

**Reproduce:** use a depth field with known planes and no subject mask; tap a textured plane and compare it against the
zero-blur result. Test several widths and depths, including a plane at the far end. Agree whether “manual focus” means
an actually sharp plane or a depth-selection starting point. An explicit sharp band/ramp beginning behind it is cheap;
changing it would alter the current depth-control feel and saved photographs, so it deserves its own batch.

## Quality limits and tradeoffs that are not proven bugs

- Depth Anything is a monocular estimate, not camera-measured depth. Hair, fences, windows, reflections, transparent
  objects and thin car details can be assigned the wrong plane. The guided refinement follows image brightness, which
  can improve a silhouette but can also follow texture rather than depth. Manual brush refinement is a useful fallback.
- Model input is scaled to its fixed landscape aspect ratio (`scaleFill`) and depth is normalized per photograph.
  Equal slider values therefore do not represent equal real-world distances across photos. Portrait rotation preserves
  orientation, but unusual aspect ratios and small subjects still need photographic comparisons.
- Three radius layers interpolate between different point-spread functions. This is a fast approximation: intermediate
  bokeh can be a mixture of two discs, and depth occlusion between different background planes is not physically solved.
  Excluding the sharp subject from blur inputs prevents its colour halo but cannot reconstruct hidden background that
  was behind it. A more complete layered renderer would require extra depth bands, occlusion handling and storage.
- This is principally background blur. Foreground defocus and lens-specific aperture blades/cat-eye bokeh are not
  modeled. They should not be implied by an aperture-equivalence claim. Higher fidelity costs more sampling/passes;
  there is no basis here for promising cleaner results at the same phone resource cost.
- Each HDR render evaluates three SDR and three gain blur layers. Lazy Core Image graphs may tile/reuse buffers, but
  the number of expensive blur operations is substantial. Half-resolution dragging and reuse of ready masks are sensible.
  Large-image caps and the minimum 0.5 px blur radius can make extreme-size/tiny-strength behaviour depart from perfectly
  proportional scaling; typical 24/48 MP photographs are below the 200 px disc cap.
- If lens-like kernels are unavailable, the fallback uses masked variable blur and can have a different bokeh/edge look.
  Current normal-path tests do not establish that fallback's equivalence. Model precision and real-device frame pacing
  remain phone checks, as specified in the AI-model skill.

## Existing evidence and next fixtures

Current tests meaningfully cover a sharp foreground, reduced background stripe contrast, subject-colour bleed,
non-disappearing direct HDR point lights, zero/disabled/no-depth/zero-opacity behaviour, missing-depth export policy,
2× size consistency, geometry, old settings migration, increasing far-depth radius and subject-mask protection. There
is also a Sony RAW preview/JPEG-export exercise. Those tests do not establish exact optical realism or the three
full-path issues above.

Use a small fixed fixture set for the next batch: HDR lights on a dark far plane; smooth and stepped depth ramps;
thin bright/dark foreground silhouettes over coloured backgrounds; two background depths crossing; hair/fence/glass;
portrait and panoramic images; and tap-to-focus without a detected subject. Compare amount 0/23/100, unlinked versus
initially linked refinement, settled versus dragging preview, fit versus 100%, and exported SDR/HDR. Record radial
profiles, luminance/energy changes and known-sharp-plane error alongside reviewable crops. Keep the current release
unchanged until those candidates are reproduced and the desired behaviour is agreed.
