# SANDBOX-LOG — what was drafted and what Claude must check

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
