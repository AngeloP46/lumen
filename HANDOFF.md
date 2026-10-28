# Lumen App Store project — status & hand-off (for a new chat)

## 28 October 2026: Clarity and single-engine continuation
Shared candidate from personal PR #169, through 73c0abf, is on `sandbox-imaging-quality-v2` (PR #168).
Clarity now uses a useful medium-detail band; all old recipes/history/presets/paste use one renderer with exact
JSON recovery copies before overwrite. Legacy render code removed; original photos/values retained. Denoise
preview-border/repair, paused-decoder identity, person-mask label reuse and tolerant crop-version fixes included.
The same shared tests/review reports are here. Existing Pro gates and pricing unchanged; no Store code changed.
The StoreKit fixture test now waits for its local catalog before exercising the unchanged production loader;
the prior first-test catalog failure needs a clean simulator rerun. Personal validation and sandbox checks pending.
Unrelated MARKETING.md and docs/appstore/LISTING.md edits remain outside the port.

## 27 October 2026: adjustment-engine candidate
Shared processing improvements from personal PR #167 are on `sandbox-imaging-quality-v2`, final main source bc0c788.
Read `docs/IMAGING-QUALITY.md` for algorithms, legacy recipes and rollback. No Store code or pricing changed.
First OFF/ON builds passed; the final boundary/test follow-up is being checked. Merge after the personal release. Existing local edits
in MARKETING.md and docs/appstore/LISTING.md are unrelated and were preserved outside this candidate's commits.

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


## Current shared revisions — complete, 14 October
Shared Lens Blur/photo information merged to personal main through protected PR #2
(main 34b72c3), mirrored here; sandbox Store code unchanged. Angelo approved publication: SideStore 0.1.207/build 207 is published, fully unlocked.
Run 38634930064 succeeded on main fbe5b7a; feed URL/size/hash matched Lumen-207.ipa
(322324910 bytes; SHA256 4d5b0b1faa801f21a87ce2c4401e87135783ce9041b535dd556c0b0eaede94c6).

Final app source d383f7e (test revision e9d997b): engine/metadata 38631365097 passed
79 checks, including nine standard camera-make fixtures and Sony RAW preview/JPEG export;
focused UI 38631369309 passed one combined test with zero failures, screenshots checked;
IPA 38631360377 and PR/readiness 38632032581 passed. Sandbox policy and OFF/ON builds
passed in 38631373218. Shared source parity checked; no Store files changed.

Whole/selected-instance subject protection and subject depth distribution, first-use 8,
progressive far blur, calibrated distance, full depth feather travel/graphic, inline
linked-mask refinement, transient optional slider preview and standard metadata info
button implemented. Saved zero/off preserved; activation does not mark untouched photos
edited. Read ../Lumen/PRODUCT-BRIEF.md: iOS/RAW/all popular brands, cheaper Lightroom
alternative; personal app free/unlocked and sandbox charging decisions separate.

Things to verify: update to 0.1.207, then phone RAW/ProRAW subject edges,
brush feel, HDR and speed. Touch tests use synthetic depth/subject coverage, not AI proof.
Troubleshooting: manual distance/range/brush fallback if no subject; missing EXIF stays
missing. Auto Level remains image-based horizon/edge analysis, not camera roll data.
checks_only now skips samples, simulator boot and screenshot artifact setup.

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

Security build, Heal deletion (8 cases), sandbox OFF/ON and protected PR checks passed.
SideStore security-only 0.1.200 publication succeeded and feed metadata verified.
No payment changes.

New workflow: use a work branch + PR, run relevant checks, merge the checked PR via
GitHub. Notes-only PRs skip the Mac build and still run Release readiness. A [skip ci]
commit requires manual build.yml on that exact branch before merging; after merge
with skipped CI, manually dispatch build.yml on main to publish the update.
Do not force-push main or use the older direct-push instructions below.

Public unrestricted SideStore distribution remains unchanged for the owner's update
feed; distribution before selling Pro is still a business decision. GitHub account
two-factor authentication was not verifiable through the current API token.

Lens Blur revisions followed the security update; see the completed status above.
They were not included in security-only SideStore 0.1.200.


## Shared editor improvements — 14 October, published to SideStore

**SideStore 0.1.197 is published and its source.json verified** (build 197, run
38604801375, app build commit cbc8405; app source feef0e4). The same shared code is
in sandbox d09da21 plus notes-only updates. SideStore remains paywall, subscription
and watermark free. Store code/project/build flags were not merged into personal main.

