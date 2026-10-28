# Lumen quality checklist (started 22 Oct 2026)

The durable record of the reliability, correctness and performance work before the App Store: every finding, its
status, the fix, the test that guards it, and what is still uncertain. Updated with every batch.

**Sources:** Claude's review (first pass: docs/REVIEW-2026-10-22.md) and an independent second review of main at
1b8892f (read-only, done by a separate agent without seeing the first). `[1]` = found by the first, `[2]` = by the
second, `[1+2]` = both.
**Evidence:** `phone` = Angelo's iPhone 17 Pro Max diagnostics · `sim` = iOS simulator UI test · `mac` = engine test
on the CI Mac (virtual GPU, CPU Core ML; its memory numbers are not phone numbers) · `code` = traced in the source,
not yet reproduced.
**Status:** open · test written · fixed (branch) · verified sim/mac · verified phone · won't fix (reason).
**Requirements** (Angelo, 22 Oct): R1 work is safe · R2 responsive, no build-up · R3 features work together ·
R4 failures handled · R5 output correct · R6 performance measured.

## Latest release and next work — 28 October, SideStore0.1.774

Main#180/24c29b7 and sandbox#181/079a63f are merged; publication40783343904 and fresh feed/log/asset verified.
Released: consistent brush feather/erase, manual focus and unchanged Refine entry, RGBHDR Lens Blur radiance,
source-relative filtered Grain Size, shape-normalized Vignette, missing Heal asset/export protection and honest
people-search results, visible-first one-active basic/refined thumbnail scheduling with atomic per-photo progress.
Non-caching source/mask materialization reduces measured Subject peak from2716MB to2399–2432MB; limit2650MB
unchanged. No UI layout, model inference, Store policy or old-renderer duplication changes.

Verified: shared465 rendered/retention checks+25 short RAW/memory checks40782782695, all29 committed compiler/
kernel blobs identical to personal candidate; six related UI methods40781694994 and screenshots, logic/readiness,
both sandbox configurations/export policy/build identity and four StoreKit cases40781697900. Scope is recorded
in ADJUSTMENT-COMPLETION-2026-10-28.md; phone/model visual limits remain distinct from deterministic checks.

Next, in order:

1. Read full engine quality/24MP memory/ProRAW40783385204 and full UI40783388166; both started on released24c29b7.
   Earlier756 export logged virtualGPU OOM; current harness now requires a successful full-size HDR file too.
2. Stabilize the brush GPU-heap retention metric without widening its64MB bound: personal identical-source run
   40782233771 passed all pixels/Subject but measured648→max716→689MB; shared40782782695 measured
   656→max709→668MB and passed. One cached component throughout, no claim of a phone memory budget.
3. Phone confirmation of Clarity scene coverage, editing/thumbnail memory, grain/brush/Lens timing and old edits.
   No literal2,000-photo run; bounded queue/filesystem fixtures plus modest RAW batch are sufficient for queue size.
4. Real high-ISO RAW/ProRAW AI Denoise detail/colour/seams, Heal texture/structure/HDR, subject-edge blur and
   overlapping edits on photographic scenes. Existing model visual assessment documents limits; no blind model swap.

The earlier queue and dated status below are historical; released fixes above supersede their candidate labels.

## Earlier adjustment review queue — 28 October 2026

**Active completion batch:** owner instructed "dont stop till youre done". Parallel candidate fixes cover brush
compositing, Lens Blur focus/refinement and RGB HDR radiance, filtered Grain and aspect-normalized Vignette,
missing Heal assets/typed people-search failure, and durable single-active visible-first basic/refined thumbnails.
Source-analysis/subject pools address the final memory follow-up failure:40738195410 subject2658MB versus2650MB
budget, virtualGPU exportOOM; no limits were raised. Memory sampling now preserves the full step peak through
diagnostic callbacks. New synthetic production-path, geometry4x-reference and UI failure fixtures await Mac checks.
The new renderer thumbnail revision4 is separate from recipeformat3; old JPEGs remain visible until atomic success.
No legacy rendering engine is retained. Actual model-generated visual limits are documented in
AI-VISUAL-REVIEW-2026-10-28.md rather than treated as fixed through model swaps. Candidate not published yet.

