# SANDBOX BRIEF — for the local LLM (read first)

You are working in a **disposable draft copy** of the Lumen repo. Read this before doing anything.

## What this folder is

- `C:\Users\pc user\Downloads\GP work\Lumen-Sandbox` — a copy of the real repo
  (`github.com/AngeloP46/lumen`), working on the branch **`sandbox/`** only.
- Your job: **draft** the App Store code described in `docs/APPSTORE-PLAN.md` (read it fully first),
  and **push your commits to the `sandbox/` branch** so the repo's automatic test suite runs on
  your work (the engine test compiles the engine and renders a real Sony A9 ARW; the results come
  back as preview images on GitHub).
- When the main developer (Claude) comes back in ~48h, he will review the `sandbox/` branch,
  fix it, and rebuild it in the real repo. **Nothing you write here is final — but it must be
  honest, well-commented, and clearly marked as a draft.**

**How to check the test results:** after pushing, the repo's "Engine test" workflow runs on the
`sandbox/` branch automatically. Results are at the GitHub repo → Actions tab (pass/fail), and
rendered preview sheets are uploaded as a `test-previews` GitHub release and `engine-renders`
artifacts. If a push makes the engine test fail, **fix and re-push** — that's the loop.
If the test fails for reasons that pre-date you (check by looking at main's last run), note it in
`SANDBOX-LOG.md` and don't chase it.

## Hard rules (breaking any of them wastes the main developer's day)

1. **Never touch the SideStore pipeline or anything it reads.** Frozen files:
   `project.yml`, `.github/workflows/` (the existing SideStore workflow), the model-fetch
   scripts, and any file the current build depends on if you're unsure — leave it alone.
2. **Push rules — read carefully:**
   - The remote `origin` points at the real repo and is **already authenticated** via a token
     embedded in the remote URL. **Never read, print, copy or edit `.git/config`.** The token
     only has permission on the `lumen` repo's *contents*; it cannot do anything else, but it
     still must not be handled.
   - Push **only** the `sandbox/` branch: `git push origin sandbox/` (or `git push -u origin
     sandbox/` the first time). **Never push `main` or any other branch. Never delete or force-
     push anything.**
   - Small, descriptive commits per logical piece, pushed in batches (a few times a session is
     fine; don't push after every file).
   - The push triggers the repo's normal CI on the branch. **The SideStore feed is only ever
     published from `main`**, so your pushes can't affect the owner's phone build — but keep
     the frozen-files rule (rule 1) anyway.
3. **New code = new files only** under `Sources/Store/`, `Sources/Views/PaywallView.swift`
   (or similar), plus a **new** workflow file `.github/workflows/app-store-sandbox.yml`
   (named `sandbox` on purpose — the real one gets a clean name later).
4. **You cannot compile.** There is no Xcode on this PC. Do not pretend to test. Instead:
   - keep every draft file self-consistent and idiomatic (Swift 5, SwiftUI, iOS 18, StoreKit 2);
   - at the top of every new file, add a comment: `// DRAFT — sandbox, review required: <what to check>`;
   - keep a running log of what you did and what you're unsure about (see `SANDBOX-LOG.md`).
5. **The build-flag contract** (from the plan §2.1): the paywall/StoreKit/watermark code must be
   designed so that when the App Store compilation flag is OFF (SideStore build), none of it is
   compiled in and the app behaves exactly as today (all Pro features on, no watermark, no
   paywall). Use a compile condition (e.g. `#if APP_STORE`) with a documented stub for the
   non-App-Store path. Show clearly where the flag gets set — in the NEW sandbox workflow only.
6. **The export gate** (plan §4.1): free export = Light & Color + crop/rotate + presets only.
   Any Pro feature active (curves, sharpen/denoise, HDR, any mask, heal) → export triggers the
   paywall path (or the stub "always Pro" path when the flag is off). Base the check on
   `EditSettings` state — read that file first; it already knows which sections are active.
7. **Watermark** (plan §5.1): pure view-layer overlay, ~25–35% of screen width, corner, 15–25%
   opacity, only when a Pro feature is active AND the user is not Pro AND flag is on.
   Two placement variants so Angelo can pick (e.g. `WatermarkCorner` / `WatermarkBottom`).
8. **Placeholder name everywhere: "Lumaforge"** (display name, paywall copy, TestFlight name).
   Keep it in ONE constant so the real name is a one-line swap.
9. **Prices are never hardcoded** — always from the loaded `Product`. Product IDs to use in the
   draft: `lumaforge.pro.monthly`, `lumaforge.pro.annual`.
10. **Do not edit existing files** (EditorView, EditorViewModel, Engine, Masks, Heal, etc.)
    EXCEPT where wiring the gate genuinely requires a small hook — in that case make the
    smallest possible change, wrap it in `#if APP_STORE` where possible, and log it in
    `SANDBOX-LOG.md` with the exact reason. The main developer will re-decide those touch points.

## Suggested order of work

1. Read `docs/APPSTORE-PLAN.md` fully, then `Sources/Edit/EditSettings.swift`,
   `Sources/Edit/EditorViewModel.swift` (export path), `Sources/Views/ExportViews.swift`,
   `project.yml`, and the existing `.github/workflows/` (read-only).
2. Draft `Sources/Store/StoreModel.swift` — StoreKit 2: products, entitlements, purchase,
   restore, `ProStatus` enum, plus the `#if !APP_STORE` stub (always Pro, no products).
3. Draft `Sources/Views/PaywallView.swift` — export-gate paywall per plan §4.4.
4. Draft the watermark overlay (two variants) per plan §5.1.
5. Draft the export-gate hook points (minimal edits, logged).
6. Draft `.github/workflows/app-store-sandbox.yml` — new file, mirrors the SideStore workflow's
   model-fetch steps, adds: bundle ID override (`com.sandbox.lumaforge` — deliberately not the
   real ID), the `APP_STORE` compile flag, signing from secrets (documented, placeholder),
   archive → export IPA → (commented-out) upload step.
7. Write `SANDBOX-LOG.md`: what you drafted, the touch points you had to make in existing
   files, every open question, and a "first things to check when building" list.

## When you finish

Commit everything with the message `sandbox: draft App Store code (review required)`.
Stop. Do not try to build, do not try to push, do not touch the real repo folder.
