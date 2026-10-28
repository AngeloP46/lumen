# AI image quality review — 28 October 2026

## Follow-up from current SideStore 0.1.747

Parallel source review found two additional reliability defects. Requested AI Denoise could silently disappear
from export when both its model and cached result were absent. Legacy PNG result metadata checked file existence
without establishing a complete, correctly sized image. `clarity-release-followup` fixes both, with tiny no-inference
fixtures covering both export modes, denoise off, valid model-free cached output that measurably changes pixels,
structurally invalid/truncated/wrong-size legacy PNGs, decoder compatibility and invalid-preview fallback.
The legacy check caches at most 128 metadata verdicts and retains no decoded bitmap. It does not establish arbitrary
compressed-pixel integrity or change model inference. Mac validation/publication pending; these are not in 0.1.747.
Automatic-mask failures/export transfer are handled in the same reliability batch and recorded in the checklist.
Missing Heal patch files and failed people-detection messaging remain queued; photographic model-quality reviews
below are still incomplete. Do not infer that no-inference reliability fixtures validate AI image quality.

Scope: AI Denoise, Heal and Remove People. Source review plus inspection of the existing Mac engine artifacts in
`.local/imaging-final-renders` (`denoise.jpg`, `previews/remove-people.jpg`, `previews/gravel-heal.jpg`). Those artifacts
are examples, not a representative RAW benchmark or proof of the phone GPU's output. No model, weights, conversion,
compute-unit selection or tuning was changed in this review. Read with `docs/QUALITY-CHECKLIST.md` and the
`lumen-ai-models` skill. New fixes below are implemented on the working branch; CI/phone verification is pending.

## Concrete correctness fixes

1. **AI Denoise could write an incorrect border into its small residual copy.** `RowShrinker` rounded the destination
   dimensions, but assigned samples with the original unrounded scale. Example: 6000 × 4000 at a 4096 px long edge
   makes 4096 × 2731 output pixels; the last input row maps to row 2729, leaving output row 2730 empty. The fallback
   initialized RGB to 1. A residual of 1 is then subtracted from the photograph, so this can make a dark preview border.
   The full-resolution residual file itself is unaffected. Sample assignment now uses the actual output width/height,
   and finishing rejects missing bins. `Tests/engine/ai-regressions.swift` covers both orientations, a camera-shaped
   reduction, zero Float16 noise, and the older UInt16 preview representation.

2. **Existing affected small copies needed repair too.** Adding the correct mapping alone would leave cached bad
   previews in use indefinitely. `DenoiseStore.Info.previewVersion` now identifies the corrected mapping. An old,
   missing or incorrectly sized raw preview is rebuilt row by row from the unchanged memory-mapped full-resolution
   residual/cleaned copy. A unique output is finished before an atomic metadata replacement; repair, removal and sweep
   share the existing upgrade lock. Failed repair or a concurrent preview replacement falls back to full-resolution
   residual data, rather than using the bad preview or omitting denoise. This does not run AI again or bump the model
   identity. Tests check old preview repair, unchanged full bytes, invalid preview recovery, and truncated full-file
   rejection. Full raw-result size validation also prevents a truncated file from falsely counting as available.

3. **A paused clean could mix two RAW decoders.** Completed residual metadata already checked its decoder, but partial
   metadata did not record one. After an OS decoder change, old rows could be joined to new rows and the whole file
   incorrectly labelled as the new decoder. Partial metadata now records the decoder, and the production `canResume`
   gate rejects unknown/foreign decoders before appending. A restart reason is logged. Tests cover old JSON without
   the key, current/foreign decoders, HDR/model mismatch, and unchanged completed legacy-cache compatibility.

4. **Rejected detection crumbs could leak into a later person's removal mask.** `splitPeople` used the accepted-piece
   count for component labels. Discarding a component under 20 original pixels allowed the next component to reuse its
   label, although the discarded pixels still carried that label in the bitmap. Final person masks could therefore
   include unrelated earlier crumbs. Labels now increase for every component, including rejected ones. A synthetic
   early crumb plus a later person verifies that the rejected region is absent from the returned mask.

Implementation: `Sources/Edit/Denoise.swift`, `Sources/Edit/Heal.swift`; deterministic regressions:
`Tests/engine/ai-regressions.swift`. These tests require Core Image for mask/cache reading, but no AI inference.

## AI Denoise: sound choices and remaining limits

