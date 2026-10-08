# Lumen – project notes for Claude

Read this first. It records what exists, how it's built and shipped, and what to do next.

## Housekeeping (do this every session)
- Before finishing any session, update the **Status**, **Things to verify** and **Troubleshooting** sections below with what changed or was learned, then commit and push (`git add -A; git commit; git push`) so the next session starts current.
- Keep this file factual and short; remove items once they're fixed or verified. Never put passwords, tokens or Apple ID credentials in it.

## What this is
**Lumen**: a free, subscription-less Lightroom/Photomator-style RAW photo editor for iPhone, written in native Swift/SwiftUI on Core Image (custom Metal kernels) + Vision. The owner (not a developer, "not techy") is sick of subscriptions and wants a Lightroom-Premium-level app with all the sliders, masks and an intuitive design, sideloaded onto their own phone.

## The user and their setup
- Windows 11 PC, **no Mac** (may rent one later but doesn't want to spend until needed). Cannot compile iOS code locally; all builds happen on GitHub Actions.
- Phone: **iPhone 17 Pro Max** (iOS 27). Camera: **Sony A9** (ARW RAW). Shoots ProRAW on the phone too.
- Explicitly NOT wanted: healing/spot removal, lens corrections, Upright/geometry, AI denoise, Generative Remove, cloud sync.
- Explain things in plain steps. Never ask them to run terminal commands; do it for them. They must type their own passwords / 2FA codes and approve GitHub device-code logins themselves.
- Priorities they stated: smooth editing (Lightroom-like), a Lightroom-mobile style UI that wastes no screen space, masks that really work (subject, sky, luminance range, colour range, brush, gradients, add/subtract/intersect), no red overlay once a mask is set up.

## Where things are
- Local project: `C:\Users\pc user\Downloads\GP work\Lumen`
- Latest built IPA (downloaded copy): `C:\Users\pc user\Downloads\GP work\LumenIPA\Lumen.ipa`
- GitHub repo (private): https://github.com/AngeloP46/lumen  (account **AngeloP46**)
- GitHub CLI is at `C:\Program Files\GitHub CLI\gh.exe` (NOT on PATH in the Bash tool; call it by full path). Logged in as AngeloP46; plain `git push` works.
- Inspiration: https://github.com/storytold/lightcraft (Rust, MIT/Apache). Ideas borrowed (not code): single fused per-pixel pass, cached blur "layers" for local contrast, log-luminance tone controls, OkLab colour work, mask planes summed per pixel.

## How to build and ship (the loop)
1. Edit Swift/Metal in `Sources/`.
2. `git add -A; git commit; git push` → **Build IPA** workflow (`.github/workflows/build.yml`, macos-15, XcodeGen + xcodebuild, unsigned, ~40 s).
3. `gh run list --repo AngeloP46/lumen`, `gh run view <id> --log-failed`.
4. Download: `gh run download <id> --repo AngeloP46/lumen --name Lumen-ipa --dir "C:\Users\pc user\Downloads\GP work\LumenIPA"`.
5. Install with **Sideloadly** (installed on the PC; iPhone `ParodiA` detected over USB). User drags `Lumen.ipa` in, enters their free Apple ID, clicks Start, types password/2FA themselves. Trust under Settings → General → VPN & Device Management. Developer Mode must be on.
6. Free Apple ID signing expires after **7 days**; re-run Sideloadly with the same IPA to renew (max 3 sideloaded apps).

No Xcode project is committed: `project.yml` (XcodeGen) generates it in CI. Metal needs `MTL_COMPILER_FLAGS=-fcikernel` and `MTLLINKER_FLAGS=-cikernel` (set in project.yml) so `Kernels.metal` becomes Core Image kernels in `default.metallib`. Bundle id `com.example.lumen`, iOS 17.0 target, Swift 5 mode.

## Testing without a Mac or device (very useful)
- **Engine test** (`.github/workflows/engine-test.yml`, runs on any push touching `Sources/Edit/**`): compiles the engine files + `Tests/engine/main.swift` as a macOS command-line tool on the runner's (paravirtual) Metal GPU, renders an A9 ARW and three JPEGs through ~40 edit cases and masks, uploads contact sheets as the `engine-renders` artifact. Download with `gh run download <id> --name engine-renders` and view the JPEGs. Also prints render timings and a Metal-texture orientation probe.
- **UI screenshots** (`.github/workflows/ui-test.yml`, runs on push to branch `v2`/manual): builds the app for the iPhone 16 Pro Max simulator, launches it with `-lumenDemo*` arguments (see `Sources/Demo.swift`) on the same sample photos and uploads screenshots as the `screenshots` artifact. Use this to check layout.
- Sample photos are fetched in CI (raw.pixls.us A9 ARW, Wikimedia JPEGs).

## Architecture (Sources/)
- `Edit/Kernels.metal`: all GPU kernels. `lumenMain`/`lumenMainLocal` = the fused develop pass (WB, exposure, dehaze, shadows/highlights/whites/blacks/contrast in log-luminance, clarity/texture/sharpen/NR from precomputed blur layers, highlight shoulder, vibrance/saturation in OkLab). `lumenFinish` = vignette + sRGB encode + grain (after crop). Plus mask kernels (linear, radial, luminance, colour, similarity, combine, finish, overlay) and `lumenAccum`.
- `Edit/Engine.swift`: `LumenGPU` (shared CIContext, extended-linear-P3 working space, RGBAh), `LumenKernels` (loads `default.metallib`), `ImageSource` (decoded image + analysis layers l1/l2/chroma + CPU stats grid; caches AI masks), `EditSession` (RAW via `CIRAWFilter`, others via CIImage; builds sources).
- `Edit/Graph.swift`: `develop(settings, source, geometry)` builds the lazy CI graph (develop kernel → crop/rotate → finish → 3D look LUT → linear). Also thumbnails/export.
- `Edit/Masks.swift`: masks = list of components (brush/linear/radial/subject/background/sky/luminance/colour) combined with add/subtract/intersect, invert, opacity. Each mask's slider offsets × mask image are summed into 5 "parameter planes" that the develop kernel reads. Subject = Vision foreground mask; `Sky.swift` = classical region-growing sky finder.
- `Edit/ColorCube.swift`: curves + HSL mixer (OkLab) + 3-way grading + B&W baked into a 48³ LUT.
- `Edit/EditSettings.swift`: Codable model (JSON sidecar per photo; old sidecars are migrated by `LibraryStore.settings(for:)`).
- `Edit/EditorViewModel.swift`: builds the graph on every change and hands it to the Metal canvas; undo/redo; debounced saving; mask editing state; histogram (throttled); export.
- `Views/CanvasView.swift`: `MTKView` that draws the CIImage directly (no CPU read-back) with pinch/pan transform (`ViewXform`), flipped for Metal textures.
- `Views/EditorView.swift` + `Panels.swift` + `Components.swift`: Lightroom-mobile layout: slim top bar, full-height photo, one-slider "param strip" panels (`ParamStrip`/`ScrubSlider`), tool strip at the bottom. `MaskViews.swift`: mask panel (type grid, Shape/Adjust tabs, range bar for luminance, colour samples), on-photo handles. Red overlay shows only on the Shape tab (eye button toggles; Adjust tab hides it, eye peeks).
- `Library/LibraryStore.swift`: imports from Photos (fetches RAW original resource, falls back to `PickedFile` transferable) or Files; thumbnails via the same engine.

## Status (2026-10-08, branch `v2`)
- Engine v2 verified on CI renders (A9 ARW decode works; tone/colour/HSL/curves/B&W/crop/masks look right; subject mask works; sky mask is heuristic). Preview render ≈ 10–25 ms on the CI GPU.
- New UI, mask UI, Photos-import fix (picker moved out of the Menu) are built and compile; see "Things to verify" for what still needs the real phone.

## Things to verify on the phone
- Smoothness while dragging sliders; zoom/pan crispness; first-open time of a 24 MP ARW (preview source build ≈ 1–2 s).
- Photos import (needs the permission prompt on first use); ProRAW DNG and ARW from Files.
- Canvas orientation/colours on the real display (Metal texture flip is unit-tested on macOS only).
- Sky mask quality on varied skies; subject mask first-run delay.
- `CIRAWFilter` `extendedDynamicRangeAmount = 1.0` plus our highlight shoulder: check default look vs Apple Photos and highlight recovery.
- Temperature/tint strength and direction; sharpen/clarity strength at 100% (no 100% zoom yet).

## Roadmap ideas
Full-resolution 100% zoom tile, draggable crop corners, filmstrip/next-prev in editor, batch sync, before/after split, AI sky model via CoreML, lens-free vignette correction, histogram-based tone-curve backdrop, Metal tile export for 48 MP ProRAW.