Angelo authorized these shared improvements and Lens Blur explicitly:
- Maximum elastic pinch release keeps the last touched photo point in place.
- Closing the editing panel centres the image; clipping ignores transparent margins.
- Depth feather sliders can reach their full range; bar handles select the actual band.
- Per-photo undo/redo is stored with edits atomically, capped at 100. Old discarded
  history cannot be reconstructed. Redo survives reopening; new edits clear it.
- Standalone Lens Blur beside Detail, readable scrolling toolbar, tap focus,
  amount/distance/range and optional background refinement with existing mask brushes.
  Camera RAW depth estimation is the primary path; Portrait depth extraction was not added.
- Preset/paste keep each photo's blur and refinement. Blur applies before geometry,
  scales with source size and applies to HDR gain as well. Missing depth cannot silently
  omit active depth blur on export; no-effect states preserve pixels exactly.

Validation passed: final IPA 38602637294, focused combined UI 38602633151,
depth sliders 38599011360, full engine 38600705716 (969 checks), focused Lens Blur
and real Sony ARW preview/JPEG export 38602642007 (32 checks). Final screenshots
inspected for readable toolbar and panels above it. Source frozen at feef0e4 before
these final runs; subsequent commits are notes. Original shared fixes also passed
UI/build/engine before the feature was added.

Sandbox policy and OFF/ON simulator builds passed their steps in 38600345922;
optional duplicate screenshot capture was cancelled. Do not call that whole run green.
Sandbox-only ProGate requires Pro for active Lens Blur, including preset looks;
zero/disabled blur remains free. Personal build has no gate. Purchases still need real
StoreKit testing separately from compilation, as noted in the earlier App Store review.

Phone follow-up: estimated-depth boundaries/background colour bleed may need Refine
background. Verify Sony ARW focus edges, speed, HDR and exported look on the phone;
the simulator touch fixture uses synthetic depth and does not prove model quality.
Owner updates normally: LocalDevVPN on, SideStore My Apps pull to refresh, Update Lumen.

## Earlier App Store export review — Codex fixes, 14 Oct 2026

Angelo authorized addressing the review findings. Local fixes supersede the older issue lists
below: batch and single export now both enforce Pro at the UI and underlying export entry
points; editor observes subscription state; offer eligibility/real trial information replace
hardcoded promises and expiry heuristics; grace entitlements are retained; foreground and
expiry refreshes added; restore errors are shown; neutral grading/masks/sharpen controls no
longer count as Pro. Added an in-app privacy notice and Apple's standard Terms link.

Added export-policy regression checks and a flag-OFF simulator build to the sandbox compile
workflow. Strengthened RAW checks to apply an edit and reopen output, checking dimensions and
16-bit TIFF. CR2 sample added from raw.pixls.us with a pinned SHA-256; genuine iPhone ProRAW still missing. No main code changes or SideStore
publication. Export-policy checks, flag-OFF simulator build, flag-ON simulator build, six-format RAW matrix and editing-engine tests have passed. Screenshot capture passed; watermark/paywall images were visually checked. The 70-test interface suite passed with zero failures at b8580d1. Latest e4698a9 preset checks and both flag configurations also passed; its screenshot capture also passed.

Still unresolved: publish an app-specific privacy URL for App Store metadata (current website
notice is waitlist-only); final pricing/name; real StoreKit purchase/restore/grace testing; real phone watermark appearance.
Do not treat source review or simulator compilation as proof of working purchases.

**Last updated:** 14 Oct 2026 (Codex fixes, validation and relocation authorized by Angelo)


## Landing page V5 — 14 October update

Angelo asked for the landing-page copy pass after the app fixes. Updated the canonical
landing-page/index.html and thanks.html with direct descriptions of the real app, examples
and founder story. Removed generic slogans/contrasts, one-tap removal wording, and vague
value claims. Free basic/preset export wording reflects Angelo's latest decision.

Design/CSS, screenshots, videos, script.js, pricing options, form attributes/fields, consent
and privacy notice preserved. Revised hero wraps onto two lines; other structure unchanged.
Browser checked at 1440x1000 and 390x844: all page images loaded, no horizontal overflow,
pricing selection and comparison slider worked. No signup submitted. No Netlify deployment.

Source: C:\Users\pc user\Projects\app development\landing-page
Deliverable: C:\Users\pc user\Projects\app development\deliverables\lumen-landing-v5-clear-copy.zip
Rollback: deliverables\lumen-landing-v4-backup.zip; original download also preserved.
The ZIP has index.html at its root and contains all 26 files.
## One-line summary

