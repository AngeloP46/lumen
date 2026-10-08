# Lumen – project notes for Claude

Read this first. It records what exists, how it's built and shipped, and what to do next.

## What this is
**Lumen**: a free, subscription-less Lightroom/Photomator-style RAW photo editor for iPhone, written in native Swift/SwiftUI on Core Image + Vision. The owner (not a developer, "not techy") is sick of subscriptions and wants a Lightroom-Premium-level app with all the sliders, masks and an intuitive design, sideloaded onto their own phone.

## The user and their setup
- Windows 11 PC, **no Mac** (may rent one later but doesn't want to spend until needed). Cannot compile iOS code locally; all builds happen on GitHub Actions.
- Phone: **iPhone 17 Pro Max** (iOS 27). Camera: **Sony A9** (ARW RAW). Shoots ProRAW on the phone too.
- Explicitly NOT wanted: healing/spot removal, lens corrections, Upright/geometry, AI denoise, Generative Remove, cloud sync.
- Explain things in plain steps. Never ask them to run terminal commands; do it for them. They must type their own passwords / 2FA codes and approve GitHub device-code logins themselves.

## Where things are
- Local project: `C:\Users\pc user\Downloads\GP work\Lumen`
- Latest built IPA (downloaded copy): `C:\Users\pc user\Downloads\GP work\LumenIPA\Lumen.ipa`
- GitHub repo (private): https://github.com/AngeloP46/lumen  (account **AngeloP46**; the user also mentioned `angelo2890-ux` but said they don't care which)
- GitHub CLI is installed at `C:\Program Files\GitHub CLI\gh.exe` (NOT on PATH in the Bash tool; call it by full path or via PowerShell). It is logged in as AngeloP46 with `repo` + `workflow` scopes and `gh auth setup-git` has been run, so plain `git push` works.
- Inspiration/reference only: https://github.com/storytold/lightcraft (Rust Lightroom clone, MIT/Apache; desktop only, no iOS). Not used as a dependency.

## How to build and ship (the loop)
1. Edit Swift in `Sources/`.
2. `git add -A; git commit; git push` → the **Build IPA** workflow (`.github/workflows/build.yml`, macos-15 runner, XcodeGen + xcodebuild, unsigned) runs automatically (~5 min).
3. Watch/inspect: `gh run list --repo AngeloP46/lumen`, `gh run watch <id> --repo AngeloP46/lumen --exit-status`, failures: `gh run view <id> --log-failed`.
4. Download: `gh run download <id> --repo AngeloP46/lumen --name Lumen-ipa --dir "C:\Users\pc user\Downloads\GP work\LumenIPA"`.
5. Install on phone with **Sideloadly** (already installed on the PC; iTunes + Apple Mobile Device Support installed so the iPhone `ParodiA` is detected over USB). User drags `Lumen.ipa` in, enters their free Apple ID, clicks Start, types password/2FA themselves. Then iPhone Settings → General → VPN & Device Management → Trust. Developer Mode must be on.
6. Free Apple ID signing expires after **7 days**; re-run Sideloadly with the same IPA to renew (max 3 sideloaded apps).

No Xcode project is committed: `project.yml` (XcodeGen) generates it in CI. `Config/Info.plist` is generated. Bundle id `com.example.lumen`, iOS 17.0 deployment target, Swift 5 mode.

## Troubleshooting seen so far
- `gh auth login --web` needs the user to approve a one-time device code in the browser pane; run it in the background and read the code from the output file. Pushing `.github/workflows` needed `gh auth refresh -s workflow`.
- Sideloadly "IPC fail / no devices": Apple Mobile Device Support missing (fixed). "getaddrinfo failed for gsa.apple.com": transient DNS blip when the phone is plugged in (retry; DNS was fine afterwards).

## Architecture (Sources/)
- `Edit/EditSession.swift`: the render pipeline. RAW via `CIRAWFilter` (handles Sony ARW + ProRAW/DNG), others via CIImage. Order: base (RAW decode, exposure, WB) → masks (local adjusts, linear space) → gamma → tone curve (blacks/shadows/highlights/whites) → dehaze → contrast/saturation/vibrance → colour LUT (curves+HSL+grading) → texture/clarity → NR/sharpen → grain/vignette → back to linear → geometry (rotate/straighten/crop). Preview renders at 2200px; export at full size.
- `Edit/Masks.swift`: mask types brush/linear/radial/subject/background (Vision `VNGenerateForegroundInstanceMaskRequest`)/luminance/colour. Masks are opaque grey CIImages blended with `CIBlendWithMask`. Mask coordinates are normalised, top-left origin, in *pre-geometry* image space; mask-editing renders with geometry skipped.
- `Edit/ColorCube.swift` + `Curves.swift`: curves, 8-band HSL mixer and 3-way colour grading baked into one 48³ LUT (cached by `LookKey`).
- `Edit/EditSettings.swift`: Codable model for every adjustment, masks, presets. Saved as per-photo JSON sidecars (old sidecars fail to decode and fall back to defaults when fields change).
- `Edit/EditorViewModel.swift`: serial render queue with generation counter (drops stale renders), undo/redo, histogram, mask editing, preset thumbnails, export.
- `Library/LibraryStore.swift`: imports from Photos (fetches RAW original resource) or Files; copies into Documents/Library; ratings/flags; user presets; thumbnails.
- `Views/`: `LibraryView`, `EditorView` (bottom tool strip, pinch-zoom, hold-eye to compare), `Panels`, `CurvePanel`, `MaskViews` (panel + on-photo overlay/handles), `Components`.

## Status (2026-10-08)
- Full feature set written; **CI build succeeded on the first run**; the IPA installed on the user's iPhone via Sideloadly.
- **Not yet verified on a real device**: nothing has been visually tested. Next step is the user trying it with a real A9 .ARW and a ProRAW and reporting back.

## Things to verify / likely tuning
- Temperature/tint slider direction and strength (RAW path scales `neutralTemperature`; JPEG path uses `CITemperatureAndTint`).
- Whether `CIRAWFilter` actually decodes A9 ARW and what `extendedDynamicRangeAmount = 0` does to highlights.
- Performance of 24MP A9 files (preview render time, subject-mask first-run delay, 48³ LUT rebuild while dragging curve/HSL).
- Mask handle placement/feel, brush size, crop drag sensitivity (heuristic), curve editor touch targets.
- Sharpen/clarity radii are scaled for preview vs export; check they look the same.
- Sky mask is not implemented (no Apple API); use luminance/colour/linear instead, or add a CoreML model.

## Roadmap ideas
Colour wheels for grading, draggable crop corners, filmstrip/next-prev in editor, batch sync of edits, auto-adjust, tone-curve histogram backdrop, before/after split view, AI sky mask, better crop UI, Metal custom kernels if Core Image chains get slow. A rented Mac (or a cheap used Mac mini) would allow simulator debugging, but is not required.
