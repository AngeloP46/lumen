# Lumen

A RAW photo editor for iPhone, written in Swift and SwiftUI on Apple's Core Image RAW engine, with its own Metal kernels
for the develop pass. It edits camera RAW (tested with Sony A9 `.ARW`), iPhone ProRAW `.DNG`, JPEG and HEIC without touching
the original, and everything runs on the phone: no account, no cloud, no subscription in this build.

Builds run on GitHub Actions (no Mac is used for development), and every change to `main` is published to a
[SideStore](https://sidestore.io) source for sideloading.

## What it does

- **Library**: import from Photos (the RAW or ProRAW original) or from Files / an SD card; days sections, star ratings, pick/reject flags,
  filters, select several photos to export, copy or paste edits, or run AI Denoise in a batch.
- **Tools** (bottom bar): Crop, Light, Color, Grade, Curve, Detail, Lens Blur, Masks, Heal, Presets.
  - **Light / Color / Grade / Curve**: exposure, contrast, highlights, shadows, whites, blacks, white balance, vibrance, saturation, tone curve (RGB and per
    channel), colour mixer (hue / saturation / luminance for 8 ranges), three-way colour grading, black and white, Auto.
  - **Detail**: texture, clarity, dehaze, sharpening, noise reduction, grain, vignette and **AI Denoise** (SCUNet running on the GPU, cleans the
    full-size photo once, then the strength slider is instant).
  - **Lens Blur**: depth-based background blur from an on-device depth estimate, with a subject picker and near / far edges.
  - **Masks**: brush, linear, radial, subject, background, sky, people, depth, luminance range and colour range, combined with add / subtract /
    intersect, each with its own adjustments (on-device Vision and Core ML models).
  - **Heal**: paint over something to fill it in with an on-device inpainting model; **Remove people** finds the people in the frame and takes them out.
  - **Crop**: aspect ratios, straighten, flip, transform and Auto level.
- **HDR**: RAW files open with extended highlight range on HDR screens; export with or without HDR.
- Histogram, pinch-zoom to a 100 % view, press and hold the photo to compare with the original, undo / redo, copy and paste edits, photo information,
  export to JPEG, HEIC or TIFF at a chosen size and quality.
- Edits are stored next to the library as small sidecar files; the original is never changed.

Camera coverage depends on Apple's RAW decoder. Sony A9 and iPhone ProRAW are the files tested most; other makes are expected to open but have not all been
tested, and missing metadata is shown as missing.

## Memory and large photos

iOS closes an app that goes past its memory limit (about 3.4 GB on an iPhone 17 Pro Max), so Lumen measures the limit at launch, plans the heavy jobs
(AI Denoise, Heal, the 100 % view, export) so that one runs at a time with room to spare, and records a short flight recorder that **Send diagnostics**
(⋯ menu) adds to its report. After iOS has closed Lumen twice in a day it uses smaller previews for the rest of that day. Details and the
history are in [`docs/QUALITY-CHECKLIST.md`](docs/QUALITY-CHECKLIST.md).

## Get it on your iPhone (no Mac needed)

Every push to `main` builds Lumen and publishes it as a SideStore source:

```
https://github.com/AngeloP46/lumen/releases/download/sidestore/source.json
```

1. Install SideStore once from a PC with [iloader](https://github.com/nab138/iloader) (needs iTunes, a cable and your Apple ID), plus **LocalDevVPN** from the App Store.
2. In SideStore: **Sources → +**, paste the URL above, then install Lumen from it. New builds show up as updates.
3. A free Apple ID signs apps for 7 days. Open SideStore (LocalDevVPN connected) and tap **Refresh All** once a week; this works anywhere with internet.

Other branches upload a `Lumen-ipa` artifact (Actions tab) that can be sideloaded by hand with Sideloadly.

## Getting camera files onto the phone

- SD card reader or the camera over USB-C (mass storage) → Files app → Lumen **+ → From Files**.
- Or the camera maker's transfer app to Photos (choose RAW) → Lumen **+ → From Photos**.

## How it is built and tested

- `project.yml` (XcodeGen) generates the Xcode project in CI; no project file is committed. Metal needs the Core Image kernel flags set there.
- Tests run on GitHub Actions: logic tests, an engine test that renders sample RAW photos on the runner's GPU and checks the numbers (including AI Denoise and
  Heal), and UI tests on a simulator (`uitest.yml`, which can pretend the phone has a given amount of memory).
- AI models (depth, scene, Heal, AI Denoise) are fetched at pinned revisions with SHA-256 checks and converted or compiled in CI.
- `CLAUDE.md` and `AGENTS.md` are the working notes for AI-assisted sessions; `PRODUCT-BRIEF.md` is the product direction.

## Layout

- `Sources/Edit/Engine.swift`, `Graph.swift`, `Kernels.metal` – the image pipeline: RAW decode, the fused develop pass, crop / geometry, export.
- `Sources/Edit/Masks.swift`, `Sky.swift` – mask rendering, AI masks, local adjustments.
- `Sources/Edit/Heal.swift`, `Denoise.swift` – the inpainting and denoise models and how they run.
- `Sources/Edit/ColorCube.swift`, `Curves.swift` – curves, colour mixer and grading baked into one 3D LUT.
- `Sources/Edit/EditSettings.swift` – the adjustment model, masks, presets.
- `Sources/Edit/EditorViewModel.swift` – live preview, undo / redo, mask editing.
- `Sources/HeavyWork.swift`, `MemoryBudget.swift`, `BlackBox.swift`, `Diagnostics.swift` – the job coordinator, memory limits and the flight recorder.
- `Sources/Library` – import, sidecar edit storage, thumbnails, ratings, user presets.
- `Sources/Views` – SwiftUI library grid, editor, panels, curve editor, mask and Heal overlays.

## Not included (by choice)

Lens-profile corrections, generative fill or extend, cloud sync.