Lumen (free RAW photo editor for iPhone, `github.com/AngeloP46/lumen`) is being prepared for
the App Store with a Photomator-style **export-gate subscription** model. The main developer
(Claude, Anthropic) is offline ~48h; a capable **local LLM** is drafting the App Store code in
an isolated sandbox in the meantime.

## Where everything lives

| Thing | Where |
|---|---|
| The full plan (source of truth for the work) | `C:\Users\pc user\Projects\app development\Lumen\docs\APPSTORE-PLAN.md` |
| Real repo (Claude works here, pushes to GitHub) | `C:\Users\pc user\Projects\app development\Lumen` |
| Sandbox (local LLM works here — do not edit it yourself) | `C:\Users\pc user\Projects\app development\Lumen-Sandbox` |
| Sandbox rules the local LLM must follow | `Lumen-Sandbox\SANDBOX-BRIEF.md` |
| Local LLM's own work log (it writes this) | `Lumen-Sandbox\SANDBOX-LOG.md` (created by the LLM) |
| GitHub branch with the local LLM's pushed work | `sandbox` branch on github.com/AngeloP46/lumen — https://github.com/AngeloP46/lumen/tree/sandbox |
| Test results from GitHub | repo → **Actions** tab (pass/fail) and the `test-previews` GitHub release (rendered ARW preview sheets) |

## Decisions already made (all locked, see plan §11)

- **Free export:** Light & Color + crop/rotate + presets only. **Pro:** curves, detail, HDR, all
  masks, heal → export requires the subscription.
- **Prices:** ≈£1/month (7-day trial) + ≈£8/year → closest Apple UK tiers.
- **Watermark:** tiled diagonal "Lumaforge" text across the whole photo, ~45 % opacity, white
  with a dark shadow, Pro-edited previews only, App Store build only. (14 Oct: replaced a
  single badge — Angelo: the first 30 %-material version was invisible on bright skies, the
  solid-badge version "looked like a button"; tiled protection style is the agreed look.)