**Latest release: SideStore 0.1.756, main #176 (737e4fe), source f6e3465, published and feed/hash verified.**
The AI failure-state batch below is now released in both versions (sandbox #177 a54fa93): 132 focused checks,
six related UI cases, logic/readiness and OFF/ON/policy/four StoreKit cases pass. Independent reviews completed.
Full engine quality 40738195410 passes all 1644 checks; its longer memory sequences continue.
See AI-RELIABILITY-2026-10-28.md. This status supersedes
the older candidate/released notes below; the still-open items remain listed explicitly.

**Prior Clarity release: SideStore 0.1.747, main #174 (e4c9f97), published and feed/hash verified.**
Clarity's wide edge veto is replaced; 142 focused checks pass, including the approved actual car crop and ten
SDR/HDR comparisons proving other adjustment families do not read that Clarity channel. Endpoint renders inspected.
Owner confirms the previous 0.1.737 thumbnail recovery works. New Clarity response still needs phone confirmation.
Full engine 40687563996: 1553/1557 passed; four failures concern the small fixture's resampling/export assumptions.
Full UI 40687567667: 94/95 passed; zoom reload exists in event log at fixed timeout boundary. Follow-up test
corrections and reruns are pending. Sandbox #175/check 40732458311 pending; #172 already merged and passed.

Owner requested parallel agents. Their current-source follow-up separates these concrete defects from visual reviews:

1. **Export fidelity first:** absent AI Denoise model + absent residual silently omitted the requested edit.
   Guard fix, no-inference missing/valid-cache regressions and structural legacy PNG validation released in 0.1.756.
2. **Automatic selections:** failed Subject can become whole-white Background; requested failed/missing selections
   have no export gate; failures disappear during large-source/detail/memo transfers; Scene retry can leave stale
   tried-empty derived landscape keys. State/gates fixed and verified distinctly from valid empty detection in 0.1.756.
3. **Brush compositing:** paint then erase at the same softness can reappear when a distant stroke with another
   softness switches the global compositing branch. Build an isolated-region regression before changing convention.
4. **Lens Blur controls:** manual focus fallback can blur the tapped plane; merely entering Refine changes radius.
   Full HDR radiance-path regression is needed; scalar gain cannot reproduce arbitrary coloured highlight mixing.
5. **Effects controls:** Grain Size floor collapses 0–80 at 640px / 0–20 at 1600px; circular Vignette on a 3:1
   frame has no effect above Midpoint ~74.5. Both need production-render regressions and calibrated fixes.
6. **AI reliability follow-ups:** missing Heal patch files are skipped; failed people detection can be described as
   none found. Distinguish failed work from valid empty results without blind inference/model changes.
7. **Quality/performance evidence:** real RAW/ProRAW AI colour/detail/seams, Heal texture/HDR, subject-edge/blur,
   crop resampling and overlapping-mask/preset/HDR/export interactions remain incompletely validated. Larger-library
   visible-first/basic-refined scheduler remains a separate draft. No literal 2,000-image run is needed.

**Follow-up reliability implementation, released in 0.1.756 / sandbox #177:** missing-model denoise export guard and bounded legacy
PNG structural/dimension validation; failed versus valid-empty automatic selection state retained across full-size,
detail and undo transfers; failed inverted selections suppressed; active failed selections block export explicitly;
derived Landscape retry invalidates failed outcome; optional successful Sky fallback remains usable. No model weights,
inference parameters, control gains or layout changed. The deterministic production-path regressions pass on the
Mac. Independent source review found and corrected two integration edges (inverted failure and unnecessary AI
when no selection is required). Broader photographic quality and effects/blur issues above remain queued.

The older dated status entries below are historical; they do not mean these features are fully reviewed.

**28 Oct urgent phone follow-up:** 0.1.737 supersedes 0.1.728's thumbnail restart/memory regression and weak Clarity.
See `THUMBNAIL-RECOVERY-2026-10-28.md`: 126 rendered/batch checks and six focused UI cases pass; phone follow-up
pending. Larger-library priority/basic-refined scheduling is next, separately from this release. No literal
2,000-photo test is required; use small deterministic scheduling tests and modest repeated real-RAW memory checks.

Current release: SideStore 0.1.728 verified, main #169 a44a6bd; all 1,315 engine quality checks and the focused 89
checks and both memory sequences passed (40671575491). Shared sandbox #168 merged 7efb41d, OFF/ON/policy/StoreKit
passed in 40671675913. Full UI follow-up: 40671255251; six targeted save/history/paste/Heal-retention cases: 40673361219.
Partial mask/brush/export/geometry follow-ups are in `REMAINING-ADJUSTMENT-REVIEW-2026-10-28.md`; they are not fixes
in this release. Keep original photos and values; older looks intentionally adopt the current renderer.

Angelo resumed these with "carry on" on 28 October. Current batch: Clarity, single-engine migration and the
deterministic defects from the AI review. These features have NOT all had a comprehensive image-quality review;
passing existing tests is not proof their algorithms and control ranges are optimal. Preserve the layout/UI he likes.

- [ ] **Clarity — released in 0.1.747, phone confirmation pending:** actual car screenshot proxy and dense-edge
  scenes now respond broadly; endpoint/centre/fine-noise/flat/halo/two-size and other-family isolation checks pass.
  The owner's original RAW and phone rendering remain to confirm; do not conflate the screenshot proxy with RAW.
- [ ] **AI Denoise:** model/input colour and HDR handling, real noise versus retained detail, strength blending,
  tile seams, preview/export consistency, speed and peak memory on real RAW/ProRAW and the phone.
- [ ] **Heal:** fill quality, edge blending, colour/tone matching, texture reconstruction, repeated/large fixes,
  HDR behaviour and exported results.
- [ ] **Remove People:** detection/selection quality, protection of the main subject, overlapping removals and
  fill quality at different subject sizes.
- [ ] **Lens Blur:** depth/focus accuracy, subject boundaries and colour bleed, bokeh/highlight rendering,
  amount/range/feather scales, refined masks, preview/export/HDR consistency and performance.
- [ ] **Mask generation:** subject, background, sky, people, landscape, depth and colour/luminance selections;
  fine edges, brush/gradient combinations, feathering and add/subtract/intersect quality.
- [ ] **Vignette and Grain:** every related adjustment's math and useful range, corner/endpoint behaviour,
  noise/grain appearance, source-size scaling and export consistency.
- [ ] **Crop, Straighten and Perspective:** geometry, interpolation quality, edge/fill handling, crop constraints,
  mask alignment and full-resolution exported detail.
- [ ] **Complete the partial reviews:** adjustments within masks; preset strength and copy/paste interactions;
  preview/detail/export consistency across the above features.

For each: trace the actual implementation, compare credible photographic approaches/primary sources, reproduce
shortcomings on representative images, explain quality/runtime/memory tradeoffs and add meaningful regression
coverage before claiming a fix. Do not describe these features as already fully audited or replaced.

Single-engine migration is implemented on `clarity-single-engine`, pending validation/publication: every older
recipe/history/preset/paste uses current processing; old render code removed, values preserved and exact JSON
backed up before overwrite. Same values may change appearance. SideStore 0.1.714 still retains the old path.

AI Denoise/Heal/Remove People received a source review, recorded in `AI-QUALITY-REVIEW-2026-10-28.md`. Confirmed
fixes on branch: rounded denoise preview bins, stale-preview repair from unchanged full residuals, paused-cache
decoder identity and rejected person-mask label reuse. Real model colour/detail/HDR/fill quality remains open.

Read-only follow-ups are recorded in `EFFECTS-QUALITY-REVIEW-2026-10-28.md` and
`LENS-BLUR-QUALITY-REVIEW-2026-10-28.md`: Grain Size preview dead ranges, aspect-dependent Vignette range,
HDR blur energy and initial refinement/manual-focus behaviour. Reproduce with their proposed fixtures before
changing those algorithms; these are outside the current Clarity/migration release.

Validation found and fixed an existing tolerant-loader defect: explicit cropVersion was discarded if another
missing field forced tolerant loading. Preserve supplied crop versions and leave genuinely absent old versions
absent; both cases have regression checks. First rendered pass passed 85/89 checks; the four Clarity strength
checks correctly rejected modest endpoint response. Retuned gains and fixed a flat-tone rounding bias. Final
focused GPU run 40671254430 (73c0abf) passed all 89 checks; RAW/JPEG sheets inspected. Broader engine/memory,
full UI, release readiness and sandbox validation still pending; phone confirmation remains outstanding.

Prior full UI run 40604410069 passed. Sandbox PR #168/check 40604979559 remains pending (OFF/ON builds passed;
StoreKit fixture products did not load in testAnnualUnlocksPro); investigate the fixture separately from editor code.

## Continuation evidence — 22 October, Codex

Scope remains all approved batches 0–6, plus the agreed Copy/Paste. No SideStore publication or App Store
submission is authorized. Rows below retain their original findings; this section records the current evidence.

- Batch 0 #95 and Copy/Paste #96 are included in batch 1 #97 (`5deccec`). Build IPA and release readiness
  passed (39849200959); Linux logic passed (39849201068); engine passed (39849201010). Full UI run
  39849201011 was still running at the last inspection. These results predate the review corrections below.
- Independent static review of `origin/main...5deccec` completed. Five defects found: pending edits ignored on
  reopen; history-only failures never retried; unchanged photos saved on close; malformed mask containers
  silently discarded; failed backup writes reported as successful. No actionable Copy/Paste defect found.
- Review corrections: pending edits are authoritative on reopen (including fresh RAW HDR defaults); pending
  history is retained even when the sidecar fails; history/index/preset writes retry; the save warning remains
  until recovery; saves on close use dirty revisions; malformed masks request backup; a failed backup blocks
  overwriting the original until the backup succeeds. Verification pending on the corrected commit.
- Added actual filesystem-failure simulator coverage: pending edits/history on reopen, a further edit before
  storage recovery, newest edits written after recovery, history-only retry and warning recovery. Extended the
  no-save-on-open test through closing the editor. Logic coverage includes malformed mask containers.
- CI Mac baseline, 12 MP iPhone ProRAW, run 39849201010: open 0.7 s / peak 792 MB; 100% source 0.9 s /
  1989 MB; subject 0.8 s / 2003 MB; Heal 9.4 s / sampled step peak 2609 MB (internal model probe 3881 MB);
  export 2.1 s / 4864 MB. Memory suite passed 19 checks. These are simulator/Mac measurements, not phone
  performance; the separate ProRAW memory run intentionally skips AI Denoise.
- Later batches and sandbox ports remain outstanding. Phone checks in section G remain unverified.
- Batch 2 started on `quality-batch2`: A9 model loading now runs outside the cache lock; release invalidates
  an in-flight load without waiting for it, and failed loads can retry. Foundation-only regression holds a
  loader blocked while measuring release latency, checks late-result eviction, failure recovery and cache reuse.
  Compile/runtime verification pending. Other batch 2 items remain open.
