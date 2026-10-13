# SANDBOX-LOG — what was drafted and what Claude must check

**Session:** 13 Oct 2026, by the local LLM (PC ASSISTANT, on Angelo's PC) — drafting the App
Store code per `docs/APPSTORE-PLAN.md` (v2, export-gate model) and `SANDBOX-BRIEF.md`.

## What was drafted (all new files unless noted)

| File | What it is |
|---|---|
| `Sources/Store/LumenStore.swift` | StoreKit 2 store: products, entitlements, purchase, restore, `ProStatus`. `#if APP_STORE` = real StoreKit; `#else` = always-Pro stub (SideStore builds). |
| `Sources/Store/ProGate.swift` | `EditSettings.usesProFeatures` — the free/Pro line: free = Light + Color + crop/straighten/turns + presets; Pro = Grade, Curve, Detail, HDR, masks, heals. Respects the Edits-sheet `disabled` switches. |
| `Sources/Views/PaywallView.swift` | The export-gate paywall: both products with real prices, trial line, Restore, privacy line, free close path. |
| `Sources/Views/LumaforgeMark.swift` | Watermark (placeholder glyph + "Lumaforge" name). Two placements (corner/bottom) — Angelo picks. |
| `.github/workflows/app-store-sandbox.yml` | Manual-only compile check: proves the draft builds with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=APP_STORE` + bundle ID override on GitHub's Mac. No signing (documented for Gate 4). |
| `Sources/Views/EditorView.swift` (EDITED — 4 small hooks, all `#if APP_STORE`) | 1) `requestExport()` gate function, 2) paywall sheet, 3) export button calls the gate + small crown badge, 4) watermark over the canvas. |

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
6. **Sandbox compile-check workflow:** run it manually from the Actions tab (workflow_dispatch)
   to prove the draft builds. It does NOT compile the new Store files into the engine test —
   the engine test compiles a fixed file list, so it's unaffected by this draft (which is the
   point: the draft can't break the engine).

## Build/test status (live on GitHub's Mac, 13 Oct)

The `sandbox/` branch runs the repo's normal CI on every push, plus a new manual/branch
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