- **iPhone-only** at launch, **instant release to 100%**, **worldwide, English only**.
- **Name:** placeholder **"Lumaforge"** in all code (that name is taken on the App Store — final
  name is Angelo's to pick before Gate 4; "Lumen" is also taken).
- **SideStore build stays frozen** — no paywall, no watermark, everything works. The existing
  `build.yml` (SideStore feed) and `project.yml` must never change for this work.

## What happened in the last chat (timeline)

1. Researched and wrote `docs/APPSTORE-PLAN.md` (v2, export-gate model) — gates 1–5, Claude's
   build spec, Apple setup steps, marketing plan, RAW-format findings.
2. **RAW finding:** the app already decodes all major camera RAW via Apple's CIRAWFilter —
   the "Sony-only" problem is mostly wording, plus a test matrix to prove (CR2/CR3/NEF/RAF/
   ARW/DNG/ProRAW must open, edit, export — hard requirement before Gate 2).
3. Built the sandbox: clone in `Lumen-Sandbox`, brief written, `sandbox` branch created on
   GitHub and pushed. A 2-day fine-grained token (repo: lumen, Contents read/write) is embedded
   in the sandbox's `origin` remote — **it expires ~15 Oct**; after that the sandbox cannot
   push. Do not print or copy the remote URL (it contains the token).
4. Angelo created the token at github.com/settings/tokens; if it's revoked/expired, re-pointing
   the sandbox remote needs a fresh token (see SANDBOX-BRIEF for the rules).
5. **App Store draft built and tested (this session):** store, paywall, export gate, watermark
   — all behind `#if APP_STORE`, all in new files (plus 4 small hooks in EditorView). The
   App Store build compiles clean, and the workflow now also boots a simulator and captures
   three screenshots on every push (artifact `app-store-shots`): free edit, Pro edit with
   watermark, and the paywall.
6. **Watermark reworked** after Angelo saw the first shots: it was small and top-right, behind
   the toolbar icons. Now it's big, bottom-centre **on the photo** (follows zoom/pan), with a
   shadow so it reads on bright skies. Angelo to give the final OK on look/placement.
7. **App Store listing assets drafted:** `docs/APPSTORE-ASSETS.md` — name, subtitle,
   description, keywords, privacy, age rating, screenshot plan, subscription setup checklist,
   rejection-risk checklist. All DRAFT for Gate 4.
8. **RAW format matrix test written:** new `Tests/rawmatrix/` + `.github/workflows/raw-matrix.yml`
   (both brand-new files, no frozen files touched). Downloads one public-domain sample of each
   camera RAW (Canon R5 CR3, Nikon D750 NEF, Fuji X-T4 RAF, Sony A7 ARW, 5D III DNG) from
   raw.pixls.us and checks the engine opens, decodes and exports each (JPEG/HEIC/16-bit TIFF).
   This is the Gate 2 proof; first run results pending in the Actions tab (workflow
   "RAW format matrix"). CR2 and ProRAW still need samples — ProRAW especially may need a real
   iPhone sample (see open questions).
9. **14 Oct (this session) — screenshots + watermark fixed:**
   - Watermark reworked twice after Angelo compared the real captures: (a) the 30 %-opacity
     material capsule was invisible on bright skies; (b) the solid dark badge "looked like a
     button". Final look = **tiled diagonal "Lumaforge" text across the whole photo**
     (`LumaforgeMark.swift` is now a `Canvas`), 45 % opacity, white + dark shadow, clipped to
     the photo frame in `EditorView` (follows zoom/pan). Angelo approved the visibility; the
     tiled style is his requested "other apps' protection" look.
   - `app-store-sandbox.yml` now captures **10 real screenshots** (artifact `app-store-shots`):
     01 free light, 02 grade, 03 curve, 04 detail, 05 masks, 06 heal, 07 export sheet,
     08 batch select, 09 watermark, 10 paywall. New CI-only demo hooks (all launch-arg driven,
     no runtime cost): `-lumenDemoGrade`, `-lumenDemoCurve`, `-lumenDemoDetail2`,
     `-lumenDemoExport`, `-lumenDemoBatch`, plus existing `-lumenDemoMask`/`-lumenDemoPeople`.
   - **`-lumenDemoNoWM`** suppresses the watermark so the ad shots (01–08, 10) are captured
     CLEAN; only 09 shows the watermark. Angelo: ad images must not carry the watermark.
   - **05-masks / 06-heal are NOT listing material** — the simulator has no AI; those overlays
     are CI stand-ins. Listing set = 01, 02, 03, 04, 07, 08, 10 (all clean, all real).
   - `docs/APPSTORE-ASSETS.md` screenshot plan updated to the 10-shot set + proposed 6-shot
     App Store order with headlines.

## What to do next (in order)

1. **Check on the sandbox** (if Angelo asks "how's it going?"): read
   `Lumen-Sandbox\SANDBOX-LOG.md`, check `git log` in `Lumen-Sandbox`, and look at the Actions
   tab of the sandbox branch (browser: https://github.com/AngeloP46/lumen/actions — branch
   `sandbox`). Report: what was drafted, whether the engine test passes, open questions.
   Key artifacts: `app-store-shots` (the 10 App Store screenshots — see timeline item 9) and
   `raw-matrix` (RESULT.txt of the RAW format test).
2. **When Claude's usage is back (~15 Oct):** copy the ONE section at the end of this file,
   "THE HANDOFF FOR CLAUDE — copy everything between the lines", and paste it into his chat.
   That single message contains everything: what to read, in what order, the known issues,
   and the rules. No other files need to be pasted.
3. **Gate 3 (Angelo, free):** landing page + waitlist + ~2 weeks of before/after clips before
   any money is spent (plan §7).
4. **Gate 4 (Angelo, ~$99):** developer account, App Store Connect setup (plan §6), final name,
   TestFlight beta, submit.

## Review focus for tomorrow (14 Oct PM, marketing day — no new features)

Angelo is pausing feature work to validate demand. When Claude returns, review in this
order (all on the `sandbox` branch, nothing merged to main, SideStore untouched):

1. **Subscription logic** (`Sources/Store/LumenStore.swift`, `PaywallView.swift`):
   - **BUG (confirmed):** the paywall shows "7 days free, then renews" under BOTH products,
     but the locked decision is a 7-day trial on the MONTHLY only (plan §173/375). The
     annual row's note is wrong.
   - Trial detection in `refreshStatus()` is a heuristic (monthly expiry < 8 days =
     trialing) — verify against StoreKit 2.
   - Paywall is `#if APP_STORE` only and has a free "Keep editing free" close path —
     confirm that satisfies Apple's free-tier-must-work rule.
2. **Export restriction** (`ProGate.swift`, `EditorView.requestExport`):
   - **GAP (confirmed):** the single-photo export gate exists, but the LIBRARY BATCH export
     (`LibraryView` → `store.export(list:options:)`) has NO Pro check — a free user can
     batch-export Pro-edited photos clean. Needs the same gate or per-item gating.
   - Preset edge case: a preset that sets curve values makes the photo Pro (documented in
     ProGate.swift; confirm intended).
3. **Watermark** (`LumaforgeMark.swift`, tiled diagonal, 45 %):
   - It is a preview overlay ONLY. Confirm it does not affect the exported file — the
     plan's intent is a watermarked *preview*; if free exports must carry the watermark in
     the file itself, that's a new pipeline task (currently they don't).
   - Opacity/angle/spacing tuned from screenshots only — never seen on a real device.

