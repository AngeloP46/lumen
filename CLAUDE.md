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
- GitHub repo (**public since 2026-10-09**, so Actions runners are free; it was private and ran out of macOS minutes): https://github.com/AngeloP46/lumen  (account **AngeloP46**). Because it is public never commit secrets or personal data, and commit with the GitHub no-reply address (`164361042+AngeloP46@users.noreply.github.com`, already set in the repo's git config). Older commits show the owner's real email.
- GitHub CLI is at `C:\Program Files\GitHub CLI\gh.exe` (NOT on PATH in the Bash tool; call it by full path). Logged in as AngeloP46; plain `git push` works.
- Inspiration: https://github.com/storytold/lightcraft (Rust, MIT/Apache). Ideas borrowed (not code): single fused per-pixel pass, cached blur "layers" for local contrast, log-luminance tone controls, OkLab colour work, mask planes summed per pixel.

## How to build and ship (the loop)
1. Edit Swift/Metal in `Sources/`.
2. `git add -A; git commit; git push` → **Build IPA** workflow (`.github/workflows/build.yml`, macos-15, XcodeGen + xcodebuild, unsigned, ~40 s).
3. `gh run list --repo AngeloP46/lumen`, `gh run view <id> --log-failed`.
4. Download: `gh run download <id> --repo AngeloP46/lumen --name Lumen-ipa --dir "C:\Users\pc user\Downloads\GP work\LumenIPA"`.
5. **Main builds reach the phone through SideStore** (set up 2026-10-09; the owner chose it over a paid developer account and won't pay for one). The Build IPA workflow's last step (main only) runs `sidestore/make_source.py` and uploads `Lumen-<run>.ipa` + `source.json` to the fixed `sidestore` release (keeps the newest 3 IPAs). The owner added `https://github.com/AngeloP46/lumen/releases/download/sidestore/source.json` in SideStore and updates Lumen from there, anywhere, no PC. SideStore rejects a download unless bundle id, version, build, size, sha256 and the `NS*UsageDescription` keys match the feed, so the script reads them all from the IPA; `CFBundleShortVersionString` = `0.1.<run number>` and `CFBundleVersion` = `<run number>` (project.yml + `CURRENT_PROJECT_VERSION` in build.yml). If you add an entitlement or a privacy key, nothing else needs changing.
6. Free Apple ID signing expires after **7 days**: the owner opens SideStore with LocalDevVPN connected and taps Refresh All (max 3 sideloaded apps incl. SideStore). iloader (`%LOCALAPPDATA%\iloader\iloader.exe`) reinstalls SideStore over USB if it ever breaks (e.g. after a phone reset). Sideloadly is still installed as a USB fallback for branch builds.

No Xcode project is committed: `project.yml` (XcodeGen) generates it in CI. Metal needs `MTL_COMPILER_FLAGS=-fcikernel` and `MTLLINKER_FLAGS=-cikernel` (set in project.yml) so `Kernels.metal` becomes Core Image kernels in `default.metallib`. Bundle id `com.example.lumen`, iOS 18.0 target (needed for `UIGestureRecognizerRepresentable`), Swift 5 mode.

## Testing without a Mac or device (very useful)
- **Engine test** (`.github/workflows/engine-test.yml`, runs on any push touching `Sources/Edit/**`): compiles the engine files + `Tests/engine/main.swift` as a macOS command-line tool on the runner's (paravirtual) Metal GPU, renders an A9 ARW and three JPEGs through ~40 edit cases and masks, uploads contact sheets as the `engine-renders` artifact. Download with `gh run download <id> --name engine-renders` and view the JPEGs. Also prints render timings and a Metal-texture orientation probe.
- **UI screenshots** (`.github/workflows/ui-test.yml`, manual only now: it cost ~7 macOS minutes per push): builds the app for the iPhone 16 Pro Max simulator, launches it with `-lumenDemo*` arguments (see `Sources/Demo.swift`) on the same sample photos and uploads screenshots as the `screenshots` artifact. Use this to check layout.
- **UI tests** (`Tests/ui/LumenUITests.swift`, `.github/workflows/uitest.yml`, runs on pushes to `v4`/`v5` or manually with `gh workflow run uitest.yml --repo AngeloP46/lumen --ref <branch>`, optional `-f only=<testMethod>`; the whole suite takes ~15 min and prints nothing until it ends): XCUITest drives the real app in the simulator with real touches (double-tap slider reset, hold-to-compare until release, drag/close the panel, pinch/double-tap zoom, tap to hide panels, swipe to next photo, panels never overlap the tool bar). Elements have accessibility identifiers (`slider-<name>`, `reset-<name>`, `panel`, `panel-handle`, `photo`, `tool-<name>`); the app writes an event log in demo mode (`-lumenDemoLog`). Add a test whenever you fix a gesture bug.
- Sample photos are fetched in CI (raw.pixls.us A9 ARW, Wikimedia JPEGs).

## Architecture (Sources/)
- `Edit/Kernels.metal`: all GPU kernels. `lumenMain`/`lumenMainLocal` = the fused develop pass (WB, exposure, dehaze, shadows/highlights/whites/blacks/contrast in log-luminance, clarity/texture/sharpen/NR from precomputed blur layers, highlight shoulder, vibrance/saturation in OkLab). `lumenFinish` = vignette + sRGB encode + grain (after crop). Plus mask kernels (linear, radial, luminance, colour, similarity, combine, finish, overlay) and `lumenAccum`.
- `Edit/Engine.swift`: `LumenGPU` (shared CIContext, extended-linear-P3 working space, RGBAh), `LumenKernels` (loads `default.metallib`), `ImageSource` (decoded image + analysis layers l1/l2/chroma + CPU stats grid; caches AI masks), `EditSession` (RAW via `CIRAWFilter`, others via CIImage; builds sources).
- `Edit/Graph.swift`: `develop(settings, source, geometry)` builds the lazy CI graph (develop kernel → crop/rotate → finish → 3D look LUT → linear). Also thumbnails/export.
- `Edit/Masks.swift`: masks = list of components (brush/linear/radial/subject/background/sky/luminance/colour) combined with add/subtract/intersect, invert, opacity. Each mask's slider offsets × mask image are summed into 5 "parameter planes" that the develop kernel reads. Subject = Vision foreground mask; `Sky.swift` = classical region-growing sky finder.
- `Edit/ColorCube.swift`: curves + HSL mixer (OkLab) + 3-way grading + B&W baked into a 48³ LUT.
- `Edit/EditSettings.swift`: Codable model (JSON sidecar per photo; old sidecars are migrated by `LibraryStore.settings(for:)`).
- `Edit/EditorViewModel.swift`: builds the graph on every change and hands it to the Metal canvas; undo/redo; debounced saving; mask editing state; histogram (throttled); export.
- `Views/CanvasView.swift`: `MTKView` that draws the CIImage directly (no CPU read-back) with pinch/pan transform (`ViewXform`). It redraws whenever its drawable changes size (`drawableSizeWillChange`); before 2026-10-09 the old frame stayed on screen stretched/misplaced after a tool switch. In demo mode every draw is logged (`draw canvas WxH view WxH`) and a UI test checks the last one matches.
- `Views/EditorView.swift`: full-height photo, round floating buttons on top (back/undo/redo/hold-to-compare/menu), 8 fixed tools in a bottom bar (Presets, Crop, Light, Color, Grade, Curve, Detail, Masks). `panelPlan` gives the everyday tools (all but Crop and the mask Shape tab) one shared height (`sharesHeight`, at most 400 pt) whenever the photo leaves room, so switching tools never moves the photo; otherwise it gives the panel whatever height the photo does not need (the user can also drag the grab handle: up = more controls, down = more photo, all the way down closes it, double-tap resets; content is clipped so it can never spill over the tool bar): with room for >= 4 whole rows it shows **every slider as a list** (`ParamPanel` list layout), otherwise **one slider at a time** (strip). More menu has Sliders: Automatic / One at a time / Full list. Tap the photo to hide all chrome; swipe the panel's grabber down to close the panel; press-and-hold the photo to see the original.
- `Views/Panels.swift` + `Components.swift`: panels built from `ParamItem`s (`ParamPanel`, `ScrubSlider` = relative drag, drag away from the track for finer steps, double-tap reset, value bubble; a drag only belongs to the slider once its first movement is sideways, so vertical swipes that start on a slider scroll the list). Light panel HDR pill = HDR on/off only (the HDR range slider was removed at the owner's request; `hdrStops` keeps its default of 2 stops). Grade = three `ColorWheel`s (hue/sat puck) + luminance sliders + Blend/Balance. Color has B&W, Reset and a colour-mix mode (`HSLPanel`: 8 swatches + Hue/Sat/Lum). `CurvePanel` shows the live histogram behind the curve and has curve presets.
- `Views/CropViews.swift`: Lightroom-style crop. The crop frame is stored as fractions (`cropL/T/R/B`) of the straightened picture; while the Crop tool is open the whole straightened picture is shown with a draggable frame (corners/edges, drag inside to move, aspect lock via `cropAspect`, 0 = free). Angle slider = straighten.
- Gestures (all in `EditorView`): two fingers pinch-zoom around the point between them and pan with it at the same time, over every overlay, in every tool but Crop (`Views/PhotoGestures.swift`: `TwoFingerWatcher` only watches touches and never claims them, so it can't block other gestures; SwiftUI's MagnifyGesture stays as a fallback). One finger pans a zoomed photo wherever nothing else takes the touch (mask handles, brush and crop frame do; the hand button still frees one finger in Masks). In Masks the photo can be zoomed out to 0.3x and moved, and handles can be dragged past the photo's edges (`ViewXform.unclamped`), so gradients/radials can be much bigger than the picture; leaving Masks returns to fit, and elsewhere a pinch below fit springs back. Double-tap zooms to that spot, press-and-hold shows the original until release or until the finger starts moving (`@GestureState holding`), tap hides the panels. There is deliberately no eye button.
- Resets: tap a slider's value/arrow (or double-tap the slider, or long-press a strip chip) resets it; Reset pills reset a group; HSL/curve/grading/mask panels have their own resets.
- 100% view: pinching past ~1.4x makes `EditorViewModel` build a second, full-resolution `ImageSource` (max 6000 px long edge, shared AI masks) and render from it; it is released a few seconds after zooming back out. Swipe left/right on the photo (or More menu) moves to the next/previous photo.
- `Views/MaskViews.swift`: mask panel (type grid, Shape/Adjust tabs, components with add/subtract/intersect, luminance range bar with histogram, colour samples), on-photo handles. Red overlay shows only on the Shape tab (eye button toggles; the Adjust tab hides it, eye peeks).
- `Library/LibraryStore.swift`: imports from Photos (fetches RAW original resource, falls back to `PickedFile` transferable) or Files; thumbnails via the same engine.

## Status (2026-10-09: overnight work merged to `main`; latest IPA is `C:\Users\pc user\Downloads\GP work\LumenIPA\Lumen.ipa`)
- Done and verified in CI: fused Metal engine, Lightroom-mobile UI (floating buttons, 8 tools, adaptive/draggable panel, list or one-slider layout), colour wheels, HSL swatches, curve with histogram, masks (subject/sky/background/brush/linear/radial/luminance/colour, add/subtract/intersect, overlay only on the Shape tab), crop frame editor, 100% zoom, swipe/next-prev photo, per-slider and per-group resets, hold-to-compare, anchored pinch zoom. 24 automated UI tests + the engine render/maths checks all pass in CI. Added 2026-10-09 (merged from the overnight branches, verified together in CI): HDR mode (Light panel HDR pill + HDR range slider, EDR canvas, HDR export labels, gain-map decode, histogram HDR bar), a separate Export button with a short More menu, bug fixes (empty-extent divisions, Photos import counts, orphan thumbnails), and many new engine/UI tests.
- NOT checkable in CI, so unverified: Photos import from the real library, real-finger feel, real-display colour vs Apple Photos, ProRAW DNG, subject-mask speed on the phone (Vision is too slow in the simulator).
- The owner tests on the phone and reports bugs/feel issues in chat. Fix them, add a UI test for any gesture/layout bug, push, rebuild, and replace `LumenIPA\Lumen.ipa` (download the Build IPA artifact to a scratch folder, then `cp -f` it over the old file; do not use `rm` or `bash -c` with timeouts, the safety check blocks them).

## How to continue in a new session
1. Open the session with working directory `C:\Users\pc user\Downloads\GP work\Lumen` and tell it to read CLAUDE.md first.
2. Work on a new branch (`git checkout -b v5`; CI runs on every branch). When green: `git checkout main; git merge --ff-only v5; git push origin main`. The simulator workflows only run on the branches listed in their `branches:` lines (`.github/workflows/ui-test.yml`, `uitest.yml`); edit those lists for a new branch name.
3. Watch CI with `gh run list --repo AngeloP46/lumen --branch <branch>`; fetch artifacts with `gh run download <id> --name <artifact>` (engine-renders, screenshots, uitest, Lumen-ipa) and look at the images.
4. Update this file before finishing.

## Things to verify on the phone
- Smoothness while dragging sliders; zoom/pan crispness; first-open time of a 24 MP ARW (preview source build ~1-2 s) and the "Loading full resolution" delay when zooming in.
- Photos import (permission prompt on first use); ProRAW DNG and ARW from Files.
- `CIRAWFilter` `extendedDynamicRangeAmount = 1.0` plus our highlight shoulder: default look vs Apple Photos, highlight recovery.
- Temperature/tint strength and direction; sharpen/clarity strength at 100%.
- Colour-wheel feel, curve touch targets, mask handle sizes, panel drag feel.

## Roadmap ideas
Batch sync/copy-paste to many photos, before/after split, AI sky model via CoreML, lens-free vignette correction, histogram-based tone-curve backdrop, Metal tile export for 48 MP ProRAW.

## Overnight loops and the CI courier (2026-10-09; finished)
- Three unattended Claude loops worked on `night/bugs`, `night/tests`, `night/hdr` (worktrees `C:\Users\pc user\Downloads\lumen-night-*`), with a Python courier (`C:\Users\pc user\Downloads\lumen-night\ci_courier.py`) pushing their branches and returning real CI results. All three finished; their work was merged and verified together on `integrate/night`, then `main`. Full decision log: `lumen-night\PROGRESS.md` (read it before restarting the loops; `Start Lumen night.cmd` / `Stop Lumen night.cmd` start/stop them).
- `engine-test.yml` / `uitest.yml` propagate the real exit code (the old lldb fallback hid failures), download samples with `.github/ci/get.sh`, and cancel superseded runs.
- The private repo ran out of free macOS minutes (they bill x10), so the repo was made public; public repos get free runners. The courier's `billingBlocked` state is stale and its scheduled task ends 2026-10-09 11:00.
- Open owner questions from the bugs loop (see `lumen-night-bugs\PROGRESS.md`): crop rotate buttons reset the crop; an undecodable file leaves a spinning thumbnail; `index.json` strict-decode recovery; Background mask when there is no subject. One blocked item: ScrubSlider cancelled drag (needs a UI test).