- **The model is appropriate in principle.** Lumen uses the real-noise PSNR SCUNet checkpoint, pinned by immutable
  revision, byte count and SHA-256. SCUNet combines convolution and attention, with diverse synthetic degradation
  training; it is not a raw-sensor demosaicer. Its authors describe the model and training in the
  [official repository](https://github.com/cszn/SCUNet). Lumen runs the fixed 256 px model on the GPU, with a separate CPU
  fallback. Existing phone evidence in the checklist supports keeping this runtime choice; Mac CPU results cannot
  establish GPU precision or phone speed.
- **Strength blending is sensible.** The stored quantity is the removed noise in linear working-space light, and the
  slider subtracts the chosen fraction. This makes 0 an identity and intermediate values a mixture of the noisy and
  cleaned pixels, without rerunning the model. The result is reused in preview, detail and export before Heal patches.
  This is not an intensity parameter inside the neural network, and it does not guarantee that every detail is real.
- **Input colour is an unproven domain choice.** The conversion script explicitly describes sRGB-encoded training
  images, while runtime tiles are gamma-encoded Display P3 (`makeDenoised`, the `p3` output render). The transfer curve
  is shared, but the RGB primaries are different. There is no simple wrong-profile relabelling on output: the residual
  is reconstructed consistently in P3. Nevertheless the network sees a different colour basis from its training data.
  Compare saturated P3 paint, neon, skin and neutral patches before deciding whether transforming through the training
  colour space is better. A naive P3→sRGB conversion can itself clip colours, so a colour-space change is not an
  automatic quality improvement. Three-channel conversions are inexpensive beside inference; preserving wide-gamut
  residuals correctly is the engineering work.
- **HDR protection trades cleaning for retained highlight data.** The photo is scaled by a sampled bright percentile
  before SDR model inference. Pixels whose largest encoded input channel reaches 0.98 keep their own original pixels.
  This avoids replacing clipped highlights with invented SDR values, but makes cleaning stop abruptly at that boundary.
  HDR/SDR reuse assumes their shadow/midtone decodes agree. The existing Sony RAW cross-mode test checks broad changes;
  it does not prove this on every ProRAW/camera model or at the threshold. Add noisy brightness ramps around the cutoff,
  isolated HDR lamps, saturated channels and HDR on/off comparisons at several strengths. A smooth highlight blend may
  have merit if those tests expose a visible transition; its shader cost would be small.
- **Tiles have context, but seams are not comprehensively proven absent.** A 16 px margin is discarded, with no
  feathering between the retained interiors. At 256 px this gives a 224 px step, approximately 31% more evaluated area
  than the retained interiors. The older 16-versus-32 context comparison is documented, but that alone is not a broad
  256 px seam benchmark. Add oblique fine lines, low-contrast fabric, smooth colour gradients and real high-ISO crops;
  shift the tile grid and compare both sides of every join. More overlap increases inference work and can improve
  context consistency; weighted blending costs extra accumulation storage/work and can soften disagreement. Neither
  should be added without measuring an actual seam.
- **The numeric guard is useful but sampled.** The runtime checks every fourth retained x/y position, rejecting
  non-finite values and large mean/far changes, retries on CPU, then preserves original pixels if no trustworthy tile
  returns. That is a good response to the historical bad-tile failures. It does not inspect every pixel for NaN/Inf,
  and diagnostic output counts retries without separately identifying all tiles ultimately left unchanged. A future
  hardening test should inject a bad value at an unsampled coordinate; exhaustive finite checking can be folded into
  the reconstruction loop at little extra cost. This is a defensive gap, not evidence that the current model emits
  isolated bad pixels.
- **Storage/performance are deliberately bounded.** Full residual storage is 8 bytes/pixel: about 192 MB for 24 MP,
  384 MB for 48 MP, plus a smaller preview. The row/strip approach avoids a second whole output in RAM. Rebuilding a
  bad preview costs a sequential read and small scratch buffers, not another neural clean. Keep the accepted 256 px
  runtime until real-phone diagnostics support a better choice. The current model identity still contains “512”;
  treat it as a historical identifier, not an accurate tile-size description. Future model/run-path changes must use
  a new identity, as required by the AI-model skill.

## Heal: what it can and cannot preserve

`makeHeal` builds a contextual square, mirrors image and hole at frame edges, scales the region for an 800 × 800 LaMa
model, and uses an opaque 8-bit sRGB image/mask interface. It records a patch plus a feathered mask. Earlier patches are
included when making later ones. Patch placement, HDR scale restoration and later photo adjustments are shared by
preview/export. The original [LaMa project](https://github.com/advimman/lama) uses Fourier convolutions for inpainting;
it predicts plausible missing content, rather than recovering a hidden original.

- The sRGB/8-bit generated patch has less colour/tonal capacity than the original RAW working image. HDR scaling
  preserves a useful brightness range and protects unremoved highlight pixels outside the hole, but cannot restore
  original detail inside newly generated content. A 16-bit TIFF export does not make this patch native 16-bit capture.
- Large patches are softer because the 800 px fill is enlarged. The full-resolution copied-texture path is explicitly
  **disabled** (`healDetailEnabled = false`) following actual wrong-texture/person-outline reports. Do not describe
  the current app as reconstructing full-resolution texture, or simply re-enable that path. In the inspected gravel
  artifact, the removed centre is visibly smoother than the surrounding grain. This illustrates the limitation; it
  does not establish how every real photograph looks.
- The blend is a wider soft mask, not a solved gradient/Poisson blend or explicit local colour matching. This is fast
  and often appropriate. Add a low-frequency sloping background, repeated lines, saturated P3 paint, dark gradients,
  frame-edge removals and overlapping fixes to judge boundary colour/structure. Gradient-domain blending may improve
  visible seams, but can introduce colour drift and requires an additional regional solver. Higher-resolution LaMa
  could retain more structure with substantially larger activations/model memory; neither has phone evidence here.
- The acceptance check tests mean hole brightness against a surrounding band. It catches black numeric failures,
  but can reject a valid dark completion next to a bright boundary, and can accept a wrong-colour or structurally
  nonsensical fill of plausible average brightness. CPU retry is not a second creative candidate. Add targeted dark
  holes near bright objects, per-channel colour checks and outside-hole invariance tests before tightening rejection.
- `HealStore.apply` skips a patch if its file or mask is missing. That is an existing failure mode worth a separate
  regression: delete/truncate one saved patch, reopen and export; the app should state that requested work is missing
  rather than silently returning an unhealed photograph. Do not invent a replacement fill during export.

## Remove People: detection and selection limits

The engine combines whole-frame person segmentation, person-instance detection and up to 24 extra body crops. It
unions those results, downsamples to roughly 1024 px and splits connected regions after dilation. Close/touching people
therefore become one selectable group, even if the instance request originally separated them. The main-person rule
is size-based: at least 3% of the frame and at least 30% of the largest detected person's area. It is a useful default,
not a semantic understanding of who should remain. Users can change selections; each chosen group is healed in order,
with earlier fills visible to later ones, and all finished removals become one undo step.

The inspected street artifact removes the selected person, but the generated bus doors/windows are visibly invented;
the all-removed result has uneven reconstructed detail. That is a realistic example of the model's limits.

Further regressions should cover two close people with separate instance IDs, a small main subject, a large background
bystander, partial bodies at frame edges, shadows/reflections, crowds, overlapping removals and no-person scenes.
Preserving instance IDs before adding segmentation-only gaps could improve individual selection without replacing the
model, at the cost of more mask bookkeeping/storage. It would require a deliberate change to grouping/selection logic.
`findPeople` currently swallows Vision errors and returns an empty list; the UI then says “No people found.” Distinguish
failure from a successful empty result before interpreting that message as evidence about the photograph.

## What existing evidence establishes

The engine has useful synthetic red-disc/gravel/edge/HDR Heal tests, a street-person example, Gaussian-noise removal
against a known clean JPEG, strength/off checks, basic edge retention and RAW HDR/SDR residual reuse. The inspected
cat crop is substantially cleaner, with some fine-fur smoothing. Current Gaussian testing on one JPEG, CPU fallback
execution and broad image averages do not establish real high-ISO RAW detail retention, exact tile invariance,
wide-gamut colour accuracy, every camera's HDR reuse or device GPU precision.

Before changing the neural model, retain the current implementations and compare a small fixed corpus of real Sony A9,
another Bayer camera and ProRAW photographs, including skin, car paint, night lights, fabric and foliage. Record 100%
crops, neutral/50/100 strength, error or edge metrics where ground truth exists, full-size export, elapsed time and peak
phone memory. “Better” must include preserved detail and usable phone resource cost, not only a smoother-looking image.