Marketing assets are being prepared separately; listing set = shots 01, 02, 03, 04, 07, 08,
10 from the `app-store-shots` artifact (all real, all clean).

## THE HANDOFF FOR CLAUDE — copy everything between the lines, paste it once

---

The project moved on 14 October 2026. Use these canonical folders:
- Main app: C:\Users\pc user\Projects\app development\Lumen
- App Store sandbox: C:\Users\pc user\Projects\app development\Lumen-Sandbox
- Landing page: C:\Users\pc user\Projects\app development\landing-page
The old Downloads paths redirect to these app folders for existing sessions.

Read Lumen/AGENTS.md and CLAUDE.md, then Lumen/docs/APPSTORE-PLAN.md (preserve this existing
untracked file), then Lumen-Sandbox/HANDOFF.md's leading Codex update and SANDBOX-LOG.md.

The local LLM's App Store draft was reviewed and fixed by Codex with Angelo's approval.
Actual GitHub branch name: sandbox (no trailing slash). Code fixes: 61f28e5, 20d2f86,
b8580d1; check git log for subsequent documentation commits. Main remains 70f1448 and no
SideStore app update has been published.

Fixed: batch/single export restrictions at UI and actual export entry points; StoreKit
trial eligibility/offer wording; trial classification; billing grace; observed watermark
updates; foreground/expiry refresh; restore errors; neutral grading/masks/sharpen controls;
privacy policy view and standard Apple EULA link. Pricing unchanged. Angelo confirmed built-in preset looks/strength export free; extra Pro edits remain gated. e4698a9 implements actual recipe matching and expanded regression cases.

Validation: export-policy regression checks and simulator flag-OFF/flag-ON builds passed.
Six-format RAW test (now including checksum-pinned Canon CR2) and engine tests passed at
20d2f86; subsequent code correction changes only paywall API usage and compiler diagnostics.
Screenshot capture passed and watermark/paywall images were visually checked. The 70-test interface suite passed with zero failures (b8580d1). Latest preset checks and both builds/screenshot capture passed at e4698a9.

Still needed: genuine iPhone ProRAW sample; StoreKit runtime tests for purchase, restore,
eligibility, revocation/expiry/grace; real-phone watermark check; public app privacy-policy
URL for metadata; final name/pricing decision by Angelo. Preset policy is confirmed as described above. Compilation is not proof of
correct purchases. 05/06 simulator mask/heal screenshots remain internal stand-ins; record
marketing footage on the actual phone. Paywall shot 10 shows unloaded products, so keep it internal until real or StoreKit-test products are configured.

Preserve the personal SideStore build and frozen project.yml/build.yml/model-fetch scripts.
Do not merge App Store paywall/watermark work into main. Angelo subsequently explicitly
approved shared editor fixes, standalone Lens Blur and a readable scrolling toolbar;
these are now in both builds and published in SideStore 0.1.197. Read the current
shared-improvements section above before continuing.
The site is already polished and TikTok content is underway; content planning follows this
fix/review work. Website prices are proposed demand-testing options, not final app prices.

---
## How updates are tracked (no extra file needed)

- **Local LLM's progress:** its git commits in `Lumen-Sandbox` + `SANDBOX-LOG.md` + the
  `sandbox` branch on GitHub + Actions results.
- **Claude's progress:** his commits in the real repo (`Lumen` folder) + his updates to
  `CLAUDE.md` (he keeps a status log there) + GitHub Actions.
- **Decisions/status for humans:** this file + `docs/APPSTORE-PLAN.md` §11. Keep §11 and this
  file updated when Angelo makes a new decision — that's the whole tracking system.

## Gotchas

- The token in the sandbox's git remote: don't display, copy or commit it. It's limited to the
  lumen repo and expires in 2 days anyway.
- Don't push anything to `main` from `Lumen-Sandbox` (the brief forbids it; the SideStore feed
  publishes from main only).
- Don't rename/move/delete anything in `Lumen-Sandbox` or the `Lumen` folder — just read and
  report.
- The plan is in the REAL repo's `docs/` — if it gets updated, update it there (it's committed),
  not just in the sandbox.
