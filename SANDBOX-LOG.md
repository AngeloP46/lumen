# SANDBOX-LOG — what was drafted and what Claude must check

## 28 Oct 2026: remaining adjustment completion (from main #180)
Candidate6f09c23: brush consistency, Lens Blur focus/refinement/RGBHDR, filtered grain/vignette, Heal/detection
failure and staged basic/refined thumbnail scheduling. Exact-mask lifetime barrier under memory validation;
no limits raised. Tests/review reports mirrored. Existing Pro/free gates retained. No Store code changed.
Validation/personal publication pending; do not merge before tested personal update. Unrelated marketing/listing kept.

## 28 Oct 2026: release validation complete (from main #176)
SideStore0.1.756 verified, sandbox #177 merged a54fa93 after40737807973 passes both flag builds, export policy
and four StoreKit tests. Main full quality passes1644 checks;132 focused regressions and six related UI cases pass.
Long memory40738195410 and phone follow-up remain. Existing Pro/free behavior retained. No Store code changed.
Sourcef6e3465, personal merge737e4fe. See AI reliability report/current main checklist for remaining review work.

## 28 Oct 2026: preserve AI failures across preview and export (from main #176)
Candidate f6e3465: denoise cache/model availability, bounded legacy PNG structural validation, mask failure
snapshot/restore, safe failed inversion and explicit export failure gate; valid empty/fallback selections retained.
Deterministic no-inference fixtures plus small-image probe/export and zoom-event test corrections. Existing Pro/free
gates retained. No Store code changed. Personal/sandbox validation pending. Clarity #175 merged 8649421 after
40732458311 passed both flag builds, export policy and all four StoreKit cases.

## 28 Oct 2026: correct Clarity scene coverage (from main #174)
Port 39b9c5d: remove broad expanded edge veto; bilateral medium-scale detail, strictly immediate fringe guard,
smooth central slider response and useful endpoints. Owner-approved car fixture and dense-edge regressions;
other light/colour/detail/Dehaze/local controls proven independent in SDR/HDR (142 focused checks pass).
Unreadable thumbnail early-admission feedback restored; RAW matrix includes the new helper in its compile list.
Existing Pro/free gates unchanged. No Store code changed. Sandbox OFF/ON/policy/StoreKit validation pending.
Prior recovery #172 is merged and passed 40678793157; personal owner confirms thumbnails now work.
SideStore 0.1.747 published, feed/hash verified. Broader engine 1553/1557 and UI 94/95 follow-up issues are recorded
in HANDOFF.md; do not claim those complete suites green.

## 28 Oct 2026: urgent thumbnail recovery and stronger Clarity (from main #171)
Port 4df9b79: per-photo thumbnail checkpoints survive interrupted migration, old JPEGs retained until successful
replacement, bounded decoded-image cache, per-job autorelease/GPU/model cleanup and optional MP-sized memory
admission separated from editor work. LoadedModel no longer retains its last hand-off after waiters finish.
Clarity endpoints stronger, signed squared response near zero, local abrupt-boundary protection. All existing Pro/
free gates unchanged. No Store code changed. Main 126 focused rendering/batch checks pass; sandbox OFF/ON/StoreKit
checks pending. Larger-library queue/refinement draft excluded at owner's request to get the recovery update first.

