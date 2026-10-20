# Lumen – project notes for Claude

## Two builds: every change goes to both (Angelo, 15 October)
- **main** = Angelo's personal app on SideStore: everything free, no paywall, no watermark, no StoreKit.
- **sandbox** branch (PC folder `Lumen-Sandbox`) = the same app developed as a real **App Store product**: paid Pro features, paywall, trial, watermark on free exports, StoreKit, privacy policy. Read its `SANDBOX-BRIEF.md`, `HANDOFF.md` and `SANDBOX-LOG.md` before touching it.
- Every bug fix and shared editor feature ships to **both**: release it on main first (branch → PR → merge), then port the same change to `sandbox` (branch from `sandbox`, PR into `sandbox`, run its compile check with APP_STORE OFF/ON), and log it in `SANDBOX-LOG.md`.
- When porting a NEW feature, keep or add the sandbox's Pro gating where it fits, and ask Angelo if it is unclear whether it should be free or Pro. Never copy paywall/StoreKit/watermark code or the APP_STORE flag into main, and never push to main from `Lumen-Sandbox`.
- Tell Angelo which of the two each change has reached.
- App Store pricing, Free vs Pro, claims and the marketing plan: `MARKETING.md` on the sandbox branch (`Lumen-Sandbox\MARKETING.md`). Keep it out of main.

## AI Denoise (0.1.360, 20 Oct; owner asked for it)
- Model: **SCUNet** colour real-noise (cszn/SCUNet, Apache-2.0), run on the **GPU** (`.cpuAndGPU`; CI sets
  `LUMEN_DENOISE_UNITS=cpu`). Weights pinned: HF `WAS/was-node-suite-weights` revision dcc864ea…, SHA-256 fa78899b…
  (`fetch.py`). Converted in CI to Core ML, float16, 512 x 512 tiles (`build-denoise.sh`, cached; on failure an empty
  `Denoise.mlmodelc` keeps the project building). `scunet.py`: the shifted-window mask is built in NumPy.