- 22 Oct (PC assistant, continuing from Codex): uncommitted batch 2 work (A9 LoadedModel.swift, Engine.swift,
  logic regression, both CI workflow file lists, second-review save corrections, APPSTORE-PLAN doc) committed as
  `9d0e538` and pushed; PR #98 `quality-batch2 -> batch1` opened, left unmerged. `.scratch/` added to .gitignore.
  Verification: wait for PR #98 CI (logic, engine, UI).

## 23 Oct: independent review of the overnight work (Claude) and the fixes on `quality-fixes`

Reviewed `origin/quality-batch2` (94616bf) read-only (a separate reviewer plus the CI logs), then fixed on
`quality-fixes` (branched from it). **The four UI failures the overnight brief called "suspected flakes" were not
flakes:** the same counts (4 of 9, 2 of 7) repeated in every run. Causes: (1) real regression in the A10 async delete,
(2) the A7 test could never pass, (3) the persistence check raced the demo library setup, (4) my Copy test tapped the
wrong spot. The A14, A17 and A19 changes themselves hold up (`renderData` is behaviour-identical to before).

| Finding | Evidence | Fix on `quality-fixes` |
|---|---|---|
| **A10 delete regression**: the photo stayed in `items` (and unmarked) until its file work ended, so a late save or heal could recreate it; `testHealDeletionPrivacy` 4 of 9 | CI 39880679715; LibraryStore.swift delete | marked deleted, off the list, list saved and original unlinked at once; only slow file work on one serial queue; retained-patch scan reads the edits folder (no stale list, no concurrent half-read); the photo's kept copies go with it |
| A7 test never passed (swipe is off in Masks) | EditorView `canNavigate`; CI | test uses ⋯ → Next photo |
| Persistence check raced the demo setup (setup deleted its files) | CI: only the first PASS logged, 2 of 7 | started after the demo setup |
| `testCopyOnlyTheChosenTools` (mine) | CI 3 runs | taps the switch itself; waits for the sheet to close |
| A5 test passed without the fix (mine) | review | `-lumenDemoSaveDelay 8`: only save-on-leaving can write |
| `formatVersion` never normalised: an older Lumen re-saved a newer file still claiming the newer format (mine) | review | held in this version's format on load; logic tests |
| Paste onto the photo it came from re-adapted its masks (mine) | review | `Clipboard.sourceID`, `samePhoto` rule; logic tests |
| Editor Paste with AI Denoise started a locked 1–2 min clean without asking (mine) | review | confirmation first; memory-tier check; library batch also checks `denoiseFits` |
| Library copy/paste used `settings(for:)`, the editor `editorSettings(for:)` (RAW HDR default) (mine) | review | library uses `editorSettings` |
| Half-copied imports could be adopted as photos at launch (mine) | review | copy to `.partial`, rename; leftovers removed |
| Heal-patch sweep failed open if the edits folder couldn't be listed (mine) | review | fails closed |
| Stop shown (and doing nothing) for a single painted heal | HealViews | `removingPeople` flag |
| A8: optional jobs released models and slept 3 s on the shared work queue | HeavyWork | optional jobs skip at once |
| B7: a frame refused in the background was never redrawn | CanvasView | redraw on `didBecomeActive` |
| Heal model read twice in `prepareHealModel` (second load after a release) | Heal.swift | read once |