**Session:** 13 Oct 2026, by the local LLM (PC ASSISTANT, on Angelo's PC) — drafting the App
Store code per `docs/APPSTORE-PLAN.md` (v2, export-gate model) and `SANDBOX-BRIEF.md`.

## What was drafted (all new files unless noted)

| File | What it is |
|---|---|
| `Sources/Store/LumenStore.swift` | StoreKit 2 store: products, entitlements, purchase, restore, `ProStatus`. `#if APP_STORE` = real StoreKit; `#else` = always-Pro stub (SideStore builds). |
| `Sources/Store/ProGate.swift` | `EditSettings.usesProFeatures` — the free/Pro line: free = Light + Color + crop/straighten/turns + presets; Pro = Grade, Curve, Detail, HDR, masks, heals. Respects the Edits-sheet `disabled` switches. |
| `Sources/Views/PaywallView.swift` | The export-gate paywall: both products with real prices, trial line, Restore, privacy line, free close path. |
| `Sources/Views/LumaforgeMark.swift` | Watermark. 14 Oct: now a tiled diagonal "Lumaforge" text pattern (SwiftUI `Canvas`), 45 % opacity, white + dark shadow — the classic protection look Angelo asked for (the earlier single-badge version was invisible at 30 %, then "looked like a button"). |
| `.github/workflows/app-store-sandbox.yml` | Manual-only compile check: proves the draft builds with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=APP_STORE` + bundle ID override on GitHub's Mac. No signing (documented for Gate 4). |
| `Sources/Views/EditorView.swift` (EDITED — hooks, all `#if APP_STORE`/demo-guarded) | 1) `requestExport()` gate function, 2) paywall sheet, 3) export button calls the gate + small crown badge, 4) tiled watermark over the canvas (skipped when `-lumenDemoNoWM` is set), 5) `applyDemo()` pre-builds per-tool demo edits for screenshots (`-lumenDemoGrade`/`Curve`/`Detail2`/`Export`/`People`). |
| `Sources/Views/LibraryView.swift` (EDITED — 1 hook) | `-lumenDemoBatch` enters selection mode with photos checked, so the batch-export bar is visible in the screenshot. |
| `Sources/Demo.swift` (EDITED) | Added `noWM` (`-lumenDemoNoWM`): suppresses the watermark in a CI launch so ad shots are clean. |

**Nothing else was touched.** `project.yml`, `build.yml`, engine-test, ui-test, all engine
files, SideStore feed — untouched.

## Open questions for Claude / Angelo

1. **Trial detection** (`LumenStore.refreshStatus`): the heuristic "monthly entitlement expiring
   within ~8 days = trialing" is a draft. Confirm against StoreKit 2 (the `Product`/`Offer`
   relationship or `Transaction` fields — I believe purchase options expose the intro offer,
   but couldn't verify without Xcode).
2. **Free/Pro line, presets:** a preset that sets curves leaves curve values in the photo →
   exports as Pro. That matches "only basic features export free", but confirm it's the intended
   behaviour (it's what plan §4.1 says, but it's the one edge case Angelo should see).
3. **Watermark placement & look:** both placements are in the hook; pick on device. The glyph is
   a placeholder — swap in the real logo when the name is decided.
4. **Product IDs** (`lumaforge.pro.monthly/.annual`): placeholder name — re-decide with the
   final name at Gate 4.
5. **Watermark on 100% zoom view:** the hook covers the canvas only. If the 100% view is a
   separate view path, the mark needs a second hook — I couldn't confirm without more reading;
   flagged rather than guessed.
7. **Tiled watermark tuning:** 45 % opacity / 34 pt text / -24° / 250×130 pt spacing are
   guesses from screenshot captures, never eyeballed on a real device. Tune in
   `LumaforgeMark.swift` (the `Canvas`) if it reads too faint or too loud on a phone.
8. **`-lumenDemoNoWM`** is launch-arg-only (CI screenshots) — it does nothing in normal use,
   but it means the watermark can be suppressed in any test launch. Confirm that's acceptable.
9. **Screenshots 05/06 (masks/heal)** use CI stand-ins (fake AI). Angelo has ruled them out of
   the App Store listing; real mask/heal ad shots would need a real device or a captured
   photo. The listing set is 01, 02, 03, 04, 07, 08, 10 (all clean, all real).
6. **Sandbox compile-check workflow:** run it manually from the Actions tab (workflow_dispatch)
   to prove the draft builds. It does NOT compile the new Store files into the engine test —
   the engine test compiles a fixed file list, so it's unaffected by this draft (which is the
   point: the draft can't break the engine).

## Build/test status (live on GitHub's Mac, 13 Oct)

The `sandbox` branch runs the repo's normal CI on every push, plus a new manual/branch
workflow `app-store-sandbox.yml` that builds the WHOLE app with the App Store flag ON.
Results at https://github.com/AngeloP46/lumen/actions (branch: sandbox):

- **App Store sandbox compile check (flag ON, whole app incl. paywall/watermark/gate):**
  first run FAILED with 5 real errors, all in the new draft files — fixed and re-pushed:
  1. `LumenStore.swift`: `Transaction.expirationDate` is `Date?` in StoreKit 2 — now unwrapped.
  2. `PaywallView.swift`: was missing `import StoreKit` for the `Product` type — added.
  After the fixes: **PASSED** (run 38465796944). The draft app compiles in the App Store config.
- **Build IPA (flag OFF — the SideStore configuration):** **PASSED** on the sandbox branch
  (several runs). This proves the `#if APP_STORE` split leaves the SideStore build compiling
  exactly as before. It built a throwaway IPA; it never uploaded to the SideStore feed
  (that step only runs on main).
- **UI tests / Engine test:** engine test didn't trigger (no engine files touched by the draft);
  UI test run passed on an earlier push.

**App Store screenshots (run 38468284395, 13 Oct, passed):** the workflow now also boots a
simulator after a clean build and captures 3 shots (artifact `app-store-shots`, viewable at the
run's artifacts page):
- `01-free-light`: free edits only — watermark must be ABSENT (verify visually).
- `02-pro-watermark`: Detail values via the new `-lumenDemoPro 1` demo flag — watermark +
  crown badge must be PRESENT (verify visually).
- `03-paywall`: `-lumenDemoPaywall 1` demo flag presents the sheet — **file size was oddly
  small (185 KB vs 4.5 MB); Angelo to confirm the sheet actually rendered.** If it didn't,
  the 3 s sleep in applyDemo or the sheet presentation needs adjusting.
Demo hooks added (CI-only, all `#if APP_STORE`): `DemoMode.paywall` / `DemoMode.proEdits` in
Demo.swift, used by EditorView.applyDemo — they do nothing in normal use. Watermark got an
accessibility ID (`lumaforge-mark`) for future UI tests.

**Angelo reviewed the first shots (13 Oct):** paywall renders correctly — the "loading"
rows are just the two products not existing yet (expected until Gate 4). The watermark, in
contrast, was wrong: small, top-right, behind the toolbar icons. **Fixed (run
38474050863, passed):** big (28pt glyph, 24pt text), bottom-centre ON the photo, 0.3 opacity,
shadow, `.ultraThinMaterial` capsule. It's anchored to `ViewXform.rect` so it follows
zoom/pan. The crown badge on the export button was removed (it sat over the icons).
New shots: artifact `app-store-shots` on that run (02-pro-watermark.png). **Angelo to confirm
the new look/placement is acceptable** — the corner placement still exists
(`LumaforgeMarkPlacement.choice`) if he prefers it.

**App Store listing assets drafted (13 Oct):** `docs/APPSTORE-ASSETS.md` — name, subtitle
candidates, description, keywords, privacy label, age rating, 6-screenshot plan, App Preview
plan, the full subscription setup checklist for Gate 4, product-ID single-source-of-truth
note, and a rejection-risk checklist. All DRAFT; nothing in it is live.

**RAW format matrix (13 Oct):** new `Tests/rawmatrix/main.swift` +
`.github/workflows/raw-matrix.yml` — both brand-new files, nothing frozen touched. On GitHub's
Mac it downloads one public-domain sample per camera RAW from raw.pixls.us (Canon EOS R5
CR3, Nikon D750 NEF, Fuji X-T4 RAF, Sony A7 ARW, 5D III DNG) and checks the engine opens,
decodes (non-blank) and exports each to JPEG + HEIC + 16-bit TIFF at full resolution.
First run (run 38481146085, 14 Oct 00:16): **PASSED — "5/5 RAW formats decoded and exported"**.
Canon R5 CR3, Nikon D750 NEF, Fuji X-T4 RAF, Sony A7 ARW and 5D III DNG all opened, decoded
(non-blank) and exported to JPEG, HEIC and 16-bit TIFF at full resolution on GitHub's Mac.
Still missing from the matrix: CR2 (needs an old-Canon sample) and ProRAW (needs a real
iPhone ProRAW file — a real device is the only clean source).

## 14 Oct session — screenshots + watermark (all pushed to `sandbox`)

- Watermark reworked twice (see open question 7): final = tiled diagonal, `Canvas`-based.
- `app-store-sandbox.yml` now captures 10 shots; 01–08 + 10 are clean (`-lumenDemoNoWM`),
  only 09 shows the watermark. Run 38547865597 (5d86f40) **PASSED** — all 10 shots verified:
  watermark clearly visible on 09, no watermark on 01/04 (04 is a Pro edit — proves the
  clean flag works on the gate case).
- 05/06 are CI stand-ins only — NOT listing material (Angelo's ruling).
- Listing set for the App Store: 01, 02, 03, 04, 07, 08, 10. Order + headlines in
  `docs/APPSTORE-ASSETS.md` §10.
- All changes are launch-arg/demo-guarded or `#if APP_STORE` — the SideStore build (flag
  off) is unaffected; `project.yml` and `build.yml` still untouched.

## What to check first when building in the real repo

1. Delete/review everything in `Sources/Store/`, `PaywallView.swift`, `LumaforgeMark.swift`,
   and the 4 `#if APP_STORE` hooks in `EditorView.swift` (search the repo for "DRAFT — sandbox").
2. Decide the compile-condition name — I used `APP_STORE`; confirm XcodeGen passes
   `SWIFT_ACTIVE_COMPILATION_CONDITIONS` through to the app target (the sandbox workflow
   sets it on the command line, which should work).
3. The stub path (`#else` in LumenStore) must be what SideStore builds compile — verify a
   SideStore pipeline run still produces a normal IPA (brief rule 1's safety check).
4. RAW test matrix: now DRAFTED as `Tests/rawmatrix/` + `raw-matrix.yml` (CR3/NEF/RAF/ARW/
   DNG) — check its first Actions run, then extend to CR2 and ProRAW in the real repo.

## Codex review fixes — 14 Oct 2026

Authorized by Angelo after source review. Changed Store/LumenStore.swift (verified offer
classification, eligibility, grace-safe entitlements, expiry refresh, restore errors),
Store/ProGate.swift (neutral grading/masks/sharpen controls), Views/EditorView.swift (observed
store, refreshed UI gate and export callback), Views/LibraryView.swift (batch paywall and
refresh), Edit/EditorViewModel.swift and Library/LibraryStore.swift (defence at actual export
entry points). Every runtime change is APP_STORE-only; SideStore paths preserved.

Changed PaywallView.swift to show actual eligible monthly trial and billing terms, dismiss
after paid access, expose AppPrivacyView.swift and standard Apple EULA. AppPrivacyView is a
new bundled policy; public App Store metadata URL still needs publication.

Added Tests/progate/main.swift (free/Pro states, disabled sections and mixed batch cases).
app-store-sandbox.yml now runs it and builds flag OFF as well as ON. Existing SideStore
project.yml/build.yml/model-fetch scripts untouched. Strengthened Tests/rawmatrix/main.swift
with exposure edit, exact sample-extension coverage, reopened exports/dimensions/TIFF depth.
CR2 and ProRAW remain explicitly untested. Compilation and runtime results pending GitHub CI.

CR2 follow-up: added the public-domain Canon EOS 5D Mark II RAW sample (raw.pixls.us sample 1182), pinned SHA-256 81c5ee6da45c4e22584c5344807ac32e2c9ba82ad274486ba64745ef8dd4f69c. RAW matrix now requires six exact formats. ProRAW remains missing; no build results yet.

14 Oct preset decision: Angelo chose free built-in preset exports, with no blanket exemption for extra Pro edits. e4698a9 matches actual built-in recipes/strengths, gates HDR/masks/heal and extra advanced values, and fades built-in advanced strength from neutral on free photos. Existing Pro edits are retained when fading from a Pro starting state. Added preset/copy/reload/mixed-batch cases. No metadata flag can grant free export. App Store-only hook; personal build unchanged. Manual compile/policy run: https://github.com/AngeloP46/lumen/actions/runs/38589125986 (pending). Existing 70-test personal-app interface suite continues; skip-ci commit avoids restarting unchanged flag-OFF behavior.

Final validation (14 Oct): e4698a9 policy regression checks, simulator APP_STORE OFF/ON builds and ten screenshot captures all passed in run 38589125986. Earlier b8580d1 UI suite passed 70 tests with zero failures (run 38585012729); e4698a9 changes only APP_STORE runtime and latest OFF build confirms personal configuration still compiles. Six-format RAW regression passed at 20d2f86 (38584274180), as did editing-engine tests (38584274314). No personal phone publication. Relocation verified: 1,349 files moved, individual old-path junctions retained; all 26 copied landing-page files hash-match the original. Main source HEAD stays 70f1448; only local notes/AGENTS and existing untracked plan updated. Preserved original download and live site. New content tone preference recorded in root notes.

15 Oct (Claude, shared fix from main PR #6, SideStore 0.1.215): undo/redo history moved out of the edits sidecar into edits/<id>.history.json, written on a background queue; old _undoHistory still read and migrated on next save. Heal deletion and reference scans include the history file; testHealDeletionPrivacy has 9 checks. No paywall/StoreKit/watermark code touched.

15 Oct (Claude, shared feature update from main PR #7): Lens Blur is lens-like (round disc blur from three layers, background-only so no subject colour halo; smooth blur kept as fallback); gentler Blur amount scale (new 100 = old 35, start amount 23, saved amounts converted on load); wider default Near roll-off that the automatic blur now follows; tidier panel; sliders stay usable while analysis runs; Masks no longer lists Lens Blur's linked mask. Lens Blur remains Pro (ProGate: amount > 0), unchanged. No paywall/StoreKit/watermark code touched.

15 Oct (Claude, shared feature from main PR #11): Auto rewritten — every value measured from the photo (no fixed contrast/vibrance/clarity), subject/centre metering with scene-key protection, HDR-aware highlights, gentle auto white balance, edge cases guarded; runs off the main thread. Auto now only sets Light and Color values (Clarity no longer touched), which ProGate treats as free, so Auto on its own no longer makes a free photo Pro. Engine test now compiles Auto.swift. No Store code touched.

15 Oct evening (Claude, shared fix from main PR #14, SideStore 0.1.242): crash when dragging Lens Blur amount fast. Canvas keeps at most two GPU frames in flight; Lens Blur renders at half resolution while its slider moves; histogram renders skip Lens Blur; disc radius capped; memory warnings clear Core Image caches. No Store code touched.

## 18 Oct 2026: Heal at 1280 px (from main #26, SideStore 0.1.248)
Big LaMa is converted in CI at 1280 x 1280 (`.github/ci/heal-convert/`: IOPaint big-lama.pt, MD5-verified, CoreMLaMa
recipe, float32), falling back to the pinned 800 px package if the conversion fails. `EditSession.healSide` is read
from the model. Engine test on main: 1049 checks passed. Heal is Pro in the App Store build (unchanged gating).
Before App Store release: check the phone's RAM and use 800 px on low-memory iPhones (6-8 GB), see the crash/memory work.

## 18 Oct 2026: Heal fixes (from main #28, SideStore 0.1.256)
No main-thread model load (fixes the freeze/kill on first Heal in 0.1.248), "Preparing Heal…" while the model loads in
the background, full-resolution patches with real texture for big removals (lumenHealDetail kernel), and memory freed
before Heal / Remove people. Engine test on main: 1051 checks passed.

## 19 Oct 2026: Heal made safe (from main #30 and #31, SideStore 0.1.266)
Texture step switched off (`healDetailEnabled = false`: it copied streaks and a flipped ghost of the person from the
mirrored edge), back to the pinned 800 px Heal model (the 1280 px model pushed Lumen past iOS's ~3.4 GB per-app limit:
owner's JetsamEvent, killed at 3388 MB) and the 100 % view's full-size copy capped at 4096 px. The 1280 conversion stays
in `.github/ci/heal-convert/` for later, once memory allows. Heal stays Pro. No Store code touched.

## 19 Oct 2026: Diagnostics and the stability batch (from main #32 and #34, SideStore 0.1.274 / 0.1.288)
- ⋯ → Send diagnostics… (editor and library): memory log plus MetricKit crash/hang reports in Library/Diagnostics,
  shared only when the user chooses. Nothing leaves the phone otherwise (privacy policy: no change needed, nothing is
  collected or sent by the app).
- AI models load when needed and are released (Heal 30 s after leaving the tool, all on a memory warning).
- Undo history written at most every 2 s.
- Memory guard before the 100 % view, Heal and export build big copies.
- After a heal, depth/subject/sky masks are re-measured from the healed photo (Lens Blur no longer leaves a sharp hole
  where a removed person was).
No Store code touched; Pro gating unchanged.

## 19 Oct 2026: Code review fixes (from main #38, SideStore 0.1.29x)
Editor stability (no model loads while drawing, stale 100 % copies dropped, Heal never stuck, no undo/swipe mid-heal or
export, AI masks re-run for a re-decoded photo), exports keep EXIF/date/GPS, sidecar migration keeps Lens Blur
focus/mask/strength, damaged edits kept as a copy, batch export frees GPU memory per photo and keeps the screen awake,
Files imports off the main thread, undo history written 0.2 s after a save and on leaving the screen, UI tests scroll the
tool bar. Difference from main: library batch export still uses the saved settings (main uses the editor's start
settings, HDR on for never-opened RAWs) because HDR is Pro here and the export gate checks saved settings.

## 19 Oct 2026: Remove people finds more people (from main #41)
Body detector + closer segmentation for bodies the whole-photo pass missed, 3072 px decode, up to 30 people. Heal and
Remove people stay Pro. No Store code changed.

## 19 Oct 2026: Heal uses less memory; CI memory budget test (from main #44)
Heal decodes at 2x the model's resolution and renders only its square once (photo side ~2.3 GB -> ~0.5 GB on the CI
Mac); the hole is mirrored at photo edges like the context; engine-test "Memory budget" step with per-step budgets.
Heal stays Pro and on the 800 px model. No Store code changed.

## 19 Oct 2026: Library thumbnails decoded once (from main #46, SideStore 0.1.333)
Decoded thumbnails cached per photo and version, so a finished thumbnail no longer makes every cell re-read its JPEG.
No Store code changed.

## 19 Oct 2026: Undo history off the main thread, brush cache, Heal and bright glints (from main #51)
Undo history read in the background when a photo opens; brush masks cached by a cheap key, newest version per brush;
Heal scales by the square's 99.5 % brightness (a glint no longer darkens the model's input) and keeps brighter
highlights outside the hole; export memory probes. No Store code changed.

## 20 Oct 2026: AI Denoise (from main #55, SideStore 0.1.360)
SCUNet real-noise model (Apache-2.0, pinned weights) converted in CI, run on the Neural Engine tile by tile, cleaned copy
kept per photo; Detail → AI Denoise slider. Pro: `usesProFeatures` returns true when aiDenoise > 0 (like HDR, Heal and
Lens Blur). tester-build.yml (main-only, personal tester builds) is not part of sandbox.

## 20 Oct 2026: AI Denoise as a one-off action (from main #58, SideStore 0.1.371)
Detail button → locked screen with progress, time left and Cancel; strength slider afterwards. Stops in the background
and restarts on return; first clean races Neural Engine vs GPU and keeps the faster; timings in diagnostics. Still Pro
(aiDenoise > 0). No Store code changed.

## 20 Oct 2026: AI Denoise model NAFNet; diagnostics only recent (from main #60)
SCUNet took 4+ minutes for 24 MP on the owner's iPhone 17 Pro Max; replaced by NAFNet-SIDD-width32 (MIT, all
convolutions, about a quarter of the work), Neural Engine only (no GPU probe), speed logged from the first tiles.
Send diagnostics holds only the last 3 launches and recent iOS reports. Still Pro (aiDenoise > 0). No Store code changed.

## 20 Oct 2026: AI Denoise back to SCUNet, on the GPU (from main #62 + #63)
NAFNet wrecked bright tiles on the Neural Engine (float16 overflow) and left half the noise. Back to SCUNet, run on the
GPU (CI: CPU). Every tile is checked against its input and a wrong one redone on the CPU. Still Pro. No Store code changed.

## 20 Oct 2026: AI Denoise faster (from main #65)
Compact shifted-window attention mask (same output, far less memory), GPU float16 sums, model made ready in the
background when Detail opens. Still Pro. No Store code changed.

## 21 Oct 2026: AI Denoise reopening, memory, Detail layout (from main #68, SideStore 0.1.400)
16 px tile overlap (117 tiles for 24 MP), results stored raw + a 2560 px preview copy (fast reopening, no 400 MB
spikes), model released after a clean and in the background (a crash on return to the screen). Detail: AI Denoise is a
pill in the actions row with Reset on the right. Still Pro (aiDenoise > 0). No Store code changed.

## 21 Oct 2026: AI Denoise on big photos (from main #70, SideStore 0.1.405)
Result written strip by strip; photo read whole only when memory allows, else in strips (48 MP ProRAW closed Lumen).
Still Pro. No Store code changed.

## 21 Oct 2026: crash report, memory after AI Denoise (from main #72, SideStore 0.1.414)
Send diagnostics: short crash report first after a crash (last 3 closures, step before each), compact full report.
AI Denoise reads through its own decoder; 4096 px small copy; photo-open steps logged. No Store code changed.

## 21 Oct 2026: big photos, edge cases, one clean for HDR on/off (from main #74, #75, #76; SideStore 0.1.436+)
100 % view memory scaled by photo size; crash report and step logging; no automatic AI Denoise cleans; original view
without AI Denoise; paste/presets keep own AI Denoise; export masks on big photos from a small copy; storage hygiene;
diagnostics heartbeat; AI Denoise keeps the noise (one clean for HDR on and off), pauses and resumes (also after a
swipe-away), opt-in batch paste (max 5) with progress; paste keeps flips/perspective/Heal on-off. AI Denoise stays Pro
(aiDenoise > 0). No Store code changed.

## 21 Oct 2026: heavy-work coordinator, History, paste masks, design pass (from main #77)
Memory-heavy jobs start only with room for the photo's size (HeavyWork.swift); ⋯ → History lists edit steps (tap to
go back; free); library "Paste the look and masks" (AI masks worked out again per photo; masks stay Pro at export);
Lens Blur, Heal and Curve actions as pill rows. No Store code changed.

## 22 Oct 2026: ChatGPT integration candidate, reviewed (branch integration-candidate-review)
Taken: tester expiry screen (TesterExpiry.swift, LumenApp), the batch-export HDR rule by build type (App Store: saved settings; SideStore/tester: as the editor shows), main's Lens Blur pinch line, UI test updates (tester-expired, tapTool), UI-PRINCIPLES.md, PRODUCT-BRIEF.md. Not taken: tester-build.yml (main only: a tester IPA built from sandbox would be unlocked). Added a CI check that the App Store build has no LumenTesterExpires key. Store files unchanged.

## 22 Oct 2026: App Store name, HDR start only for Pro, library paste (from main #81)
App Store display name is "Lumen RAW" (Angelo): set on the generated Info.plist in the App Store build step and
checked after it; project.yml and the SideStore app keep "Lumen". Bundle ID and product IDs are still placeholders.
A never-edited RAW opens in HDR only for Pro users in the App Store build (it used to make every free user's RAW Pro:
watermark plus paywall). Library paste: Look only / Look and masks / Everything / Choose… (pick tools; Pro tools are
still gated at export).

## 22 Oct 2026: AI Denoise keeps the 100% copy out of memory (from main #83)
A 100% copy that finished while a clean ran was kept beside the model (iOS closed Lumen). Now dropped; mask models released; a short job waits up to 3 s for memory. No Store code changed.

## 22 Oct 2026: final IDs, lifetime purchase, StoreKit test, listing drafts
Bundle com.lumenraw.app (CI builds and screenshots); products com.lumenraw.pro.monthly / .annual / .lifetime
(1.49 GBP with 7-day trial / 9.99 / 29.99 non-consumable, which counts as paid Pro). Paywall shows all three and says
"Lumen RAW Pro"; watermark text "Lumen RAW" (LumenMark). Tests/store: StoreKit configuration plus a hosted unit test
(appstore-tests.yml = project.yml + LumenStoreTests) run by app-store-sandbox.yml: products and prices load, trial
offered, lifetime and annual unlock Pro, monthly starts as a trial and locks again when it expires. Listing copy, app
privacy and support pages drafted in docs/appstore/ (not published).

## 22 Oct 2026: memory budget by device (from main #85); App Store build is iPhone only
MemoryBudget sizes the preview, 100 % copy and AI Denoise from the app's measured memory limit; Lumen.entitlements
asks for the Increased Memory Limit (enable it on the App ID in the developer account; archive with
CODE_SIGN_ENTITLEMENTS=Lumen.entitlements). App Store build: TARGETED_DEVICE_FAMILY=1, checked in CI (no iPad
screenshots or iPad review for 1.0). StoreKit test: all four checks pass (purchases need a moment before
currentEntitlements shows them; the app refreshes on Transaction.updates, so users are not affected).

## 22 Oct 2026: TestFlight upload workflow, release checklist, feature freeze
`testflight.yml` (manual, sandbox only): archives the App Store build (APP_STORE, com.lumenraw.app, iPhone only, Lumen RAW,
version 1.0 build = run number, Increased Memory Limit entitlement), signs it in Apple's cloud with an App Store Connect
API key and uploads to TestFlight. Needs secrets ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8, APPLE_TEAM_ID (Angelo adds them).
`docs/appstore/RELEASE-CHECKLIST.md`: the submit bar, the 10-minute phone run-through, Angelo's steps. Feature freeze until 1.0.

## 23 Oct 2026: sandbox rebuilt on main's quality work (main 0.1.516)
The sandbox had drifted far behind main (a trial merge gave 20 conflicts), so this branch is main's code with the Store
layer put back on top, not a merge. Everything main learned since 14 Oct is now here too: the tolerant edits file and
history loading, Copy edits…/Paste (also from the library), delete that leaves the list at once, failed-save banner and
retry, the HeavyWork fixes, AI mask memo, export and import fixes (see main's docs/QUALITY-CHECKLIST.md).
Store code is only in: `Sources/Store/`, `PaywallView`, `LumenMark`, `AppPrivacyView`, and `#if APP_STORE` hooks in
`EditorView` (export gate, paywall sheet, watermark, screenshot demos), `LibraryView` (batch export gate, paywall sheet),
`LibraryStore` (batch export refuses Pro edits for free users; a never-opened RAW starts in HDR only for Pro) and `Demo.swift`
(`paywall`, `proEdits`, `noWM`). Everything else is main's file unchanged. Checked by app-store-sandbox.yml (flag off and on,
ProGate checks, StoreKit test, screenshots).

## 24 Oct 2026: sandbox follows main to 0.1.608
Main merges since the rebuild came in as plain `git merge origin/main` (no conflicts, no Store code touched): batches 11-17 (careful mode,
the original copy once at a time, the Heal model on the GPU and loaded alone, lighter canvas context, AI Denoise needs free memory,
AI Denoise model at 256 px tiles and kept loaded). Each port was checked with `app-store-sandbox.yml -f checks_only=true`. The RAW format
matrix workflow (sandbox only) had not compiled since `LoadedModel.swift` joined the engine files; its compile list is fixed and its run
passes. Not submitted; the App Store version waits for Apple Developer enrolment and Angelo's instruction.

## 25 Oct 2026: crop rework (main #147)
Merged from main: the crop rework (stage with a margin, pinch and move the photo under the frame, 48 pt handles, the straighten
dial; crop version 2 keeps the crop on real photo exactly, "Keep the crop inside the photo") and the
SideStore screenshots. One conflict, in `EditorView`'s photo area: in Crop the stage draws the photo itself, so the canvas and the
free-user watermark are not drawn there (`tool != .crop`); exports are watermarked as before. Crop stays free. The RAW format
matrix compiles `CropMath.swift` and `CropFit.swift` (Graph uses them). Checked with `app-store-sandbox.yml -f checks_only=true`.

## 25 Oct 2026: Straighten and Perspective tabs (main crop-perspective); line endings
Merged from main: the crop panel is Crop | Straighten | Perspective like Photomator (a ruler for straighten and for perspective,
chips choose what the perspective ruler changes, big tiles, a fine grid while a ruler turns, no picture behind the top buttons).
No Store code involved; crop stays free. Before it, a fix: the crop port's merge (#148) had been committed with Windows line
endings (CRLF) in 16 files; they are LF again (no content change), so merges from main stop conflicting on every line. Commit
sandbox merges with the repository's normal settings (never `core.autocrlf=false` on this Windows clone).

## 25 Oct 2026: one zoom in Crop, no hidden overshoot at limits (main crop-one-zoom)
Merged from main: pinching is the crop's only zoom (zoom tile "2.4×" back to 1×, badge while pinching; Scale and Move show in
Perspective only with Fill frame off), and `EndStop`: sliders, rulers, crop drags and pinch, photo pan, curve points, Depth
soft edges and the panel handle respond at once when the finger turns back at a limit. No Store code involved.

## 25 Oct 2026: Brightness (main #155, SideStore 0.1.679)
Merged from main: Brightness under Exposure (mid-tones up or down, white and black kept) and in masks' Adjust; Auto shares
its brightening between Exposure and Brightness. Light stays free, so Brightness is free; inside a mask it is part of Masks
(Pro) like every mask adjustment. No Store code changed.

## 25 Oct 2026: canvas draws nothing outside the photo (main #157, SideStore 0.1.684)
Merged from main: the canvas fills the whole texture at its own size and crops the photo to its place on screen (a mask's
tint showed around the photo on the owner's phone until the next zoom); a picture of the wrong shape is noted in Send
diagnostics. Shared code only.

## 25 Oct 2026: sliders (main #160, SideStore 0.1.692)
Merged from main: a detent at neutral instead of a snap zone (values next to 0 can be chosen), slider haptics and a livelier
look; tests and notes for 0.1.673-0.1.684 (#158). Shared code only.

## 26 Oct 2026: curves, two-swipe exit, radial handles (main #163, #164; SideStore 0.1.700, 0.1.703)
Merged from main: Darkroom-style curves (whole end points, five starting points, zone names, hold a point to remove it),
the editor defers the bottom-edge swipe (two swipes to leave), radial masks with a size handle on every side kept on
screen and 48 pt grab areas. Curves are Pro here as before; nothing Store-specific changed.

## 27 Oct 2026: adjustment-engine quality (from main candidate #167)
Shared candidate 9d6bba0: monotone tone composition, bounded detail/noise, gentle Dehaze, Bradford relative white
balance, edge-aware Clarity analysis, perceptual P3 gamut mapping, B&W grading, honest HDR export failures. Old
recipes keep processing 1; new/reset recipes use 2 (edits format 2 protects rollback files). UI unchanged. Apple RAW
base retained for Heal/AI residual compatibility. Light/Colour remain free; existing Pro gates unchanged. No Store
code changed. Prepared while main validation runs; sandbox OFF/ON compile check pending, merge follows main release.
Existing local MARKETING.md and docs/appstore/LISTING.md edits are unrelated and are not included in this port.

Follow-up: aligned shared code/tests with main bc0c788. Clamp v2 analysis resampling at the photo edge; exact-linear
constant regressions pass in main's 44-check GPU run 40604409841. Focused engine mode and early render artifact
upload speed diagnosis. First sandbox OFF/ON builds passed; final compile check follows this commit. No Store changes.

## 28 Oct 2026: Clarity and one renderer (from main #169)
Shared candidate through 73c0abf: stronger bounded Clarity band with edge/flat protection; all old edits/history/
presets/paste use current processing, exact recovery JSON retained before overwrite, edits format 3, old shader/
white-balance/gamut dispatch removed and thumbnails refreshed. Preserve Heal references in migration backups.
Fix denoise preview rounding and repair existing small copies from unchanged full residuals, paused decoder identity,
rejected person-mask label reuse, and explicit crop versions in tolerant loading. No model/runtime changes.
Detail/AI/Heal keep existing Pro gates, Light/Colour remain free. No Store code changed. Tests/store alone gains
a bounded local-catalog readiness preflight after the prior cold first-test failure; production product loading,
prices and purchase assertions unchanged. OFF/ON/StoreKit validation pending; merge follows personal publication.
Unrelated MARKETING.md and docs/appstore/LISTING.md edits excluded.
