# Lumen

A free, subscription-less RAW photo editor for iPhone, built on Apple's Core Image RAW engine.
Edits Sony A9 `.ARW` and iPhone ProRAW `.DNG` (plus JPEG/HEIC) non-destructively.

## Features

- **Library**: import from Photos (pulls the RAW/ProRAW original) or Files / SD card; star ratings, pick/reject flags, filters.
- **Light / Color / Effects / Detail**: exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, vibrance, saturation, texture, clarity, dehaze, vignette, grain, sharpening, noise reduction.
- **Tone curve**: RGB + per-channel, tap to add points, drag to bend.
- **Color mixer**: hue / saturation / luminance for 8 colour ranges.
- **Color grading**: shadows / midtones / highlights, blending and balance.
- **Masks**: brush, linear, radial, subject, background (on-device AI via Vision), luminance range, colour range. Each mask has its own exposure/contrast/highlights/shadows/temperature/tint/saturation/clarity/sharpening and can be inverted.
- **Crop**: aspect ratios, straighten, zoom, drag to reposition, 90° rotation.
- **Presets**: built-in + save your own, with live thumbnails.
- Histogram, pinch-zoom, hold the eye icon to compare with the original, undo/redo, copy/paste edits, export JPEG/HEIC/TIFF.

## Get it on your iPhone (no Mac needed)

Every push to `main` builds Lumen and publishes it as a [SideStore](https://sidestore.io) source:

```
https://github.com/AngeloP46/lumen/releases/download/sidestore/source.json
```

1. Install SideStore once from a PC with [iloader](https://github.com/nab138/iloader) (needs iTunes, a cable and your Apple ID), plus **LocalDevVPN** from the App Store.
2. In SideStore: **Sources → +**, paste the URL above, then install Lumen from it. New builds show up as updates.
3. Free Apple ID: apps expire after 7 days. Open SideStore (LocalDevVPN connected) and tap **Refresh All** once a week; this works anywhere with internet, no PC needed.

Other branches still upload a `Lumen-ipa` artifact (Actions tab) that you can sideload by hand with Sideloadly.

## Getting A9 files onto the phone

- SD card reader / A9 over USB-C (mass storage) → Files app → Lumen **+ → From Files**.
- Or Sony's Creators' App to transfer to Photos (use RAW transfer), then **+ → From Photos**.

## Layout

- `Sources/Edit/EditSession.swift` – image pipeline (CIRAWFilter + Core Image), geometry.
- `Sources/Edit/Masks.swift` – mask rendering and local adjustments.
- `Sources/Edit/ColorCube.swift`, `Curves.swift` – curves + HSL + grading baked into one 3D LUT.
- `Sources/Edit/EditSettings.swift` – the adjustment model, masks, presets.
- `Sources/Edit/EditorViewModel.swift` – live preview, undo/redo, mask editing.
- `Sources/Library` – import (Photos / Files), sidecar edit storage, thumbnails, ratings, user presets.
- `Sources/Views` – SwiftUI library grid, editor, panels, curve editor, mask overlay.

## Not included (by choice)

Healing / spot removal, lens corrections, Upright, AI denoise, Generative Remove, cloud sync.