**Verification of `quality-fixes` (PR #99, merged 23 Oct; simulator and Mac only, no phone evidence):** Build IPA and
Release readiness green; Linux logic tests green; engine test green (1072 checks plus the 12 MP ProRAW memory run); full
UI suite 87 of 88 with the one failure a test of mine that compared against the wrong starting value (Lens Blur amount
after leaving the tool), fixed and re-run 3 of 3; the eight tests that exercise the changed flows 8 of 8.
Published as SideStore **0.1.516**.

**Batch 4 (PR #100, merged 23 Oct, SideStore 0.1.521):**

| Finding | Fix | Guard |
|---|---|---|
| A18: an AI step that failed (request threw, model wouldn't load, no memory) was remembered as "found nothing" ("No people found") and could never be retried | `ImageSource.noteFailure/failures/clearFailures`; each Masks.swift step notes a failure where it happens; the empty-mask banner says the AI couldn't run and offers Try again (`mask-empty-retry`) | engine test: failure registry; targeted UI tests |
| A20: a batch clean of a photo removed meanwhile left a stray cleaned file; a batch paused by backgrounding never carried on if Lumen came back first | file removed when the photo is gone; carries on when the app is active again | code review (hard to test) |
| A4 reopen: a heal finished after its editor closed was written by the store, then overwritten by a reopened editor's next save | store posts `.lumenHealsAdded`; an open editor of that photo adopts the heals | code review; targeted heal UI tests |

Checks: Build IPA + Release readiness green, Logic green, Engine green (first commit), six targeted UI tests green
(mask, heal, next photo, people mask). Full UI suite not re-run on this batch.

**App Store version (`sandbox-on-main`, 23 Oct):** the old `sandbox` had drifted too far for a merge (20 conflicts), so it
is main's code with the Store layer put back on top (only `EditorView`, `LibraryView`, `LibraryStore`, `Demo.swift`
hold `#if APP_STORE` hooks; all other shared files are main's). Checked with app-store-sandbox.yml: flag off and on,
ProGate checks, StoreKit test, screenshots. Not yet merged into `sandbox`; nothing is submitted.

**23 Oct, first phone test of 0.1.521: Lumen was closed by iOS twice in four minutes.** Neither is something the batches
above set out to fix (they protect your edits and data); both are memory, and CI cannot see memory (B1: the simulator
reports none, so every UI test runs as a low-memory phone and the 100 % copy is never built there).

| Finding | Evidence | Status |
|---|---|---|
| **A21: the 100 % view loops into a memory kill.** After Remove person on a 24 MP photo, zooming in tried to build the zoomed copy 13 times in a minute (every pinch step asks, and so did every memory warning that dropped it); each build adds ~2.1 GB; at 2477 MB free a 4096 px copy was started (the margin was not kept) and iOS closed Lumen | phone 0.1.521, 10:16:41-10:16:52: "100% view: building" x13, warnings x11, closed after the last | fixed (batch 5, PR #105, SideStore 0.1.533): cost 2150 MB at 24 MP / 2640 MB at 48 MP plus the 700 MB margin must be free; zooming first lets go of the original copy, the mask/Heal/denoise models and GPU caches and looks again once; a try with no room, a skipped build or a copy dropped on a memory warning is not repeated for 12-30 s; coordinator: optional jobs keep the margin; logic tests (`DetailCopy`, `RetryGate`, the coordinator) |
| **A22: memory spikes right after AI Denoise on a 48 MP photo** (Lens Blur 20, 2 masks, Detail open): 1454 MB at the end of the clean, then 2764, 2837 and 3083 MB within 7 s (limit 3375), warnings x6, closed a few seconds later. The clean itself was fine (101 s, 0.43 s/tile, 0 redone). **Cause not found.** Candidates: the preview reload with the cleaned copy, the thumbnail made again on closing the editor, the Lens Blur masks; a Mac probe could not tell (each RAW decode stays in the process, a second decode of the same size adds almost nothing) | phone 0.1.521, 10:11:30-10:11:42 | open. 0.1.546 flight recorder showed (13:01) memory swinging 1.4-2.9 GB every 0.1 s while the picture was only moved: fixed in 0.1.574 (one frame in flight, rested picture drawn from a bitmap, 2048 px preview). 0.1.552 closed at "heal start (model ready false)" (14:06) with 2.3-3.05 GB swings as the Heal model loaded: batch 12 (Heal on the GPU, loaded alone with the picture still, or "no room"). Needs diagnostics from 0.1.574+ to confirm |
| **A23: the same photo decoded three times in one second** after a heal (undo, HDR and the finished heal each asked for a reload); three copies of the photo were alive together and memory went 1.2 to 3.4 GB | phone 0.1.533, 12:19:24: "preview decode: start" x3 | fixed (0.1.546): `SingleFlight` - a request while a decode runs only marks the newest settings as wanted and one more decode follows; stale results are dropped; opening and reloading go through the coordinator; logic test |
| CI blind spot: the 100 % copy, the standard-memory paths and AI Denoise are never exercised in UI tests | B1 | open: needs a decision, see B1 (a UI test with `-lumenDemoMemoryMB 3375` would exercise the 100 % view gating) |

Idea for the 100 % view (not built): render only the visible part at full size (a cropped lazy decode cost ~400 MB in
the Heal measurement) instead of a whole 4096 px copy (~2.1 GB).

**PR #91 (from the 0.1.465 diagnostics), ready, not merged:** rebased on main 0.1.521 and green (Build IPA, Release
readiness, Engine, six targeted UI tests: hold-to-compare, export quality and size, batch export, before/after split, next
photo). The original copy is made once at a time (diagnostics showed it made five times in 20 s); export works out AI masks
on the 2560 px copy for every photo over 2700 px, not just over 30 MP (B6); the export memory estimate is 30 MB/MP + 700
(a 48 MP export peaked at about 1.1 GB on the phone, the old 60 MB/MP + 800 asked for more than the limit). It waits
for the phone results of 0.1.521.

**23 Oct, evening and night (Claude, SideStore 0.1.533 to 0.1.593).** The first phone runs found memory closures that the
batches above did not set out to fix. New rows below the table of 23 Oct: A21 (the 100 % view loop), A22 (spikes and
closures: the flight recorder is in since 0.1.546), A23 (reload storms). Versions:

| SideStore | What |
|---|---|
| 0.1.533 | A21: the 100 % copy needs its measured room plus the margin, is not retried in a loop |
| 0.1.542 | the flight recorder (`BlackBox`: memory every 0.1 s into its own file, the last lines copied into the log after a closure), Lumen lets go early past 2.4 GB, Heal warm-up later and only with room |
| 0.1.546 | A23: the preview decode is single-flight (one at a time, newest settings only) and goes through the coordinator; the Heal model stays loaded instead of being reloaded for every use |
| 0.1.552 | A13, A16, B8, A9 edge (above) |
| 0.1.562 | B1, B2, B4, B5 (above) |
| 0.1.569 | A17 rest, A8 export part (above) |
| 0.1.574 | A22 frame pacing: one frame in flight (was two), a rested picture is rendered once into a bitmap and drawn from that, a 2048 px preview, a memory warning draws again once 0.6 s later |
| 0.1.581 | A22 Heal: the Heal model runs on the GPU (not with the Neural Engine, whose first load after an update took 2.2-3 GB inside Lumen), is loaded on its own with the canvas still and nothing else heavy running, or Heal says there is no room; the canvas also stays still during a heal; a fresh demo launch forgets the undo history (test isolation) |
| 0.1.589 | careful mode: after two memory closures within a day Lumen uses a 1600 px preview, skips the zoomed-in copy and the Heal warm-up, lets go earlier (2.0 GB) and says so once; back to normal after a day without a closure (`CarefulMode`, logic tests) |
| 0.1.593 | B6: the original copy is made once at a time (0.1.581 log: 11 times in a minute during undo/redo), export works out AI masks on the small copy for every photo over 2700 px, a realistic export estimate (30 MB/MP + 700) |
| 0.1.599 | nothing is drawn while a clean has the screen locked; a picture is frozen only with room; the decode a zoomed-in copy leaves in the session goes with the copy |
| 0.1.606 | the canvas draws with a context that keeps no intermediate results; Lumen's own let-go does not redraw at once; AI Denoise does not start with under 1500 MB free (it says so) |
| 0.1.608 | AI Denoise model at 256 px tiles (was 512); the loaded model is kept for the session instead of let go and loaded again (only a memory warning lets it go); Detail warms it only with 2400 MB free; a clean needs 1100 MB free |
| 0.1.620 | careful mode works without a popup (owner: users shouldn't see it); the Heal model needs 1200 MB free to load, not 2800 (0.1.608 refused three heals with 2764 MB free; on the GPU it loads for ~150 MB) |
| 0.1.626 | masks: the overlay and the clipping warning stay on the photo (kernels give nothing outside it); the editor lets go of its copies on close |
| 0.1.629 | App Store groundwork shared with main: Acknowledgements (model licences, Apache 2.0 text), privacy manifest, no export-encryption question, iPhone only |
| 0.1.634 | SideStore page: screenshots, description, tint, release notes from the PR title |
| 0.1.639 | the photo sits in the middle of the space above the panel in every tool (a wide photo sat on the panel) |
| 0.1.644 | Grade opens taller (its compact height is 330 pt) |
| 0.1.657 | crop rework (#147, `docs/CROP-REWORK.md`): the photo zooms and moves under a frame that stays big, 48 pt handles, a straighten dial; crop version 2 keeps the crop on real photo exactly ("Keep the crop inside the photo"), older edits converted when Crop opens them |
| 0.1.665 | crop panel Crop / Straighten / Perspective like Photomator (#150): a ruler for straighten and for perspective (chips choose Vertical, Horizontal, Aspect, Scale, Move), big tiles, a fine grid while a ruler turns, nothing drawn behind the top buttons |
| 0.1.673 | Crop: one zoom (pinch, zoom tile back to 1x, Scale / Move only with Fill frame off); `EndStop`: sliders, rulers, crop drags and pinch, photo pan, curve points, Depth edges and the panel handle respond at once when turning back at a limit (#153) |
| 0.1.679 | Brightness (Light and masks: mid-tones up to +/-1 EV, white and black kept); Auto shares its lift between Exposure and Brightness and no longer treats a bright sky as a night scene (#155) |
| 0.1.684 | canvas fills the whole texture at its own size and crops the photo to its place (a mask's tint showed around the photo on the phone); a wrong-shaped picture is noted in Send diagnostics (#157) |
| 0.1.692 | sliders: a detent at neutral instead of a 1.2 % snap zone (values next to 0 can be chosen), haptics (neutral click, end bump, ticks), a livelier look (#160) |
| 0.1.700 | curves like Darkroom (corner points whole, five starter points, zone names, ring points, hold a point to remove it); the editor needs two swipes from the bottom edge to leave (#163) |
| 0.1.703 | radial masks: a size handle on every side, kept on screen, dragged by distance; mask handles take hold within 48 pt (#164) |

**Phone evidence, 0.1.581 (Angelo, 23 Oct 16:49-16:51):** heavy, quick editing (undo/redo and HDR toggles, three people removed, four heals, the
zoomed-in copy built three times, AI masks on every change): **no closure, peak 1932 MB** (0.1.552 and earlier reached 3.0-3.4 GB and closed). The Heal model
loaded alone in about a second (262 to 413 MB), the 100 % copy was refused once for lack of room (1831 MB left, needs ~2880) as designed, one heal started
with 1869 MB free (needs ~2000) and finished. One session, not proof: A22 stays open until a few days of use have passed without a closure.
Seen in the same log and fixed in 0.1.593: "original copy made 11 times within 60 s".


**Phone evidence, 0.1.599 (Angelo, 23 Oct 18:08 and 19:00): two more closures, one cause.** A normal AI Denoise (24 MP, 19:00:49, 117 tiles, 51 s,
median 0.42 s/tile) peaked at 1598 MB and finished: it does not close Lumen by itself. What closes it is the model's memory stacking:
- Loading the model costs 0.63 to 1.2 GB (346 to 1304, 637 to 1266, 255 to 1339 MB at "denoise model made ready").
- Letting it go gives back about 130 MB (17:15:57 done, 1382 MB; 17:16:01 "4 s after", 1256 MB; background 1210 MB). With the editor closed and no photo open
  Lumen sat at 1235 MB (19:00:14 "editor freed"). The release did not return the rest, and the next load took another 1.19 GB on top (1277 to 2465 MB when the
  second photo's Detail opened at 19:00:34), after which a clean started with 912 MB free and iOS closed Lumen.
- 18:08: a cancelled clean left 1369 MB, masks, HDR toggles and Lens Blur took it to 2.4 GB, the model was made ready again (2661 MB), the clean started with 952 MB
  free and closed Lumen within 5 s. Two closures in a day switched on careful mode (the header of the 19:00 report says so).
So "the model costs ~0.9 GB and can't be freed" was right about the model and wrong to stop there: the cost is paid again on every load. 0.1.608 (batch 17) makes the
model a quarter of the size (256 px tiles: its working memory grows with the tile's area; CI Mac time per tile 5.3, 3.0, 1.3 s for 512, 384, 256 px, the same
speed per pixel, about 15 % more tiles for the overlap, so 24 MP ~51 s to ~58 s and 48 MP ~98 s to ~113 s) and loads it once per session. CI cannot measure
the phone's GPU memory (the CI Mac's footprint does not include it): the effect shows only in Angelo's next "denoise model: loading" / "made ready" lines.

**Phone evidence, 0.1.608 (Angelo, 23 Oct 20:56-21:04): no closure.** 48 MP ProRAW AI Denoise twice in a row: model loaded in 0.5 s for +40 MB
(165 to 205 MB), peak 723 MB (was ~1.8 GB), 97 and 102 s, 972 tiles of 256 px at 0.09-0.11 s, settled at 480 MB. 24 MP: 486 tiles at 0.09 s, ~40 s
(was 51 s). The second clean loaded nothing (model kept). Speed is accepted by the owner (24 Oct). Seen in the same log: Heal refused three times
("needs ~2900"), fixed in 0.1.620.

**Still open:** A22 (a few more days of use without a closure; Send diagnostics will show), A8 residual (the AI Denoise model's memory: 0.1.608 makes it a quarter of
the size and loads it once; confirm with one session on 0.1.608: the "denoise model: loading" line and the memory at "made ready" should be well under the 0.65-1.2 GB above). **B3 is closed as won't fix:** a heal paints pixels the model made, which never had sensor noise, over the photo
after AI Denoise has done its work, so the patch looks the same at any AI Denoise amount while the photo around it does not; matching it means
inventing grain (a feature, not a repair), and moving the patch before the denoise changes nothing (the noise is zero inside it). Healing after
AI Denoise gives the closest match. Phone verification of everything above is outstanding (section G).

## A. Confirmed bugs, ranked by user impact

### Work safety (R1)

| # | Finding | Evidence | Reproduce / verify | Status |
|---|---|---|---|---|
| A1 | **Opening a photo can permanently drop its masks, or all its edits, and its undo history.** When the strict decode fails (an older build after a rollback, a renamed mask kind, a new required field), `decodeSettings` retries without masks, then falls back to defaults, with no backup (a backup is kept only when the JSON doesn't parse at all). The editor then **saves on open**: `start()` sets `settings` → `settingsChanged` → `scheduleSave()` even while loading. History is decoded strictly with no migration, so it resets and is overwritten. `[2]`, damaged-file part `[1]` | code: LibraryStore.swift:293–344, 380–393; EditorViewModel.swift:171, 527–537; EditSettings.swift:45, 180, 200, 234 | Logic test: sidecar with `"kind":"futureKind"` / a missing `MaskComponent` key → masks kept, backup written, history loads, nothing written on open. | fixed (SideStore 0.1.521) - tolerant setting-by-setting load, backup before anything is dropped, no save on open; logic + UI tests. Phone: P9 |
| A2 | **Failed saves are silent.** Edits, history, photo list and presets are written with `try?`; storage full or a write error loses work with no message. A photo copied in but never listed (index write failed, or the app died mid-import) stays invisible: orphan files are adopted only when `index.json` is damaged. `[1+2]` | code: LibraryStore.swift:421, 446, 809–813, 943–947, 232–237 | Logic test on a read-only folder → error surfaced, edit kept in memory, retried; orphan file adopted at launch. | fixed (0.1.521) - saves retry, a banner says when one failed, half-copied imports never adopted; UI + logic tests. Phone: P9 |
| A3 | **"Remove from Lumen" on one photo deletes at once, with no confirmation or undo** (multi-select delete asks). It removes Lumen's copy, edits, history, heals and AI Denoise results. `[2]` | code: LibraryView.swift:~298 vs 200–209 | UI test: long-press → Remove → a confirmation appears. | fixed (0.1.521) - Remove on one photo asks first (`confirm-remove`); UI test. Phone: P8 |
| A4 | **Leaving the editor during a heal, Remove people or export loses the result**, and the heal's patch files stay on disk. Back is always enabled; ⋯ → Previous/Next skip `canNavigate`; completions hold the editor weakly. Heal patches whose undo step falls off the 100-step history also stay forever. `[1+2]` | code: EditorView.swift:661, 695–696; EditorViewModel.swift:1215, 1374, 1700; HealStore has no sweep | UI test (`-lumenDemoPeople` + slow heal hook): tap Back while removing → result kept or navigation blocked; logic test: unreferenced patch swept at launch. | fixed (0.1.521) - heals survive leaving the editor and reach a reopened one (batch 4); code review + targeted UI tests |
| A5 | **A pending edit isn't saved when Lumen leaves the screen.** Saves wait 0.5 s; the resign handler writes history only. `[2]` | code: EditorViewModel.swift:544–555; LibraryStore.swift:109–112 | UI test: change a slider, send to background within 0.3 s, relaunch → change kept. | fixed (0.1.521) - edit saved when leaving straight away; test now deterministic (`-lumenDemoSaveDelay`) |
| A6 | **A release build can ship without AI Denoise.** `build-denoise.sh` leaves an empty model and exits 0 on failure; `build.yml` publishes it; exports then silently skip AI Denoise. `[2]` | code: .github/ci/denoise-convert/build-denoise.sh:12, Graph.swift:246 | CI check: main builds fail if any `Models/*.mlmodelc` lacks `coremldata.bin`. | fixed (0.1.521) - Build IPA fails if any AI model is missing or empty |

### Responsiveness and memory (R2)

| # | Finding | Evidence | Reproduce / verify | Status |
|---|---|---|---|---|
| A7 | **The next photo waits behind the previous photo's work.** One serial `workQueue` (file-level, shared by every editor) runs preview decodes, AI masks, the 100 % copy, heals, Auto and preset thumbnails; nothing is cancelled when a photo closes; reloads aren't merged (five undos through heals = five full decodes). `[1+2]` | **phone 0.1.465**: open AWP09650 19:27:28; previous photo's AI masks finish 19:27:33; "photo ready" 19:27:33 (5 s). code: EditorViewModel.swift:7, 458–509; HeavyWork.swift:67–75 | UI test: photo with a Depth mask + `-lumenDemoSlowAI`, swipe at once → next photo ready < 2 s (demo log "loaded … queued Xs"). | fixed (branch) — AI masks moved to their own `aiMaskQueue` (memory gating stays with HeavyWork); new UI test `testNextPhotoDoesNotWaitForAIMasks` parses "queued" from the log. The cancellation and reload-merging parts remain for a later item |
| A8 | **Memory the job coordinator can't see or free:** the AI Denoise model warmed whenever Detail opens (outside the coordinator, kept 30 s); the Heal model left loaded if Heal is left while it loads; the editor's shared decoder keeping a full-size decode after export or a heal (only AI Denoise and batch export use their own decoder); preview opens, reloads and thumbnails decoding outside it; the "original copy" declared as 450 MB whatever the size; an unlimited thumbnail cache. `[1+2]` | **phone 0.1.465**: between photos after a clean Lumen sat at 892–1001 MB, vs ~300 MB in a session without (0.1.459). code: EditorViewModel.swift:430–440, 1166, 1179, 1257, 1692; Heal.swift:238; Denoise.swift:390–393; LibraryStore.swift:40, 956 | Engine `--memory` step: footprint after export with the session alive, then a heal. Phone P1. Log memory at editor close and when its view model is freed. | mostly fixed - the original copy is sized by the photo, thumbnails cache is bounded, previews and reloads go through the coordinator (0.1.546), an export frees its decode by decoding the preview again with a new session (0.1.569). Still open: about 1 GB stays in use after an AI Denoise with its model released (0.1.533 log: 1385 MB at the end, 1050 after, ~1000 in the background). Understood from the 0.1.599 logs: Core ML returns ~130 MB when the model is let go and the next load costs the full 0.65-1.2 GB again. 0.1.608: 256 px tiles (a quarter of the working memory), the model is loaded once per session and kept. Needs Angelo's diagnostics on 0.1.608 |
| A9 | **The main thread can freeze while an AI model loads.** `LoadedModel` holds its lock for the whole load; `release()` takes it and is called on the main thread (closing the editor, memory warning, heal start, export, the heal release task). `[1+2]` | code: Engine.swift:12–24; EditorView.swift:149; EditorViewModel.swift:143, 1180, 1239, 1685 | Sim test with a slow fake model load and a release on the main thread; measure the stall. | fixed (0.1.552) - `LoadedModel` loads outside its lock; callers already waiting for a load a release overtakes share its result instead of loading again (logic test) |
| A10 | **File work on the main thread that grows with photo size or selection:** Photos imports copy each original (after first writing a temp copy) and read EXIF on the main actor; paste onto N photos reads and writes each; delete waits on the history queue and re-reads every other photo's edits per deleted photo; thumbnails decode on the main thread; the batch-export sheet reads every selected photo's edits. `[1+2]` | code: LibraryStore.swift:910–941, 464–509, 740–756, 44–50; LibraryView.swift:213 | Phone P2; sim: main-thread stall timer in demo mode. | fixed (branch) — `delete` now does the history flush + Heal-patch scan (the per-photo sidecar reads) off the main thread in a detached task; list update, index save and patch removal stay on main as before; the per-file order is unchanged (a failed removal leaves a re-adoptable file, not a lost one). The Photos-import and thumbnail parts were already off-main; paste is left for the next pass |
| A11 | **Editor observers are never removed** (two per photo opened). `[1+2]` | code: EditorViewModel.swift:281, 298–317, 132 | Debug counter after 10 photos. | fixed (branch) — `deinit` now removes `memoryWarning` + `denoiseObservers` + `lifecycleObservers` (added in batch 1 `5deccec`); not yet measured on the phone |

### Features together and output (R3, R5)

| # | Finding | Evidence | Reproduce / verify | Status |
|---|---|---|---|---|
| A12 | **Paste behaves differently in the editor.** ⋯ → Paste edits replaces everything except heals and AI Denoise: the other photo's Lens Blur focus and mask link, Heal switched off, its HDR mode, masks not adapted. The library's "Everything" keeps this photo's Lens Blur and Heal on/off and adapts masks. Paste logic lives in four places. `[1+2]` | code: EditorView.swift:685; EditorViewModel.swift:1399; LibraryStore.swift:464–509 | Logic test: same clipboard through each path → agreed rules hold. | fixed (0.1.521) - one paste rule everywhere (`Paste.swift`), Copy edits… and Paste in the editor and the library; logic tests. Phone: P7 |
| A13 | **Thumbnails never show AI-mask adjustments** (sky, subject, people, landscape, depth masks). Thumbnails come from a fresh decoder that works out only Lens Blur's masks; a regression from eca6a78. `[2]` | code: Graph.swift:221–231; LibraryStore.swift:958; EditorView.swift:149 | Sim: Sky mask −1 EV, back to library, thumbnail differs from an unedited one in the sky. | fixed (0.1.552) - closing an edited photo makes the library thumbnail from the picture already decoded in the editor (`renderThumbnail`): the AI masks that are worked out show on it, and the photo is not decoded again |
| A14 | **An SDR export from the editor differs from the same export from the library** when the photo is edited in HDR: the editor exports from its HDR decode, the library from an SDR decode. `[2]` | code: EditorViewModel.swift:1692; LibraryStore.swift:662 | Engine test: both paths, "Include HDR" off, compare pixels. | fixed (branch) - the library export now decodes the way the editor does (edits.hdr, not edits.hdr AND includeHDR): the Include-HDR toggle only controls the gain map, so an SDR export from the two paths is the same photo again |
| A15 | **The before/after split line doesn't follow the finger.** Its drag reads the moving handle's own coordinates; every other handle uses a named space. Cause of the flaky `testClippingWarningAndBeforeAfterSplit` (0.53 < 0.6). `[1]` | sim (flaky), code: EditorView.swift:610 | UI test: slow drag to 0.8 → 0.8 ± 0.03, 5 runs. Phone P4. | fixed (branch) - the split handle reads its drag in a full-canvas named space (splitSpace, like every other handle) instead of its own 30 pt frame; the test now asserts the line lands at the drag point, not just 'moved' |

### Failures handled (R4)

| # | Finding | Evidence | Reproduce / verify | Status |
|---|---|---|---|---|
| A16 | **"AI Denoise on but its result is missing" is silent.** After a model update (`modelVersion`), an iCloud restore (results are not backed up, edits are) or a damaged result file, the photo quietly loses AI Denoise in preview and thumbnails, the pill shows unlit while the setting stays on, and the next export re-cleans for 1–2 min with no progress or cancel (a batch: N times; fails if another clean holds the lock: "Export failed."). The launch sweep keeps old-version results forever (~300–500 MB each). No free-space check before any clean; no `denoiseFits` check for export or library batch. `[1+2]` | code: Denoise.swift:101, 145–181, 259–276, 348, 374, 417–450; Graph.swift:246–251; LibraryStore.swift:515; Panels.swift:207, 220 | Logic tests: version bump, truncated file, low free space → clear state and message; export asks first. | fixed (0.1.552) - AI Denoise on with its cleaned copy gone says so once on opening; editor and library exports no longer clean for a hidden minute inside the export, they stop and say how to clean the photo first (`renderDataOutcome(allowClean:)`); results of an older model version are swept at launch |
| A17 | **Every export failure says only "Export failed."**; when depth is unavailable, every export of a photo with Lens Blur fails. `[2]` | code: Graph.swift:250, 253, 269; EditorViewModel.swift:1703; LibraryStore.swift:684 | Engine test: no depth model → export reports Lens Blur and offers without it. | fixed (0.1.569) - every failure has its own message; Lens Blur with no depth estimate offers "Export without Lens Blur" (the saved edit keeps it) |
| A18 | **AI failures read as "nothing found".** Subject, people, scene and depth return nil on any error; that's stored as "tried" for the session and shown as "No people found in this photo"; a failed model load is remembered. `[2]` | code: Masks.swift:501, 614, 809, 877; Engine.swift:20, 147–151; EditorViewModel.swift:1481–1490 | Logic test with a failing request → "couldn't run, try again", retry possible. | fixed (0.1.521, batch 4) - AI failures say "couldn't run" with Try again; engine test + targeted UI tests |
| A19 | **Batch export and Remove people can't be cancelled** (only AI Denoise can). `[1]` | code: LibraryStore.swift:647; EditorViewModel.swift:1347 | UI test: batch export of 3, Cancel → stops after the current photo. | fixed (branch, 23 Oct) - batch export: a Stop button on the progress overlay sets exportCancel, the loop stops between photos, the photos already done are kept, and the summary says "Export stopped after N of M". Remove people: the picker's Cancel already existed; now the removal run itself (one heal per person) can be stopped with a Stop button under the busy badge - what's removed stays removed. Both mirror the existing AI-Denoise cancel flag pattern. Needs a UI check of the two new buttons. |
| A20 | **Library batch AI Denoise loose ends:** stays paused after a quick app switch (the "paused" result arrives after the return-to-screen check); a photo deleted during its clean leaves a result kept forever; no `denoiseFits` check. `[2]` | code: LibraryStore.swift:562–569 vs 625–628, 765, 515 | Logic test of the pause/resume order. | fixed (0.1.521, batch 4) - stray cleaned file removed, paused batch carries on; code review only |

## B. Suspected risks (confirm before fixing)

| # | Risk | Why suspected | How to confirm | Status |
|---|---|---|---|---|
| B1 | **CI runs every UI test as a low-memory phone.** `os_proc_available_memory()` very likely returns 0 in the simulator: the low tier (2048 px preview, no AI Denoise), no 100 % copy, the original copy skipped, and a 3 s pause before every heavy job (HeavyWork's new wait). Would make UI tests slower, skip real paths, and make `testLowMemoryPhoneZooms` meaningless. `[2]` | code: MemoryBudget.swift:12, Diagnostics.swift:82–85, HeavyWork.swift:82–85 | Log `MemoryBudget.summary` in a UI run. | fixed (0.1.562) - `uitest.yml` takes `memory=3400`: the suite runs as a standard phone (the memory gates, the 100 % copy). First full run: 90 of 90 passed. The default stays the fast low-memory run |
| B2 | **GPU work in the background isn't paused or checked** (only AI Denoise pauses): exports, heals, Remove people, AI masks, thumbnails keep rendering; iOS refuses background GPU work and Core Image doesn't throw; Heal's check passes an all-black result in dark scenes. Possible black or partial patches and exports after pressing Home. `[2]` | code: no `beginBackgroundTask`; Heal.swift:354–357 | Phone only: Home during a heal / batch export; look for black results. | fixed (0.1.562) - heavy jobs do not start while Lumen is in the background (`HeavyWork.isForeground`); AI Denoise keeps its own pause. Logic test |
| B3 | **Heal and AI Denoise don't compose.** Patches are baked from the decode at the time (with that AI Denoise amount and HDR mode) and painted over every later decode: heal-then-denoise leaves noisy spots; denoise-then-heal-then-lower leaves clean spots; an HDR-made sky patch may not match in SDR or in thumbnails. `[1+2]` | code: Engine.swift:463–467; Heal.swift:238 | Engine test: noisy photo, heal, then denoise; noise inside vs outside the patch; HDR→SDR patch vs ring. | won't fix (23 Oct, reason in the note after the table of versions above): the patch has no sensor noise and is painted after AI Denoise, so it is unaffected by the amount; matching grain would be a new feature |
| B4 | **Brush masks with long strokes bloat everything:** every point kept; the sidecar saved every 0.5 s on the main thread; up to 201 history snapshots rewritten after each save; the History list re-diffs all steps on every redraw; the brush raster redrawn from scratch on each finger move on the main thread. `[1+2]` | code: Masks.swift:170; LibraryStore.swift:422–447; EditSettings.swift:649–668; EditorViewModel.swift:988–996 | Sim: 20 long strokes → sidecar/history size, save time; phone P3. | fixed (0.1.562) - a brush stroke is reduced to the points that give its shape when the finger lifts (Ramer-Douglas-Peucker, 1.5 px on the preview, at most 300 points); logic tests |
| B5 | **Moving AI Denoise strength re-decodes the photo** (and rebuilds the 100 % copy when zoomed). | phone 0.1.459 ("100% view: building" ×5 in 20 s); code | Count reloads per slider move in the demo log. | mitigated (0.1.562) - a decode after a pause of the slider is one decode at a time (0.1.546), and the 100 % copy is made 2 s later, once, instead of after every pause |
| B6 | **Repeated AI work:** subject-at-a-point re-runs Vision; each model renders its own 1024 px copy; each heal blends over the whole picture; export works out masks at full size under 30 MP (fixed in #91, not merged). `[1+2]` | code | Engine timings before/after. | fixed (0.1.593) - the original copy once at a time, export masks from the small copy for every photo over 2700 px, a 30 MB/MP + 700 export estimate; the other parts of B6 (each model's own 1024 px copy, a heal blending over the whole picture) are cost, not memory: left as they are |
| B7 | **The canvas may redraw the whole photo on unrelated screen updates** (`updateUIView` always calls `setNeedsDisplay()`), competing with AI Denoise for the GPU. `[1]` | code: CanvasView.swift:221–234 | Count "draw canvas" log lines during a clean. | fixed (branch) — `updateUIView` now redraws only when the layout (xform/HDR) changed; image changes and view resizes keep their own redraw paths. Existing UI tests (zoom, pan, rotate, split, every tool) guard that the canvas still follows the finger; phone P-check: watch for a frozen canvas |
| B8 | **iOS RAW decoder changes aren't tracked:** stored AI Denoise noise and heal patches assume today's decode; an iOS update with a new RAW engine could misalign them. `[2]` | code: Engine.swift:427–442 | Record the decoder version per photo; compare on update. | fixed (0.1.552) - AI Denoise results remember the RAW decoder (`CIRAWFilter.decoderVersion`) they were made with; another decoder after an iOS update counts as missing (the A16 notice) |

## C. Cleanup (no user-visible change)

- C1 Heal's full-resolution texture path, off since 18 Oct (~130 lines + 2 kernels). `[1]`
- C2 HEIC 10-bit HLG fallback for iOS < 18: unreachable. `[1+2]`
- C3 `healEnd` calls `freeMemoryForHeal()` twice; `bandWeights` allocates per LUT entry. `[1]`
- C4 Shared statics written from worker threads (`healFailure`, `healDiagnostics`, `healModelReady`, `denoiseTimings`). `[1]`
- C5 Memory thresholds in five places (700/1300/1500/2000 MB): one policy. `[1]`
- C6 `DepthField.usefulRange` unused; HeavyWork comment says release drops the 100 % copy (it doesn't). `[2]`
- C7 The engine test re-implements the sidecar migration instead of testing the real `decodeSettings`. `[2]`
- C8 After a clean, if the photo was decoded again meanwhile, the requested strength isn't applied and the flag stays set (EditorViewModel.swift:391). `[2]`
- C9 Exports keep GPS location with no option to remove it (worth a switch before the App Store). `[2]`

## D. Underlying causes (several findings share each)

1. **Saving and loading trust everything** → A1, A2, A5, A16: `try?` on every write, no backup on a format mismatch,
   saving on open, strict history decoding. One save path that reports failures and one tolerant, versioned load.
2. **Background work has no owner and no lifecycle** → A4, A7, A19, A20, B2, B5: jobs run on shared queues, aren't
   cancelled when the photo closes, aren't paused in the background (except AI Denoise), and are lost or orphaned when
   the editor goes. A job owner per photo; library-owned jobs for work that must outlive the editor.
3. **Memory is managed per job, not per app** → A8, A9, B1, B4: the coordinator admits jobs against free memory
   but can't see or release the models and copies that use most of it, and some decodes bypass it.
4. **Edits depend on files and decodes that can change or go missing, silently** → A16, A17, A18, B3, B8: missing
   heal patches, AI Denoise results and AI masks fall back without telling anyone.
5. **Two versions of the same operation have drifted apart** → A12, A13, A14, C7: paste (4 places), editor vs batch
   export decode, thumbnail vs editor masks, the test's copy of the migration.
6. **EditorViewModel holds ~15 flags in one 1,723-line class** (AI Denoise alone has 8): most October bugs were flag
   combinations; it makes causes 2 and 3 hard to fix safely.

## E. Fix batches (proposed, awaiting Angelo's approval)

Each batch: one branch; reproduce first (test written and failing where practical); fix; build + engine + full UI
suite; an independent review of the diff; this checklist updated; ported to the App Store version (sandbox). Main PRs
are left **ready, not merged**: merging publishes to SideStore, and that waits for Angelo.

0. **Measurement and test foundation** (no behaviour change): settle B1 and make CI run as a standard phone unless a
   test asks; a fast logic-test target (seconds, every push) for loading/migration, paste, history, memory policy;
   the real migration under test (C7); diagnostics timings (open → first frame, frame time while dragging p50/p95,
   export per photo, AI mask per model, memory at editor close and after it is freed); a 12 MP iPhone ProRAW sample
   in CI; settle the flaky tests' causes (Lens Blur release, pinch, StoreKit); record baselines in section F.
1. **Your work is safe:** A1, A2, A3, A5, A6, A4 (results survive leaving the editor; patch sweep).
2. **Responsive, no build-up:** A7, A8, A9, A10, A11, B2 (pause and check GPU work in the background), B7.
3. **Features together, correct output:** A12, A13, A14, A15, B3 (decide after the engine measurement), plus PR #91
   (export masks, original copy, export memory) and PR #92 (diagnostics Findings).
4. **Failures handled:** A16, A17, A18, A19, A20.
5. **Performance:** B4, B5, B6, then measure everything against section F.
6. **Structure:** extract the AI Denoise and Heal jobs as small state machines with tests; one memory policy (C5);
   cleanup C1–C9; bring main into sandbox by merge instead of cherry-picks.

## F. Performance baselines

| Measure | Mac (engine test 22 Oct, run 39836799362) | Phone (iPhone 17 Pro Max) |
|---|---|---|
| Open 24 MP ARW (decode + analysis, preview) | 2.6 s + 1.5 s | < 1 s to "photo ready" (0.1.465) |
| Render one frame 1260 px, default / heavy edits | 44 / 50 ms | not measured yet (batch 0) |
| AI masks incl. depth, 24 MP | — | ~7–14 s (0.1.459 / 0.1.465) |
| Heal, one spot | 12–15 s (CPU model) | ~2 s |
| Remove one person | — | ~4 s |
| AI Denoise 24 MP | 662 s (CPU) | 55 s, 0.43 s/tile (0.1.465) |
| AI Denoise 48 MP ProRAW | — | 110 s (21 Oct) |
| Export 24 MP JPEG | 8.4 s | not measured yet (batch 0) |
| Peak memory in a session | Mac footprint, not comparable | 2.70 GB (0.1.465), 1.86 GB denoise run |
| Memory between photos after a clean | — | ~900–1000 MB (A8) |
| iPhone ProRAW | not covered: add raw.pixls.us iPhone 12 Pro IMG_1361.DNG (12 MP) | 48 MP from phone runs only |

## G. Phone tests (short, specific)

- P1 Memory after AI Denoise: open a 24 MP ARW, Send diagnostics (note "Memory now"); run AI Denoise; back to the
  library; wait 30 s; Send diagnostics again.
- P2 Import: import 10 ProRAW photos from Photos and try scrolling the library meanwhile.
- P3 Brush: paint ~20 long brush strokes; does painting stay smooth?
- P4 Split: ⋯ → View → Before/after split; drag slowly; does the line stay under your finger?
- P5 48 MP: open a 48 MP ProRAW, zoom to 100 %, heal one spot, export; Send diagnostics.
- P6 Background: start Remove people (or a batch export of 5) and press Home straight away; come back; any black
  patches or broken files?
- P7 Copy and paste (0.1.516): in the library tick a photo → Copy → pick only Light + a mask → tick two others →
  Paste. Do they take exactly what you chose? Open one: no second prompt, masks sit right. Try a photo with AI
  Denoise: Paste should ask before cleaning (about a minute).
- P8 Remove asks first: tick a photo → Remove. A question appears first; Cancel keeps it; Remove takes it out at once.
- P9 Edits survive: change a slider, press Home straight away, kill Lumen from the app switcher, open it again: edit
  still there. Open a photo and leave without touching anything: it must not appear as "edited".
- P10 AI masks undo/redo: add a Subject or Sky mask, Undo, Redo: the mask should return at once (no 7–14 s wait).
- P11 Memory: the same P1 run on 0.1.516; compare "Memory now" with 0.1.465 (about 900–1000 MB after a clean).

## H. Test failures and their causes

| Test | Seen | Cause | Status |
|---|---|---|---|
| testClippingWarningAndBeforeAfterSplit (0.53 < 0.6) | full suite 21 Oct | A15: split drag uses the moving handle's coordinates | cause found (code) |
| testLensBlurRevisionsAndPhotoInfo ("preview must clear") | full suite 22 Oct; passed alone | suspected: the test reads the log right after the drag; poll for 2 s — if "false" never comes, it's a real stuck preview | batch 0 |
| testPinchZoomsAndDoubleTapToggles | now and then | simulator double-tap timing (suspected); B1 may add load | batch 0 |
| StoreKit testAnnualUnlocksPro (no products in 10 s) | sandbox 22 Oct, first test only | suspected: products requested at app launch before the test session exists | batch 0 |
| iPhone SE: testLandscapeEveryToolFitsInTheSideColumn | 22 Oct | real 2 pt overlap of Crop's side panel at 667 pt width (Angelo: low priority) | won't fix now |
| testHealDeletionPrivacy (4 of 9), testFailedSavesRecover… (2 of 7), testNextPhotoDoesNotWaitForAIMasks, testCopyOnlyTheChosenTools | overnight full suite 23 Oct, repeatable | **not flakes**: A10 delete regression; check raced the demo setup; test swiped where swiping is off; test tapped the row not the switch | fixed on `quality-fixes`, verification below |
| iPhone SE: testPhotoRestsOnThePanelAndGrowsUpwardsWhenZoomed | 22 Oct | the test assumes spare height above a landscape photo; the SE has none | test to adapt |
