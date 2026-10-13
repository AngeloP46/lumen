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

## What to check first when building in the real repo

1. Delete/review everything in `Sources/Store/`, `PaywallView.swift`, `LumaforgeMark.swift`,
   and the 4 `#if APP_STORE` hooks in `EditorView.swift` (search the repo for "DRAFT — sandbox").
2. Decide the compile-condition name — I used `APP_STORE`; confirm XcodeGen passes
   `SWIFT_ACTIVE_COMPILATION_CONDITIONS` through to the app target (the sandbox workflow
   sets it on the command line, which should work).
3. The stub path (`#else` in LumenStore) must be what SideStore builds compile — verify a
   SideStore pipeline run still produces a normal IPA (brief rule 1's safety check).
4. RAW test matrix is still outstanding (plan Gate 2) — that's a real-repo task, not draftable here.
