# Clarity coverage failure: owner's car screenshots

The owner confirmed thumbnail recovery works in 0.1.737, but Clarity still barely changes his car photograph.
The supplied screenshots are +96 and -100. Actual screenshot RGB differences in selected photo regions:
windshield 0.00/255 mean, grille 0.10/255, background cars/people 0.01/255, bonnet 3.62/255; only 15.3% of the
bonnet differs by more than 5/255. This is a real coverage failure, not a request for still more endpoint gain.

## What was wrong

`Engine.analyse` computed a local log-light max/min range, then spread its maximum across twice the broad Clarity
radius. `lmDevelopTone` faded Clarity to zero above 1.5–3 EV in that spread field. Crowded bright/dark boundaries
therefore disabled most surrounding surfaces. Larger gains could not change pixels multiplied by zero.

A local CPU proxy using the screenshot and the same thresholds/disk footprint predicts complete veto on 64% of
the windshield, 100% of the grille and 98% of the background ROI. These are proxy estimates: the screenshot's
colour/HDR encoding differs from the original RAW. The measured screenshot differences above are direct data.
Prior sine/flat/single-edge tests proved useful isolated response, but did not test scenes with many nearby edges.

## Scope audit

- The expanded range lives in `ImageSource.l2.r` and is read only in the Clarity branch. `l1.b` is also only its base.
- Both global Clarity and mask-local Clarity use that shared branch, and HDR gain repeats its tone computation.
  All three are affected; all three receive the correction.
- Exposure, Brightness, Contrast, Highlights/Shadows, Whites/Blacks and Bradford white balance do not read the
  range channel. HSL/grading/curve/B&W use their independent point/LUT processing. Dehaze uses `l2.g`, not `l2.r`.
- Texture and ordinary noise reduction use fine/medium residuals and pointwise magnitude/brightness protection.
  Sharpening uses its own fine residual and the explicit Masking control. Negative Dehaze scales detail reach
  according to the remaining photographic signal. Those rules do not spread a hard-edge veto across the scene.
- AI Denoise's highlight protection, Heal's explicit painted patches and Lens Blur's depth/selection are separate
  systems. This trace does not certify every algorithm/range as ideal; their broader quality reviews remain queued.

Rendered scope tests poison the Clarity range channel while exercising other light, colour/grading/HSL, detail/NR,
Dehaze and mask-local adjustments in both SDR and HDR. Outputs must remain identical, proving no accidental reuse.

## Candidate correction (validation pending)

Replace the guided base plus broad veto with a small bilateral grid of the medium-scale log-light guide.
Spatial and intensity weights preserve real boundaries through averaging. A short immediate-edge guard handles
resampling fringes; it is never dilated across the broad filter footprint. Scalar analysis remains <=640 px;
the compact grid and temporary readback do not require another full-resolution RAW bitmap. Fine noise stays
outside the analyzed frequency band. Keep squared slider travel and bounded/non-inverting signed gains.

This follows the filtering principles in [Durand and Dorsey, SIGGRAPH 2002](https://people.csail.mit.edu/fredo/PUBLI/Siggraph2002/)
and the compact grid representation in [Chen, Paris and Durand, SIGGRAPH 2007](https://groups.csail.mit.edu/graphics/bilagrid/).
It is an independent implementation, not a copy of Lightroom's proprietary processing.

The owner's screenshot crop is an explicitly labelled proxy in Tests/fixtures/clarity-car-proxy.png. It cannot
recover the original RAW or undo its existing edits; its unchanged windshield still reproduces the reported failure.
New regressions require response there and on patterned surfaces surrounded by dense hard edges, in addition to
the existing noise, endpoint, centre-travel, constant, halo, preview-size and 32-thumbnail memory checks.
Do not publish until rendered output and the owner's car proxy have been inspected. All thumbnail recovery code
from 0.1.737 remains unchanged. The larger-library scheduler remains a separate draft.