- 20 Oct history: SCUNet on the Neural Engine (0.1.371) never reached 25 % of 24 MP in 100 s (attention layers don't
  suit the ANE) and iOS closed Lumen once (that build also loaded the GPU copy for a probe). NAFNet-SIDD-width32
  (0.1.381, #60) was quick on the ANE but wrecked bright tiles (channel-attention sum ~200,000 > float16's 65,504; the
  CI Mac runs on the CPU in full precision and can't show it) and even fixed (#62: 8 x 8 block mean) left half the
  noise (SIDD-only training). Owner: one model, good and quick, use the chips to the full -> SCUNet on the GPU (#63).
- Speed (owner, 20 Oct: good image, wants it faster). 0.1.388 on the phone: 84 s for 24 MP = load 10.3 s + first tile
  10.4 s (GPU setup) + 0.50 s/tile; memory hit 2.75 GB while loading. #65: the shifted-window mask is two small
  broadcast parts (was 89 M stored values; identical output, 24 % faster on a PC CPU), GPU float16 sums
  (`allowLowPrecisionAccumulationOnGPU`), and the model is loaded + run once on a blank tile when Detail opens
  (`detailToolChanged`, `warmDenoise`), kept while Detail is open, released 30 s after leaving it or on a memory
  warning. Tile prep is negligible (~1 s of 84), so pipelining would not help. NAFNet on the ANE did 0.08 s/tile.
- **Measured 0.1.394 (owner, 20 Oct): 57 s for 24 MP** (median 0.42 s/tile, first tile 0.4 s after Detail's warm-up
  of 2.7 s, peak 1.9 GB, no memory warnings, 0 tiles redone). Owner: "results were very good". Next idea to try:
  1024 px tiles (overlap work 31 % -> 14 %, estimate ~45 s; check memory).
- 21 Oct (#68): tiles keep 16 px of context (was 32; whole photo 60 dB from it, no step at any boundary): 117 tiles for
  24 MP. Results are raw 16-bit RGBA (`.rgba16`, read memory-mapped, no decode) plus a 2560 px copy that previews,
  thumbnails and the unhealed view use (before, every decode read the whole 24 MP PNG, ~400 MB spikes); old PNG
  results still read. The model is let go of straight after a clean and in the background (0.1.394: kept while Detail
  was open, ~600 MB, and iOS closed Lumen on return to the screen). Detail: AI Denoise is a pill in the actions row
  (like Light's Auto), Reset on the right; first tap cleans, then it switches AI Denoise off / on.
- 21 Oct (#70, owner's 48 MP ProRAW was closed by iOS at the start of a clean): the result is written to its file row
  of tiles by row of tiles (never held whole) and the preview copy averaged from those rows; the photo is read whole
  once when 4x its size is free (fastest; 24 MP = ~190 MB), else strip by strip from the RAW engine (diagnostics line
  "denoise reads the photo whole / in strips", strip read times in "denoise done"). The engine test forces strips
  (`denoiseForceStrips`); the memory step reads whole.
- 21 Oct (#72, owner's 48 MP ProRAW: clean worked, 221 tiles 110 s, but memory stayed ~2 GB after and Heal on top
  closed Lumen): the clean reads through its own `EditSession` (the photo's CIRAWFilter kept the full-size decode
  cached), and the small copy is 4096 px so the 100 % view never reads the whole result (it did, 372 MB, each time).
- 21 Oct (#74, the crash report named "100% view: building 4096 px copy", 214 -> 2851 MB, on a 48 MP ProRAW): the
  100 % view asks for free memory that grows with the photo past 24 MP (x MP/24: 48 MP gets 3072 px with > 2.6 GB
  free, never 4096); results with a small copy under 4096 px get one made once, row by row from the mapped file
  (`upgradePreview`); the job builds its small copy row by row too (`RowShrinker`; the whole-copy averaging held
  ~200 MB).
- 21 Oct edge-case review (two read-only reviews, #75): nothing starts a clean by itself any more (`ensureDenoise(start:)`:
  only the pill, or resuming one the background stopped; HDR switch / undo / presets / paste used to start a locked
  1-2 min clean); a clean asked for during AI masks waits for them; masks and the original copy wait for a clean.
  Hold-to-compare and the split's before half show the original (no heals, no AI Denoise: `makeSource(..., denoise:
  false)`). Paste (editor and library) and presets keep each photo's own AI Denoise. The pill switches back on at
  the strength it had. After a reload while zoomed the 100 % copy is rebuilt. Remove people frees memory first.
  Thumbnails and preset previews use a materialized small source (lazy ones re-ran the RAW engine per AI step).
  Export: a failed clean fails the export; photos > 30 MP get their AI masks from a 2560 px copy, scaled up. AI
  Denoise reads whole only with room for the RAW decode too (+50 MB/MP). Cleaned copies moved to Application
  Support (out of Files), excluded from backup, orphans swept at launch. Diagnostics: a 2 s heartbeat in the state
  file ("last seen HH:MM:SS using N MB"), background written at once, iOS's daily exit counts (MXMetricPayload),
  iOS reports capped at 20 KB. Open: paste keepOwn doesn't keep flips/transform or Heal's on/off (not fixed).
- Send diagnostics is compact (owner: too much to paste): a summary line per launch (version, times, how it ended,
  peak, AI Denoise runs, heals), then the log without routine memory samples (new highs and the last 8 lines before
  iOS closed Lumen are kept), repeated memory warnings folded into one line, iOS reports only with real content.
  After a crash the sheet's first button is "Share crash report": the last 3 closures only, each with the last step
  logged before it ("last step ... at HH:MM:SS; memory A -> B MB") and the 12 lines leading up to it (`crashes`).
  Opening a photo logs its steps ("photo ready (...)", "AI masks: working them out", "copy without heals").
- Every tile is checked against its input (finite, mean change < 0.1, < 0.5 % of samples off by > 0.3); a wrong one is
  redone on the CPU (`denoiseCPU`), else the photo's own pixels are kept. Diagnostics: "denoise model loaded in N s",
  "denoise first tiles a / b / c s", then "denoise done in N s: …, N redone on the CPU".
- WSL on the owner's PC crashes converting it (7 GB): don't retry locally; CI Macs swap and manage.
- App (`Sources/Edit/Denoise.swift`): `makeDenoised` cleans the full-size camera decode (no heals) once, tiles keep a
  32 px margin (no blending), one model on the GPU (no probe: two loaded copies cost memory), saves a
  16-bit PNG + json per photo and HDR mode in Library/denoise (`DenoiseStore`, removed with the photo). Every decode
  mixes it in by `EditSettings.aiDenoise` (0...100) with `withDenoise`, keeping highlights above the cleaned range.
  Export makes it if missing. Detail → AI Denoise button; full-screen lock `denoise-busy` with progress, time left and
  Cancel; the job stops if Lumen leaves the screen. The diagnostics log gets "denoise model loaded in N s" and
  "denoise first tiles a / b / c s, N tiles in all" straight away, then 25 % steps and "denoise done in N s: …".
- 24 MP ARW = 126 tiles of 512 px. Target < 30 s (owner's ideal).
- Send diagnostics now holds only the last 3 launches of the log and the 3 newest iOS reports from the past 3 days,
  as compact JSON (20 Oct: a report carried two days of log and every saved report).
- Engine test: Gaussian noise std 0.04 on cat.jpg: error 0.039 → 0.011, edges 95 % kept, 50 % mixes between, 0 = off,
  files removed; sheet `denoise.jpg`. Memory test step "AI denoise". Sandbox: Pro (`usesProFeatures`).

## Status — 19 October (overnight stability work; SideStore 0.1.311+)
- **Send diagnostics** (⋯ menu in editor and library, `Sources/Diagnostics.swift`): memory log in Library/Diagnostics
  (`Diagnostics.shared.note(...)` at photo open, heal steps, 100 % copy, export, memory warnings; a 2 s sampler logs big
  footprint moves; "previous run ended while Lumen was open" = iOS closed it) plus MetricKit crash/hang/disk-write JSON.
  One text file is shared on request; nothing is sent otherwise. Ask Angelo for it after any crash.
- **AI models** are `LoadedModel` holders (Engine.swift), not static lets: Heal's model is released 30 s after leaving
  Heal (at once when the photo closes), its CPU fallback straight after use, and depth/scene models on a memory warning
  or when the editor closes. `hasHealModel/hasSceneModel/hasDepthModel` only check for `coremldata.bin` (screens call
  them while drawing; an empty UI-test stand-in folder counts as missing).
- **Memory guard**: the 100 % copy is 4096 px with > 2 GB free, 3072 px with > 1.3 GB, else none
  (`Diagnostics.availableMB` = os_proc_available_memory). Heal and export drop the copies that can be remade first.
- **Heal memory**: the photo is decoded at 2x the model's resolution, only the square's part is rendered once into a
  small buffer, then the full decode is let go of before the model runs (was ~2.3 GB of a heal, now ~0.5 GB). The model's
  own prediction takes ~1.3 GB for a moment on the CI Mac's GPU, so the 1280 px model (~2.5x that) stays off; 800 px.
- **CI memory test**: engine-test step "Memory budget" (`--memory`) prints `MEMORY` lines per step (open, 100 % view,
  subject, heal with per-step probes, export) and fails over budget (measured 19 Oct + ~10 %; Mac numbers).
- **Heal at photo edges**: the hole is mirrored like `mirrorPadded`'s context (`withMirrors`), so a person at the edge is
  no longer painted back from their mirror image.
- **Lens Blur / AI masks after a heal** are worked out again from the healed photo (`reloadSource` carries masks over only
  when heals are unchanged); before, a removed person stayed "near" and left a sharp hole in the blur.
- **Remove people** finds more people: VNDetectHumanRectanglesRequest bodies that the whole-photo segmentation mostly
  missed get segmentation again on a crop, kept inside the body's box; 3072 px decode, up to 30 people. Whole-photo
  quarters were tried and merged neighbours into one (dropped). Shadow removal was tried and reverted: on dappled paving
  it smeared a large area and a neighbour's legs (bus test photo). Ideas only, not built.
- **Undo history** (`<id>.history.json`) is written 0.2 s after a save, when the app leaves the screen, on close and
  before deletes. A 2 s delay (0.1.288 only) lost it on a quick close (UI test `testOctoberEditorFixes`).
- **Code review fixes (0.1.311)**: exports keep EXIF/TIFF/GPS (date taken, camera, lens; orientation 1) — before, Photos
  dated exports the day they were made; sidecar migration keeps optional keys (Lens Blur mask/focus) and Lens Blur's
  scale conversion; damaged sidecars copied to `<id>.damaged.json`; batch export clears GPU caches per photo, keeps the
  screen awake, compares names ignoring case; old temp exports removed at launch; Files imports copy off the main
  thread with NSFileCoordinator; no undo/redo/swipe while a heal or export runs; stale 100 % copies dropped; Heal
  never stuck after a failed reload; AI masks re-run when the photo was re-decoded during analysis.
- **UI tests** use `tapTool(name)`, which scrolls the tool bar first: the full suite had been failing since the bar
  started scrolling (Masks/Heal/Presets off screen on the test iPhone). Releases skip the full suite, so check it.
- **Library grid** caches decoded thumbnails per photo and version (`LibraryStore.thumbnail(_:)`), 0.1.333.
- **Publishing gotcha**: the publish job skips a build when a newer commit is on main. Merging a docs- or tests-only PR
  while a code merge's build is running leaves SideStore on the old version (19 Oct: #41 skipped after docs #45).
  Merge docs/tests after the code build has published, or dispatch build.yml on main afterwards.
- 19 Oct SideStore versions: 0.1.274 diagnostics, 0.1.288 stability batch, 0.1.311 review fixes + undo fix,
  0.1.325 people finder, 0.1.329 heal memory, 0.1.333 thumbnails. All ported to sandbox (#40, #42, #43, #48, #49).
- **0.1.346 (#51)**: undo history loads in the background (`LibraryStore.loadHistory`; saves before it arrives pass
  no history so the store extends the file's own); brush masks cached by `ImageSource.RasterKey` (id + per-stroke
  summary), newest version per brush; Heal scales by the square's 99.5 % brightness x 1.25 (`brightEnd`) and keeps
  brighter highlights outside the hole; export steps report to `healProbe`. Export memory (~5.5 GB peak on the CI Mac,
  within budget) left as is: decoding into a buffer first gave the same peak and kept 1.8 GB more.
- All 19 Oct review items are done; nothing open from that review.

## Status — 15 October (Claude review of the 14 October work)
- Reviewed everything other AIs added since 70f1448: sound and safe overall.
- Fixed: undo/redo history moved out of the edits sidecar into `edits/<id>.history.json`, encoded and written on a serial background queue (`historyQueue`). The edits file is written synchronously and stays small (previously every 0.5 s save rewrote up to 200 snapshots on the main thread). Old `_undoHistory` in sidecars is still read and moves on the next save. Deletion and Heal-reference scans include the history file; deleting a photo without Heal patches no longer reads every other photo's edits. CI: `testHealDeletionPrivacy` has a 9th check for the separate file.
- Lens Blur (PR #7, SideStore 0.1.225, sandbox PR #10): `maskedLensBlur` = three `CIBokehBlur` disc layers (1/3, 2/3, full; disc = 1.6x the old radius) mixed by the blur map in `lumenLensCompose`; `lumenLensWeigh` feeds only background (premultiplied, so blur ÷ alpha = background-only average: no subject halo). `smoothLensBlur` (old CIMaskedVariableBlur) is the fallback. Amount scale: `LensBlurSettings.radiusScale` = 0.018 × 0.35 (new 100 = old 35), `startAmount` 23 (old 8), `scaleVersion` 2 (older saves divided by 0.35 on decode). Roll-off: `fullFrom` = focus + width, `rampStart` = fullFrom − max(0.2, 2 × width); the automatic ramp and the linked mask's Near feather both use it. Panel: no help paragraph / "Enable blur at 8"; preview-while-sliding is an icon (`lens-blur-preview`); amount/Near-Far/Refine are disabled only when depth is missing (busy analysis used to lock them: owner's "can't adjust after coming back"). Near/Far edit the linked mask without selecting it (`updateLensDepth`); Masks lists `userMasks` (never Lens Blur's mask). Tests: `testLensBlurAmountStillAdjustsAfterLeavingTool`, engine no-bleed / point-light / scale-conversion checks.
- Auto (PR #11, SideStore 0.1.236, sandbox PR #12): `Auto.swift` rewritten. `EditSession.autoKeys` = exposure, contrast, highlights, shadows, whites, blacks, vibrance, temperature, tint (Clarity no longer touched). Exposure meters Vision's subject (`ensureSubject`, coverage 3–70 %) else centre-weighted; high-key unclipped scenes darken at 40 %, scenes with bright lights brighten at 50 % and never past 1.6× white; HDR white level = 2^hdrStops for highlights. Contrast from the 5–95 % spread, Vibrance from mid-tone saturation (0 for B&W/grey), white balance from near-neutral cells (≥5 % of the frame, 60 % of the cast, 30 % if strong, Temp ±30 / Tint ±20). Runs on `workQueue` (`autoBusy`, hourglass icon); only Auto's keys are applied on completion. Engine test now compiles Auto.swift. In sandbox, Auto now only sets free (Light/Color) values.

## Lens Blur phone feedback follow-up — 14 October
Owner reported amount still 0 and unclear subject selection on 0.1.207. PR #5:
old untouched zero/default settings migrate once on explicit tool entry to amount 8;
new explicit zero/reset choices stay off. Selecting a new subject re-enables amount 8
when off. Highlighted picking button, selection status and four-second red background
confirmation; manual eye can show/hide selection. Main Lens Blur page now uses the
same depth bar/presets/Near edge/Far edge controls as Masks. Brushes remain inline.
Shared fixes mirrored into sandbox; personal SideStore stays unlocked. Owner explicitly
requested publication ASAP after focused checks. Checks pending; latest feed 0.1.207.
Phone verification: old photos start at 8, subject selection feedback, depth/brush feel.
Troubleshooting: old fully-default saved zeros could not be distinguished from unused
settings; migrate those once, preserve custom-focus zeros and all new explicit zeros.


## Security changes — 14 October 2026

GitHub main is now protected: pull requests required, Release readiness from GitHub
Actions required, branches must be current, rules apply to admins, force pushes and
branch deletion blocked. Zero additional human approvals avoids locking out the sole
owner. NEVER temporarily disable protection or use --admin to merge failed checks.
Secret scanning and push protection enabled; sandbox origin cleaned, GitHub CLI uses
system keyring. Angelo confirmed revoking the old LLM token. Git access reverified.

Both clones now pin build actions, XcodeGen and model revisions/file hashes. Build
and test jobs have read-only tokens and checkout does not retain credentials.
Only the isolated main publish job may write releases; it rejects stale main builds.
Engine renders are run artifacts, not a release upload from a write-enabled test job.
Heal deletion removes current/history/owned patches, preserves retained references,
and waits for active export/thumbnail readers. Late writes/saves are blocked.
Legacy orphan patches absent from every sidecar cannot safely be attributed; corrupt
retained sidecars cause a cleanup warning rather than destructive cleanup.

Security validation completed: personal IPA 38625860904; testHealDeletionPrivacy
38625864692 (8 cases); sandbox OFF/ON 38625938312; PR readiness 38626612845.
Security-only main publication 38627206272 passed. SideStore source.json verified
as 0.1.200, build 200, com.example.lumen, Lumen-200.ipa, 322268814 bytes,
SHA256 005fc7745dc657f03fa57d3d11390c7404a3408c6a98c8f96fe32df4bba94ce2.
No payment changes.

New workflow: use a work branch + PR, run relevant checks, merge the checked PR via
GitHub. Notes-only PRs skip the Mac build and still run Release readiness. A [skip ci]
commit requires manual build.yml on that exact branch before merging; after merge
with skipped CI, manually dispatch build.yml on main to publish the update.
Do not force-push main or use the older direct-push instructions below.

Public unrestricted SideStore distribution remains unchanged for the owner's update
feed; distribution before selling Pro is still a business decision. GitHub account
two-factor authentication was not verifiable through the current API token.

## Status — shared revisions complete, 14 October
Lens Blur and photo information merged through protected PR #2 as 34b72c3.
Shared source is in sandbox too; Store code remains separate. Personal main/SideStore
is fully unlocked. Angelo approved publication on 14 October. SideStore 0.1.207
(build 207) is published: run 38634930064 succeeded on main fbe5b7a. Feed bundle ID,
download URL, size (322324910 bytes) and SHA256 matched the released Lumen-207.ipa:
4d5b0b1faa801f21a87ce2c4401e87135783ce9041b535dd556c0b0eaede94c6.
This includes the security fixes, Lens Blur revisions and photo-information button.

Implemented: whole detected/selected-instance subject protection and subject depth
percentiles; first-use amount 8 with saved zero/off preserved; progressive far blur;
photo-calibrated distance; full Near/Far feather travel and accurate depth graphic;
inline linked-mask refinement with brushes/Add/Subtract; transient red slider preview
with saved off preference. Top info button reads standard original EXIF/TIFF camera,
lens, date, dimensions, size, shutter/aperture/ISO across camera brands.

Validation (final app source d383f7e; frozen test revision e9d997b; later commits notes):
engine/metadata 38631365097 passed 79 checks including nine camera-make fixtures and
real Sony RAW preview/JPEG export; focused UI 38631369309 passed one combined test,
zero failures (87 seconds), including default 8, inline refinement, preview on/off,
saved-zero reopen, info sheet and both Near/Far endpoints. Screenshots/renders inspected.
Personal IPA 38631360377 and protected PR/readiness 38632032581 passed. Sandbox
38631373218 passed policy and APP_STORE OFF/ON compilation; compile-only skips shots.

Things to verify: update to 0.1.207 in SideStore, then check representative camera
RAW/ProRAW subject edges, brush feel, HDR/export appearance and performance on phone.

Troubleshooting: missing subjects offer distance/range/brush fallback. Old saved
Lens Blur objects preserve zero rather than guessing previous intent. Simulator touch
checks use marked synthetic depth/subject fixtures and do not establish AI quality.
Auto Level uses Vision horizon detection then straight-edge voting, not camera roll
metadata. Photo info uses available standard metadata; missing fields stay missing.
Read PRODUCT-BRIEF.md for the iOS/RAW/all-brands and cheaper-Lightroom direction.

Read this first. It records what exists, how it's built and shipped, and what to do next.

## Housekeeping (do this every session)
- Before finishing any session, update the **Status**, **Things to verify** and **Troubleshooting** sections below with what changed or was learned, then commit and push (`git add -A; git commit; git push`) so the next session starts current.
- Keep this file factual and short; remove items once they're fixed or verified. Never put passwords, tokens or Apple ID credentials in it.

## What this is
**Lumen**: a free, subscription-less Lightroom/Photomator-style RAW photo editor for iPhone, written in native Swift/SwiftUI on Core Image (custom Metal kernels) + Vision. The owner (not a developer, "not techy") is sick of subscriptions and wants a Lightroom-Premium-level app with all the sliders, masks and an intuitive design, sideloaded onto their own phone.

## The user and their setup
- Windows 11 PC, **no Mac** (may rent one later but doesn't want to spend until needed). Cannot compile iOS code locally; all builds happen on GitHub Actions.
- Phone: **iPhone 17 Pro Max** (iOS 27). Camera: **Sony A9** (ARW RAW). Shoots ProRAW on the phone too.
- Explicitly NOT wanted: lens corrections, AI denoise, Generative Remove/extend, cloud sync. (Heal was added at the owner's request on 2026-10-11; perspective sliders were ticked in the overnight report.)
- Explain things in plain steps. Never ask them to run terminal commands; do it for them. They must type their own passwords / 2FA codes and approve GitHub device-code logins themselves.
- Priorities they stated: smooth editing (Lightroom-like), a Lightroom-mobile style UI that wastes no screen space, masks that really work (subject, sky, luminance range, colour range, brush, gradients, add/subtract/intersect), no red overlay once a mask is set up.

## Where things are
- Local project: `C:\Users\pc user\Projects\app development\Lumen`
- Downloaded IPA for a manual Sideloadly install (rarely needed, SideStore delivers main builds): `C:\Users\pc user\Projects\app development\LumenIPA\Lumen.ipa` (refreshed 2026-10-09 with 0.1.72).
- Archive (outside the repo): `C:\Users\pc user\Projects\app development\Lumen-archive\` (the 2026-10-08/09 overnight-loop notes, decision log and scripts).
- GitHub repo (**public since 2026-10-09**, so Actions runners are free; it was private and ran out of macOS minutes): https://github.com/AngeloP46/lumen  (account **AngeloP46**). Because it is public never commit secrets or personal data, and commit with the GitHub no-reply address (`164361042+AngeloP46@users.noreply.github.com`, already set in the repo's git config). Older commits show the owner's real email.
- GitHub CLI is at `C:\Program Files\GitHub CLI\gh.exe` (NOT on PATH in the Bash tool; call it by full path). Logged in as AngeloP46; plain `git push` works.
- Inspiration: https://github.com/storytold/lightcraft (Rust, MIT/Apache). Ideas borrowed (not code): single fused per-pixel pass, cached blur "layers" for local contrast, log-luminance tone controls, OkLab colour work, mask planes summed per pixel.

## Backups
- `backup/before-ui-refresh` (branch on GitHub) = the app exactly as it was before the 2026-10-10 UI refresh (SideStore 0.1.72-era main, commit 5e04a66). To go back: `git checkout main; git reset --hard origin/backup/before-ui-refresh; git push --force-with-lease origin main` (only if the owner asks), which also republishes it to SideStore.
- UI changes are checked against `docs/UI-PRINCIPLES.md` (photo first, fewest taps, thumb reach, one slider style, gestures with a visible fallback, keep the tests).

## How to build and ship (the loop)
1. Edit Swift/Metal in `Sources/`.
2. `git add -A; git commit; git push` → **Build IPA** workflow (`.github/workflows/build.yml`, macos-15, XcodeGen + xcodebuild, unsigned, ~1 min; pushes that only change `*.md`, `Tests/**` or the test workflows don't build, so notes never publish an empty SideStore update).
3. `gh run list --repo AngeloP46/lumen`, `gh run view <id> --log-failed`.
4. Download: `gh run download <id> --repo AngeloP46/lumen --name Lumen-ipa --dir "C:\Users\pc user\Projects\app development\LumenIPA"`.
5. **Main builds reach the phone through SideStore** (set up 2026-10-09; the owner chose it over a paid developer account and won't pay for one). The Build IPA workflow's last step (main only) runs `sidestore/make_source.py` and uploads `Lumen-<run>.ipa` + `source.json` to the fixed `sidestore` release (keeps the newest 3 IPAs). The owner added `https://github.com/AngeloP46/lumen/releases/download/sidestore/source.json` in SideStore and updates Lumen from there, anywhere, no PC. SideStore rejects a download unless bundle id, version, build, size, sha256 and the `NS*UsageDescription` keys match the feed, so the script reads them all from the IPA; `CFBundleShortVersionString` = `0.1.<run number>` and `CFBundleVersion` = `<run number>` (project.yml + `CURRENT_PROJECT_VERSION` in build.yml). If you add an entitlement or a privacy key, nothing else needs changing.
6. Free Apple ID signing expires after **7 days**: the owner opens SideStore with LocalDevVPN connected and taps Refresh All. See **The phone side** below for the setup, recovery and known errors. Sideloadly is still installed as a USB fallback for branch builds.

No Xcode project is committed: `project.yml` (XcodeGen) generates it in CI. Metal needs `MTL_COMPILER_FLAGS=-fcikernel` and `MTLLINKER_FLAGS=-cikernel` (set in project.yml) so `Kernels.metal` becomes Core Image kernels in `default.metallib`. Bundle id `com.example.lumen`, iOS 18.0 target (needed for `UIGestureRecognizerRepresentable`), Swift 5 mode. App icon: `Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (single 1024 px RGB, same aperture design as `sidestore/icon.png`; `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in project.yml), added 2026-10-09 in 0.1.65; before that the home screen showed a blank icon.

## Testing without a Mac or device (very useful)
- **Engine test** (`.github/workflows/engine-test.yml`, runs on any push touching `Sources/Edit/**`): compiles the engine files + `Tests/engine/main.swift` as a macOS command-line tool on the runner's (paravirtual) Metal GPU, renders an A9 ARW and three JPEGs through ~40 edit cases and masks, uploads contact sheets as the `engine-renders` artifact. Download with `gh run download <id> --name engine-renders` and view the JPEGs. Also prints render timings and a Metal-texture orientation probe.
- **UI screenshots** (`.github/workflows/ui-test.yml`, manual only; the UI tests below save screenshots too): builds the app for the iPhone 16 Pro Max simulator, launches it with `-lumenDemo*` arguments (see `Sources/Demo.swift`) on the same sample photos and uploads screenshots as the `screenshots` artifact. Use this to check layout.
- **UI tests** (`Tests/ui/LumenUITests.swift`, `.github/workflows/uitest.yml`, run on every push to a branch other than `main`, or manually with `gh workflow run uitest.yml --repo AngeloP46/lumen --ref <branch>`, optional `-f only=<testMethod>`; the suite currently contains 70 tests and prints its results after the run finishes; `testPinchZoomsAndDoubleTapToggles` now and then sees a double tap as a single tap in the simulator: rerun it alone before chasing it): XCUITest drives the real app in the simulator with real touches (double-tap slider reset, hold-to-compare until release, drag/close the panel, pinch/double-tap zoom, tap to hide panels, swipe to next photo, panels never overlap the tool bar). Elements have accessibility identifiers (`slider-<name>`, `reset-<name>`, `panel`, `panel-handle`, `photo`, `tool-<name>`); the app writes an event log in demo mode (`-lumenDemoLog`). Add a test whenever you fix a gesture bug.
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
- `Views/EditorView.swift`: full-height photo, round floating buttons on top (back/undo/redo/hold-to-compare/menu), 8 fixed tools in a bottom bar (Crop, Light, Color, Grade, Curve, Detail, Masks, Presets: Presets last at the owner's request). `panelPlan` gives the everyday tools (all but Crop and the mask Shape tab) one shared height (`sharesHeight`, at most 400 pt) whenever the photo leaves room, so switching tools never moves the photo; otherwise it gives the panel whatever height the photo does not need (the user can also drag the grab handle: up = more controls, down = more photo, all the way down closes it, double-tap resets; content is clipped so it can never spill over the tool bar): with room for >= 4 whole rows it shows **every slider as a list** (`ParamPanel` list layout), otherwise **one slider at a time** (strip). More menu has Sliders: Automatic / One at a time / Full list. Tap the photo to hide all chrome; swipe the panel's grabber down to close the panel; press-and-hold the photo to see the original.
- `Views/Panels.swift` + `Components.swift`: panels built from `ParamItem`s (`ParamPanel`, `ScrubSlider` = relative drag, drag away from the track for finer steps, double-tap reset, value bubble; a drag only belongs to the slider once its first movement is sideways, so vertical swipes that start on a slider scroll the list). Light panel HDR pill = HDR on/off only (the HDR range slider was removed at the owner's request; `hdrStops` keeps its default of 2 stops). Strip chips and mask tabs mark the selected one with an accent fill + outline (it used to be a barely lighter grey). Grade = three `ColorWheel`s (hue/sat puck) + luminance sliders + Blend/Balance. Color has B&W, Reset and a colour-mix mode (`HSLPanel`: 8 swatches + Hue/Sat/Lum). `CurvePanel` fills its panel (GeometryReader), drags the nearest point (or adds one on the curve) relative to the finger, shows in → out values while dragging, draws the other channels faintly, presets in a ⋯ menu.
- `Views/CropViews.swift`: Lightroom-style crop. The crop frame is stored as fractions (`cropL/T/R/B`) of the straightened picture; while the Crop tool is open the whole straightened picture is shown with a draggable frame (corners/edges, drag inside to move, aspect lock via `cropAspect`, 0 = free). Angle slider = straighten.
- Gestures (all in `EditorView`): two fingers pinch-zoom around the point between them and pan with it at the same time, over every overlay, in every tool but Crop (`Views/PhotoGestures.swift`: `TwoFingerWatcher` only watches touches and never claims them, so it can't block other gestures; SwiftUI's MagnifyGesture stays as a fallback). One finger pans a zoomed photo wherever nothing else takes the touch (mask handles, brush and crop frame do; the hand button still frees one finger in Masks). In Masks the photo can be zoomed out to 0.3x and moved, and handles can be dragged past the photo's edges (`ViewXform.unclamped`), so gradients/radials can be much bigger than the picture; leaving Masks returns to fit, and elsewhere a pinch below fit springs back. Double-tap zooms to that spot, press-and-hold shows the original until release or until the finger starts moving (`@GestureState holding`), tap hides the panels. There is deliberately no eye button.
- Resets: tap a slider's value/arrow (or double-tap the slider, or long-press a strip chip) resets it; Reset pills reset a group; HSL/curve/grading/mask panels have their own resets.
- 100% view: pinching past ~1.4x makes `EditorViewModel` build a second, full-resolution `ImageSource` (max 6000 px long edge, shared AI masks) and render from it; it is released a few seconds after zooming back out. Swipe left/right on the photo (or More menu) moves to the next/previous photo.
- `Views/MaskViews.swift`: mask panel (type grid, Shape/Adjust tabs, components with add/subtract/intersect, luminance range bar with histogram, colour samples), on-photo handles. Red overlay shows only on the Shape tab (eye button toggles; the Adjust tab hides it, eye peeks). Masks are stored against the uncropped, unturned source; since 2026-10-10 the Masks tool shows the photo cropped and turned like every tool, and `MaskOverlay` maps every handle, brush point, pick and the radial's angle/radii through `SourceGeometry` (Graph.swift, same maths as `EditSession.geometry`, checked against it by the engine test); the red overlay gets the same geometry (`overlay(..., settings:)`). Press-and-hold compares in the Masks Adjust tab but not in the Shape tab, where a finger places the mask (owner's call 2026-10-10: a pause before dragging a handle flicked to the original); the hold gesture lives on the canvas (`canCompare`); a hold that starts on the brush takes its dab back (`cancelRecentStroke`, and `strokeOpen` stops the finger extending the previous stroke).
- `Library/LibraryStore.swift`: imports from Photos (fetches RAW original resource, falls back to `PickedFile` transferable) or Files; thumbnails via the same engine. `LibraryItem.taken` = EXIF date (read at import; older libraries fill it in on launch). `apply(_:to:keepOwn:)` pastes edits onto many photos (keepOwn keeps each photo's crop/straighten/rotation/masks), `export(_:options:)` batch-exports in the background (`batchProgress`, `batchResult`), `browseOrder` = the library's display order (editor swipe/next/previous follow it).
- `Views/LibraryView.swift`: grid in day sections (date taken, or import date; Sort by in the filter menu), RAW badge on thumbnails, long-press = Copy / Paste edits / Select / Remove. **Select** mode: tap photos or a day's Select, then the bottom bar: All/None, Paste edits (the look, or everything), Export (same options sheet, then Save all to Photos / Share), Delete (asks first). In demo mode the library always holds exactly the sample photos and sorts by import date (`-lumenDemoSort taken` to change).
- `Views/ExportViews.swift`: `ExportOptions` (format, quality 10-100, long edge full/4096/2048/1080, HDR on/off; remembered in AppStorage), `ExportOptionsSheet` (single and batch), `BatchExportSheet`. `EditSession.renderData(_:format:quality:maxEdge:includeHDR:)` scales the full-size result down.
- HDR: iPhones report `currentEDRHeadroom` = 1 until something brighter than white is on screen, so `EditorViewModel.effectiveHeadroom` uses `potentialEDRHeadroom` until the screen is in HDR mode (before 2026-10-09 HDR therefore never switched on). HDR mode decodes RAW with `extendedDynamicRangeAmount` 2 (SDR keeps 1) and gain-map JPEG/HEIC expanded; toggling HDR re-decodes (`reloadSource`, AI masks kept). The histogram then shows an HDR zone (SDR 60 % left, one segment per stop, part the screen can't show dimmed); the badge says `HDR +x.x` stops or why nothing shows (Low Power Mode, no headroom, nothing above white). The file kind (RAW · ARW / JPEG) shows under the histogram: JPEGs have no hidden highlight detail. `-lumenDemoHeadroom <x>` fakes an HDR screen in the simulator.

## UI refresh (2026-10-10, owner's requests from phone screenshots)
- One slider row everywhere (`SliderRow` in Components.swift; `ParamPanel` lists and `LabeledSlider` both use it): name, accent dot once changed, value = reset button. Groups get `SectionHeading`s (`ParamItem.section`; spec headers in `EditorView.spec` add 30 pt per heading). Page buttons: `PanelActions` (actions left, Reset right).
- Light: Auto pill stays lit while the values it set are untouched (`EditorViewModel.autoRecord/autoActive/toggleAuto`), a second tap restores the values from before. HDR moved to the top bar (`pill-hdr`, next to Back).
- Color: order Saturation, Vibrance, Temp, Tint (owner's choice); white balance picker (`wbPicking`, `pickWhiteBalance` solves the kernel's WB gains for a neutral spot; tap layer `wb-layer` in EditorView). The page Reset leaves the colour mix alone, as before.
- Detail: headings Effects / Sharpening / Noise reduction / Vignette / Grain.
- Grade: tabs All / Shadows / Midtones / Highlights (`@AppStorage("gradeTab")`); a zone tab = one big wheel + Hue / Saturation / Luminance rows; All = the old three wheels + Blend / Balance.
- Edits sheet (top bar `btn-edits`, `EditsSheet.swift`): per tool switch off/on (`EditSettings.disabled`, `EditSection`, `effective` = what `develop` renders; values are kept), reset one tool, Reset all (confirm). Tool bar shows a dot under tools with edits and an eye-slash on switched-off tools; a switched-off tool's panel shows a "Turn on" bar. Crop can be reset but not switched off.
- Photo sits directly on the panel: spare height goes above it, under the floating buttons (`EditorView.topSpare`; not in Masks/Crop, which keep room round the photo).
- Masks: header = + / masks / eye / ⋯ (move photo with one finger, delete). The parts row only appears with more than one part. Brush: Paint | Erase, Size 1–100 (= brushSize × 400), Feather applies to strokes painted afterwards (`BrushStroke.feather`; `brushImage` softens runs of strokes separately when feathers differ). Linear and radial: blue move pin + round-arrow turn knob, 44 pt targets. Luminance graph: white handles = band, small blue handles = soft edges (`lum-bar`). How-to hints show once per mask kind (`maskHintsSeen`). Sky: also picks up blue sky seen through trees (blue skies only).
- Photo placement: `ViewXform.bottomAlign` rests the photo on the panel while it is shorter than the view and grows it upwards when zoomed (not in Masks/Crop/landscape); `EditorView.drop` keeps the pinch point steady.
- Landscape (width > 1.1 × height): photo left at full height, panel in a right column (`sidePlan`, 300–400 pt) with an icon-only tool bar (`toolBar(compact:)`). Portrait tool bar folds to a 30 pt strip (`toolsCollapsed`, AppStorage; ˅ button overlaid on the panel's grab row, `tools-collapse` / `tools-expand`).
- Pinch: `TwoFingerInstaller` puts the `TwoFingerWatcher` on the WINDOW (only fingers landing on the photo area count; disabled while a sheet is up). As a SwiftUI `.gesture` it lost to child gestures (mask pin / rotate knob). `vm.pinching` makes mask handles ignore drags during a pinch. `.simultaneousGesture` with a UIGestureRecognizerRepresentable does not compile.
- Accessibility modifiers on a handle go BEFORE `.position(...)` (after it they cover the whole canvas).
- CI failures are readable from the cloud session as check-run annotations (uitest.yml emits `::error::` lines): `gh api repos/AngeloP46/lumen/check-runs/<job id>/annotations`. Run one test alone: `gh workflow run uitest.yml --ref <branch> -f only=<test>` (use a scratch branch so it doesn't cancel the branch's full run).
- Artifacts (screenshots, renders) can't be downloaded from the cloud session (blob storage is blocked by its proxy); check them from the PC or rely on the test assertions.

## Release routine (owner's call 2026-10-11: no long waits for small fixes)
- Small fix: push the branch, open a PR, wait for **Build IPA** (~2 min, proves it compiles) + Release readiness, run just the related UI test(s) on a scratch branch if any, merge the PR on GitHub → SideStore. The full UI suite (~35 min) keeps running on the branch afterwards; if it finds a problem, fix it in the next release. (`main` is protected: no direct pushes or fast-forwards.)
- Big or risky change (engine, gestures, layout maths across tools): wait for the full suite before releasing.
- Mask Adjust and Detail: the page Reset rides on the first section heading (`ParamPanel.pageReset`), strip = round icon; released 0.1.113 before the full suite finished.

## Masks 2026-10-11 (0.1.116 – 0.1.131)
- **Depth mask** (`MaskKind.depth`): Apple's Core ML Depth Anything V2 small f16 (Hugging Face `apple/coreml-depth-anything-v2-small`), downloaded + compiled by `.github/ci/get-depth-model.sh` in Build IPA and Engine test (actions/cache key `depth-anything-v2-small-f16-1`), bundled as a folder reference `Models/DepthAnythingV2SmallF16.mlmodelc` (`optional: true` in project.yml, so UI-test builds have no model and the panel says so). `computeDepth` runs it via VNCoreMLRequest (portrait turned a quarter for the landscape 518x392 input), normalises disparity p2..p98 and flips: `DepthField` 0 = near ... 1 = far, top row first (render(toBitmap:) writes the top row first). Band uses the luminance fields (`lumLow/High/...Feather`) and kernel `lumenRangeMask`; `LumRangeEditor(depth: true)` = Near/Middle/Far presets, tap photo picks a distance. Engine test: matterhorn top far / bottom near.
- **Part opacity** (`MaskComponent.amount`, owner's request): applied to each part before combining (Intersect: 1 - t·(1 - b)); UI "Part opacity" when a mask has more than one part, the old slider is "Mask opacity".
- **Edge refinement** (0.1.123): `refined()` in Masks.swift = guided filter (kernels `lumenGFPack/Coef/Apply`; data never in alpha, Core Image premultiplies it), window 0.8 % of the long edge (depth 1.4 %), masks stretched (0.12…0.88) to drop the filter's tails; result kept as an 8-bit buffer (`materializedMask`). New AI masks start with Soften 0 (the old default 50 blurred them again).
- **AI Sky + Landscape** (0.1.128): Apple's `DETRResnet50SemanticSegmentationF16` (COCO panoptic, 201 labels, input 448x448, output `semanticPredictions` Int32 448x448), fetched by `.github/ci/get-seg-model.sh`, bundled like the depth model. `computeScene` → `SceneField` (labels + parts found ≥ 0.3 %). Sky uses it (classical `computeSky` is the fallback); `MaskKind.landscape` + `MaskComponent.scene` = Lightroom's parts (`ScenePart`: sky, water, vegetation, mountains, architecture, natural/artificial ground; class numbers checked against the model's labels by the engine test). Mask type grid = 6 columns (11 kinds), `kind-<raw>` ids.
- UI-test workflows create empty `Models/*.mlmodelc` stand-ins: without them xcodebuild failed (`optional: true` still adds the reference), so the full UI suite did not run for 0.1.116–0.1.123.
- **Masks tidy-up** (0.1.131, owner's request): new-mask grid grouped like Lightroom (`typeGrid`: Auto = Subject/People/Background/Sky/Landscape on row 1; Draw = Brush/Linear/Radial and Range = Colour/Luminance/Depth side by side on row 2). Landscape offers `ScenePart.landscapeParts` (no Sky: Sky is its own mask) and lists only parts found in the photo (2-column grid) + "Not in this photo: …". `EditorViewModel.emptyReason(_:)` (component / mask) → orange banner `mask-empty` with Remove mask, photo notice `mask-empty-photo`, ⚠︎ on the chip. Invert part / Invert mask = icons `invert-part` / `invert-mask` beside Add / subtract.
- Next (agreed): real depth from iPhone Portrait photos for the Depth mask (Lightroom's approach), AI depth stays as the fallback for photos without depth data.
- Owner wants masks as good as Lightroom's. Gaps noted: sky finder is classical (weakest), no tap-to-pick object mask (Vision gives instances), no people parts (face/skin/hair...), masks are computed at 1024 px so edges are soft at 100 %.

## Heal (0.1.137, owner's request 2026-10-11)
- `Tool.heal` (tool bar between Masks and Presets), `EditSection.heal` (`canPaste` false), `EditSettings.heals: [HealSpot]` (strokes + patch rect normalised top-left + `scale`).
- `Sources/Edit/Heal.swift`: `makeHeal` = square around the stroke (2.4x, min 192 px) from the FULL-resolution decode with the earlier heals, scaled to 800x800, divided by its peak (HDR), LaMa (`mlboydaisuke/LaMa-CoreML`, inputs `image` + `mask` 800x800, output `output`; computeUnits .all (as verified by the converter) with .cpuOnly as fallback; inputs go in as raw pixel buffers; the OUTPUT IS MADE OPAQUE (`settingAlphaOne`): dark fills on red paint / yellow plates on the iPhone (0.1.139-145, also on CPU) are believed to come from the model leaving the output's alpha byte below 255 on iOS (on the CI Mac it is 255, so this is unconfirmed there); the patch is re-checked after write + read-back (rejected if much darker than its surroundings); HealStore draws old patches opaque too; engine test: badge on red paint heals red and the stored patch is fully opaque; ~216 MB, fetched by `.github/ci/get-heal-model.sh`), patch + soft mask written as PNGs by id in `HealStore.directory` (= Library/heals).
- `EditSession.heals` is applied inside `decode` (`HealStore.apply`), so every path (preview, detail, export, thumbnails) shows heals; `renderCGImage(_:maxEdge:)`/`renderData` set it from the settings; the view model sets it on load and `reloadSource()` runs when effective heals change (undo, delete, switch off).
- Heals are never pasted (library apply keeps each photo's own, editor Paste keeps own, Paste some hides Heal), never in presets; preset Strength keeps them.
- Views: `HealOverlay` (one-finger paint, pins `heal-pin`, busy `heal-busy`), `HealPanel` (Size, Delete this fix, Clear all, `heal-note`). Hold-to-compare is off in Heal (finger paints). Since 0.1.141 the original (hold) and the split's before half show the photo WITHOUT heals: `unhealedSource` (2560 preview, `makeSource(...heals: [])`), built by `refreshUnhealed()` while the photo has heals, rebuilt when HDR changes, not used in the 100 % view's split.
- Engine test: stored patch replaces a red disc; model removes it (~10 s on the CI VM). Library/heals files are not cleaned up when a photo is removed yet.
- **Portrait RAW bug (fixed 0.1.158):** `CIRAWFilter.nativeSize` is the sensor's landscape size even for portrait photos, so Heal measured portrait ARWs sideways (wrong area copied: car into the hedge, tarmac onto a plate; off-edge = black). `EditSession.nativeSize` is now the decoded (oriented) size; `makeHeal` refuses if they disagree; the engine test checks they match. JPEGs (oriented by ImageIO) were always right, which is why heals on JPEGs looked great. Many earlier 'AI quality' complaints were this bug. **Owner confirmed on the phone (2026-10-11): heals on portrait RAWs now work.** Fixes made on RAWs before 0.1.158 are still wrong and must be cleared.

## Heal, Remove people, sky through trees (0.1.160+, 2026-10-11 evening)
- **Big fixes:** `EditSession.healRegion` = square of 2.4x the area, at most the long edge (and 2x the short edge); it may run past the photo's short sides, the missing context is a mirror image (`mirrorPadded`), so `HealSpot.x/y` can be < 0 and `w/h` > 1 (HealStore crops). Before, the square was capped at the short edge: on portrait photos tall areas were cut off (head and legs left, straight lines). Owner-confirmed limit: a person filling the frame comes out soft (800 px model). Chunked high-res refill is an idea to try on test photos only, not promised.
- **Fill check:** a fill is rejected only if far darker than the band right around the spot (`meanBetween`, outer = hole grown 34 px); it used to be the whole square, which binned correct dark fills next to bright things (owner's "couldn't remove" on a small tap). `EditSession.healFailure` (`HealFailure`: notAvailable / tooBig / looksWrong / failed) gives the panel message.
- **Remove people** (Heal panel `heal-people`): `findPeople` = Vision person segmentation + person instance mask (max-combined; the instance one catches people cut off by the frame), read at 768 px, `splitPeople` = connected pieces (widened 0.6 %, crumbs < 20 px dropped, max 12), `FoundPerson.main` = >= 3 % of the photo and >= 0.3x the biggest (not picked at first). Picker: red tint (`tintPeople`) + pins (`person-pin`), tap toggles (smallest box containing the tap), All/None, Cancel, Remove N (`people-remove`) = one `makeHeal(person:)` each, built on the previous ones, appended as one undo step; `HealSpot.person` = the box (pin + dashed outline). CI: `-lumenDemoPeople` = three made-up people (no Vision in the simulator).
- **Sky through trees:** `skyThroughTrees` (Masks.swift, kernels `lumenSkyWeigh/LeafWeigh/SkyGaps`): only inside the scene model's trees (class 184, `ScenePart.treeClass`) near confident sky, each pixel joins the closer of the local sky colour and the local leaf colour (OkLab, fields measured at 1/8 size, sigma 5 % of the long edge; leaf samples exclude anything nearly as bright as the sky). Prototyped on the owner's Aston Martin screenshot against Photomator. AI masks are recomputed each time a photo opens (no disk cache).
- **RAW starts in HDR:** `LibraryStore.editorSettings(for:)`: a RAW with no saved edits opens with `hdr = true`; CI keeps the old start unless `-lumenDemoRawHDR` (then `-lumenDemoFresh` deletes the sidecars instead of saving defaults).
- **Engine preview sheets** go to the `test-previews` release (public): `remove-people.jpg`, `people-finders.jpg`, `tall-heal.jpg`, `sky-trees.jpg`; fetch with curl from `github.com/AngeloP46/lumen/releases/download/test-previews/<name>` and look at them. Extra samples (not rendered by every edit case): `people/bus.jpg` (ultralytics), `people/building.jpg` (OpenCV).
- **Histogram, Photomator-style** (owner asked "asap"): 128 bins from a 256 x 256 sample of a 320 px render; `HistogramView` = grey brightness shape (`lumaShown` = HDR-scaled in HDR) + smooth red/green/blue lines with faint fills, dark rounded panel, 156 x 76 (HDR 190 x 76). The full-resolution and Heal busy badges moved below it.
- **Sky from four quarters** (owner asked, 2026-10-11 late): `skyScene` runs the scene model again on 4 overlapping quarters (60 % each, ~1.7x detail; tiles cropped from a 1600 px render), stitched on a 2x grid (896) from the most central quarter; the quarters may only ADD sky within 8 % of the whole-photo sky (allowing them to remove sky lost real sky among branches on the cat photo); elsewhere their finer labels feed the tree-gap step. Only the Sky mask uses it (Landscape keeps the whole-photo field). ~3.5-4.5 s on the CI CPU (4 extra model runs; much faster on the phone's Neural Engine). Sheet: `sky-trees.jpg` = photo | live | quarters.
- `testPinchZoomsAndDoubleTapToggles` (sky/HDR suite) and `testClippingWarningAndBeforeAfterSplit` (histogram suite: split drag reached 0.53) each failed once in a full suite and passed alone on the same code: simulator flakes.
- **Landscape parts keep off the sky** (owner, 2026-10-12): `landscapeMask` = the part's scene mask x (1 - the finer AI Sky), so Vegetation stops where the sky seen through the leaves starts (overlap on the test photos 0.019-0.027 -> 0.003-0.004); Vegetation also gets back tree tops the whole-photo run called sky (`labelRegion` trees x coarse sky, before the sky is taken out). Only a scene-model sky is used. The Sky is now worked out whenever Landscape parts are (one computation, cached). Sheet: `vegetation-sky.jpg`.
- **AI mask busy notice** (owner: tapping Depth looked ignored for a few seconds): `EditorViewModel.aiPending(mask)` → capsule on the photo (`mask-busy`: "Measuring depth…", "Finding the sky…", …) while the selected mask's AI result is not ready. CI: `-lumenDemoSlowAI` holds the AI back 4 s (`testAutoMaskShowsItIsWorking`).
- **Depth: the sky is always far** (2026-10-12): when the scene model finds a sky, `skyFar` pushes the depth field to 1 under the AI Sky (soft at its edge) and recounts its histogram, so Far gets all of the sky and Near never leaks into it. Engine: depth inside the sky 0.9998 on cat and matterhorn.
- Ideas not built (judged uncertain): four quarters for every Landscape part (tile mislabels would need a guard per part), colour-competition edges for Subject/People hair against the sky.

## Smart fill (tried and removed, 2026-10-11)
- 0.1.154 shipped a beta "Smart fill" (Stable Diffusion 1.5 inpainting, LocalMuseAI/coreml-cyberrealistic-v8-inpaint-6bit, own CLIP tokenizer + DPM-Solver++ + 9-channel UNet + VAE). On the CI Mac the VAE decoder returned flat grey even for a plain encode→decode round trip; on the owner's iPhone fills came out as blue/cyan noise. Owner asked to go back to the working quick heal: 0.1.156 reverts all of it (code = 0.1.147) and deletes the ~950 MB download on launch. The code is in git history (commits 2812404..50653eb) if it is ever picked up again; it needs a real Mac + iPhone to debug.
- Apple's Photos **Clean Up** (Apple Intelligence, iPhone 17 Pro Max) is the suggested route for hard removals: export from Lumen, Clean Up in Photos as the last step.
- Owner, 2026-10-11 after the 0.1.158 fix: quick heal removed the person behind the car perfectly; Smart fill is probably not needed. Don't restart it unless he asks.

## Status (14 October 2026: SideStore 0.1.197 published: shared editor fixes and Lens Blur)
- Angelo explicitly requested the same bug/feature improvements in personal SideStore and sandbox; this overrides the App Store-only main freeze for shared improvements. Main remains paywall/subscription/watermark free. No App Store Store files or build flags are merged into main.
- Fixed maximum elastic pinch release to retain the last touch anchor, closed-panel photo centering, clipping warnings outside transparent photo pixels, and depth feather sliders' extra cap. Saved per-photo undo/redo in the atomic settings sidecar under _undoHistory, capped at 100; older versions ignore this key. Old discarded undo steps cannot be recreated.
- New standalone Lens Blur beside Detail: estimated depth for camera RAW/JPEG, tap focus, amount/distance/range, background refinement via a linked Depth mask with Add/Subtract brush corrections. Blur applies before geometry and to HDR gain as well, with radius scaled to source size. Presets/paste retain each photo's focus. Older saved settings default blur off.
- User chose scrolling toolbar with fixed readable targets (66 pt portrait, 48 pt landscape); labels retained. No need to shrink all tools on smaller phones.
- Exact no-op paths avoid filter colour conversion when no farther plane exists or refinement opacity is zero. Ready depth is reused while dragging Blur amount so analysis does not interrupt controls.
- Validation passed: original fixes UI/build/engine, depth slider test 38599011360, full blur engine 38600705716 (969 checks), final focused blur + real Sony ARW preview/JPEG export 38602642007 (32 checks), final combined interaction test 38602633151 and IPA build 38602637294, source feef0e4. Lens Blur/control/refinement screenshots inspected: readable single-row toolbar, panels above toolbar. Sandbox export-policy and APP_STORE OFF/ON build steps passed in 38600345922; optional duplicate screenshot step cancelled after completion of those checks. Main publication passed in 38604801375 (build commit cbc8405, source code feef0e4). Verified release source.json version 0.1.197, build 197, bundle personal Lumen, Lumen-197.ipa and its SHA-256/size. Subsequent notes-only commits do not change that app code. Phone appearance/performance remains for owner feedback.

## Troubleshooting (14 October additions)
- Lens Blur depth failure: controls show that depth could not be estimated, and export refuses to silently omit requested blur. Build must include the existing depth model. UI tests use a clearly marked demo-only synthetic depth fixture for touch checks; this does not establish AI quality.
- Lens Blur boundaries can show estimated-depth errors or background colour bleed: use inline Refine background with Add/Subtract brush. Camera RAW is the primary intended use; Portrait depth extraction has not been added in this change.
- Undo from before the new version cannot be reconstructed; future undo/redo is persisted per photo. The global Edits switches still preserve values independently.

## Status (2026-10-12 01:00: main = latest SideStore build, released after full UI suite + engine test passed: Landscape parts off the sky, AI busy notice, sky-aware depth)
- Panel space (owner, 2026-10-11): in one-at-a-time (strip) layout the panel hugs its row (`panelPlan` snaps to `ToolSpec.compact` unless the handle is being dragged); section headings live in `ToolSpec.sections` and no longer raise the list threshold (`listMin` = header + one heading + 4 rows). In the strip, `PanelActions`' Reset is a 34 pt round icon (id still `pill-Reset`); the mask page's Reset is just "Reset". Radial turn knob sits just below the centre pin (thumb reach). UI test job limit is 45 min (the suite outgrew 30).
- Pro pack (owner ticked every item of the overnight report): Crop | Transform tabs (flip as seen on screen, auto-level via `levelAngle` / VNDetectHorizonRequest, 7:5, 3:1, custom ratio, grid choices `cropGrid`; Transform = `tVertical/tHorizontal/tAspect/tScale/tOffX/tOffY`, a CIPerspectiveTransform in `geometry` composited over a clear full frame, mapped for masks by `Homography` in `SourceGeometry`; flips `flipH/flipV` before the turns, `mirrored` flips radial angles). Clipping warning (`lumenClip` kernel, More → View; NOT on the histogram: a button there blocked press-and-hold on the photo). Before/after split (More → View, `splitCompare/splitPos`, draggable `split-handle`). Paste some edits (`PasteSomeSheet`, `EditSettings.take`). Grade Global wheel (`ColorGrading.global`, 5th tab). Preset Strength (`presetRecord`, `EditSettings.blend`). People mask (`computePeople`, VNGeneratePersonSegmentationRequest). Mask overlay cropped to the photo. Mask type grid = 5 columns.
- Auto-level: Vision horizon first (its angle is anticlockwise: Straighten = -angle), else `edgeLevel` (Sobel edge-direction histogram, refined by re-measuring after turning) for photos with no horizon. Engine checks a tilted horizon, a tilted 'building' and a level photo.
- Transform Fill frame (`tFill`, default on, like Lightroom's Constrain Crop): `Homography.corners` zooms the warp just enough that every frame corner is inside the photo; off shows the black edges.
- Rotation bug fixed: `CanvasModel` keeps every attached MTKView (weak hash table) and redraws those on screen; keeping only the last one left edits undrawn after turning the phone.
- Engine test failures also print as `::error::` annotations (readable via the check-runs API).

## Status (2026-10-09 midday: everything is on `main`, SideStore feed at 0.1.72)
- Done and verified in CI (38 UI tests + 771 engine checks): fused Metal engine, Lightroom-mobile UI, colour wheels, HSL, masks (subject/sky/background/brush/linear/radial/luminance/colour with add/subtract/intersect), crop, 100% zoom, resets, hold-to-compare. Added 2026-10-09: photo redrawn after every panel resize (was stretched / misaligned with the crop frame), one shared panel height for the everyday tools, two-finger pinch + pan everywhere, zoom out to 0.3x in Masks with handles past the photo, sliders that let vertical swipes scroll the list, HDR that really switches on (potential headroom, RAW EDR 2, HDR histogram zone, explaining badge, on/off only), RAW/JPEG label, library Select mode (delete / paste edits / batch export), day sections by date taken or import date, export sheet with JPEG/HEIC quality and size, full-panel curve, clearly marked selected chips, Presets last in the tool bar, app icon (other session), SideStore delivery (other session).
- NOT checkable in CI, so unverified: anything on the real HDR screen (how bright, how it looks), real-finger feel, Photos import from the real library, ProRAW DNG, subject-mask speed on the phone (Vision is too slow in the simulator).
- The owner tests on the phone and reports bugs/feel issues in chat. Fix them on a branch, add a UI test for any gesture/layout bug, push (Build, Engine and UI tests run by themselves), and once green fast-forward `main`: about 2 minutes later the owner taps **Update** on Lumen in SideStore → My Apps. Tell them when it's there. Downloading to `LumenIPA\Lumen.ipa` is only needed to try a branch build with Sideloadly (download the artifact to a scratch folder, then `cp -f` it over the old file; do not use `rm` or `bash -c` with timeouts, the safety check blocks them).

## Decisions taken for the owner (2026-10-09; they asked Claude to decide)
- Crop rotate buttons turn the crop (and a locked ratio) with the picture, like Lightroom, instead of resetting it (`CropPanel.rotate`).
- A file that can't be decoded shows "Can't open" on its thumbnail (`LibraryStore.unreadable`); the editor already said "This file couldn't be opened."; missing thumbnails are remade at launch.
- A damaged `index.json` recovers automatically: single bad entries are skipped; otherwise `index.backup.json` (copied at every good launch) is used, then the photo files themselves (named by id, so edits come back; original names become "Photo <date>"); files the list doesn't know are adopted; the user gets an alert. CI checks both paths (`-lumenDemoCorruptIndex index|both`).
- Background mask with no subject found = the whole photo (everything is background), with a hint in the mask panel.
- A drag the system cancels (call, Control Centre) no longer leaves a slider half-dragged with its list unable to scroll: `@GestureState` + a deferred tidy-up after any onEnded (ScrubSlider, pan and pinch).

## The phone side (SideStore, set up 2026-10-09)
- On the iPhone: **LocalDevVPN** (App Store; a local loopback "VPN" SideStore needs to talk to the phone) and **SideStore 0.7.0** (installed with iloader's "SideStore (Stable)", signed in with the owner's free Apple ID), with the Lumen source added under Sources and Lumen installed from it. Any leftover Sideloadly copy of Lumen is dead (its certificate was revoked) and can be deleted.
- Owner's routine: once a week, LocalDevVPN on → SideStore → My Apps → **Refresh All** (works anywhere with internet). Updates: My Apps shows **Update** on Lumen after a main build; pull down to re-check. App data survives updates.
- If SideStore itself expires (missed >7 days) or the phone is reset: plug in by USB, open **iloader** (desktop shortcut "iloader (reinstall SideStore)"; the real exe is `C:\Users\pc user\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\iloader\iloader.exe` because it was installed from Claude's shell, which sees it as `%LOCALAPPDATA%\iloader`; logs under `...\LocalCache\Roaming\me.nabdev.iloader\logs`), owner signs in, click **SideStore (Stable)**; then on the phone Settings → General → VPN & Device Management → Developer App → Trust, open SideStore, sign in (Settings tab), Refresh All, reinstall Lumen from Sources.
- Errors already met and their fixes: **Developer error 7252** "no 'ios' certificate with serial…" = iloader bug with the stale "Apple Development … e5c5d1f2…" certificate; in the "Maximum certificates reached" dialog untick that one and revoke only "iOS Development" ones. **"Maximum number of installed apps using a free developer profile"** = free accounts allow 3 sideloaded apps on the phone, expired ones included; delete old ones. **SideStore error 28 "You are not signed in"** = sign in under SideStore → Settings. The **+** on My Apps opens Files (installs an IPA); sources are added with the **+** at the top left of the Sources tab.

## How to continue in a new session
1. Open the session with working directory `C:\Users\pc user\Projects\app development\Lumen` and tell it to read CLAUDE.md first.
2. `git checkout main; git pull`, then work on a new branch (`git checkout -b <short-name>`). Every push to it runs Build IPA, the Engine test (engine files) and the UI tests (app files). When green, open a PR and merge it on GitHub (`gh pr create`, `gh pr merge --merge`); `main` is protected, so never push or fast-forward it directly. The merge publishes to SideStore. Bring the branch up to date with `origin/main` first if another session merged meanwhile.
3. Watch CI with `gh run list --repo AngeloP46/lumen --branch <branch>`; fetch artifacts with `gh run download <id> --name <artifact>` (engine-renders, screenshots, uitest, Lumen-ipa) and look at the images.
4. Another session may be working in this same folder: check `git status` before switching branches and never commit or discard changes you didn't make without asking.
5. Update this file before finishing.

## Things to verify on the phone
- Lens Blur 0.1.225+: disc look and speed at high amounts on 24 MP ARWs (three bokeh passes), roll-off feel, new amount scale, adjusting after leaving and returning.
- Auto 0.1.236: subject metering on cars/people, high-key and night scenes, white balance on mixed light, how long the hourglass shows.
- Updated SideStore build: max pinch release at off-centre points, closed-panel centering, clipping margins, Near/Far slider travel, undo/redo after reopen.
- Lens Blur on representative camera RAW/ProRAW (including Sony): focus picking, subject edges around cars/people, zoomed preview, HDR and exported appearance. Automated tests do not confirm real-phone appearance/performance.
- HDR on the real screen: does the badge show `HDR +x.x`, do bright skies/lights glow with detail, does the HDR export look right in Photos.
- Two-finger pan and pinch, zooming out in Masks, slider scrolling from anywhere: how they feel under a real finger.
- Library: Select, paste edits onto many, batch export speed with 24 MP ARWs, date sections (date taken comes from EXIF).
- Curve: point picking and the relative drag; export quality/size choices.
- First-open time of a 24 MP ARW and the "Loading full resolution" delay when zooming in; Photos import (RAW original vs JPEG: the label under the histogram says which arrived).

## Roadmap ideas
Before/after split, preset folders, AI sky model via CoreML, lens-free vignette correction, histogram-based tone-curve backdrop, Metal tile export for 48 MP ProRAW.

## History
- 2026-10-08/09: three unattended Claude loops (bugs / tests / HDR) worked overnight on separate git worktrees, with a Python "CI courier" pushing their branches and feeding GitHub CI results back. Their work was merged and verified on 2026-10-09; the worktrees, branches and scripts were removed in the housekeeping that day. Notes, decision log and scripts: `app development\Lumen-archive\overnight-2026-10-08\` (read `PROGRESS-master.md` before ever doing it again). The private repo ran out of free macOS minutes (they bill x10), which is why it is public now.
