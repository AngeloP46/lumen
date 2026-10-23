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
| **A22: memory spikes right after AI Denoise on a 48 MP photo** (Lens Blur 20, 2 masks, Detail open): 1454 MB at the end of the clean, then 2764, 2837 and 3083 MB within 7 s (limit 3375), warnings x6, closed a few seconds later. The clean itself was fine (101 s, 0.43 s/tile, 0 redone). **Cause not found.** Candidates: the preview reload with the cleaned copy, the thumbnail made again on closing the editor, the Lens Blur masks; a Mac probe could not tell (each RAW decode stays in the process, a second decode of the same size adds almost nothing) | phone 0.1.521, 10:11:30-10:11:42 | open. 0.1.533 logs "preview decode: start/done" and "thumbnail: making/done" (photos over 20 MP) with the memory they ran at; the thumbnail is made again on closing only if the edits changed. Send diagnostics after the same steps to see which one it is |
| CI blind spot: the 100 % copy, the standard-memory paths and AI Denoise are never exercised in UI tests | B1 | open: needs a decision, see B1 (a UI test with `-lumenDemoMemoryMB 3375` would exercise the 100 % view gating) |

Idea for the 100 % view (not built): render only the visible part at full size (a cropped lazy decode cost ~400 MB in
the Heal measurement) instead of a whole 4096 px copy (~2.1 GB).

**PR #91 (from the 0.1.465 diagnostics), ready, not merged:** rebased on main 0.1.521 and green (Build IPA, Release
readiness, Engine, six targeted UI tests: hold-to-compare, export quality and size, batch export, before/after split, next
photo). The original copy is made once at a time (diagnostics showed it made five times in 20 s); export works out AI masks
on the 2560 px copy for every photo over 2700 px, not just over 30 MP (B6); the export memory estimate is 30 MB/MP + 700
(a 48 MP export peaked at about 1.1 GB on the phone, the old 60 MB/MP + 800 asked for more than the limit). It waits
for the phone results of 0.1.521.

**Not fixed yet (known, recorded):** `LoadedModel` can start a second load for a waiter after a release; A13
(thumbnails don't show AI masks: needs a design decision); A16; B1 (CI runs as a low-memory phone: a decision, the
default tier could be faked in demo mode); B2–B6, B8; B3 (heal × denoise) after the engine measurement. Phone
verification of everything above is outstanding (section G).

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
| A8 | **Memory the job coordinator can't see or free:** the AI Denoise model warmed whenever Detail opens (outside the coordinator, kept 30 s); the Heal model left loaded if Heal is left while it loads; the editor's shared decoder keeping a full-size decode after export or a heal (only AI Denoise and batch export use their own decoder); preview opens, reloads and thumbnails decoding outside it; the "original copy" declared as 450 MB whatever the size; an unlimited thumbnail cache. `[1+2]` | **phone 0.1.465**: between photos after a clean Lumen sat at 892–1001 MB, vs ~300 MB in a session without (0.1.459). code: EditorViewModel.swift:430–440, 1166, 1179, 1257, 1692; Heal.swift:238; Denoise.swift:390–393; LibraryStore.swift:40, 956 | Engine `--memory` step: footprint after export with the session alive, then a heal. Phone P1. Log memory at editor close and when its view model is freed. | partly fixed (branch) — the "original copy" now estimates by the photo's size (~50 MB/MP, was a flat 450 MB that started the job when it couldn't fit) and the thumbnail cache is bounded (200). The Heal model already uses the A9 LoadedModel; the remaining parts (the editor's shared decoder keeping a full-size decode after export, the preview decodes outside the coordinator) stay open for a later pass |
| A9 | **The main thread can freeze while an AI model loads.** `LoadedModel` holds its lock for the whole load; `release()` takes it and is called on the main thread (closing the editor, memory warning, heal start, export, the heal release task). `[1+2]` | code: Engine.swift:12–24; EditorView.swift:149; EditorViewModel.swift:143, 1180, 1239, 1685 | Sim test with a slow fake model load and a release on the main thread; measure the stall. | fixed (0.1.521) - `LoadedModel` loads outside its lock; logic test of release latency. Edge left: a waiter can start a second load after a release |
| A10 | **File work on the main thread that grows with photo size or selection:** Photos imports copy each original (after first writing a temp copy) and read EXIF on the main actor; paste onto N photos reads and writes each; delete waits on the history queue and re-reads every other photo's edits per deleted photo; thumbnails decode on the main thread; the batch-export sheet reads every selected photo's edits. `[1+2]` | code: LibraryStore.swift:910–941, 464–509, 740–756, 44–50; LibraryView.swift:213 | Phone P2; sim: main-thread stall timer in demo mode. | fixed (branch) — `delete` now does the history flush + Heal-patch scan (the per-photo sidecar reads) off the main thread in a detached task; list update, index save and patch removal stay on main as before; the per-file order is unchanged (a failed removal leaves a re-adoptable file, not a lost one). The Photos-import and thumbnail parts were already off-main; paste is left for the next pass |
| A11 | **Editor observers are never removed** (two per photo opened). `[1+2]` | code: EditorViewModel.swift:281, 298–317, 132 | Debug counter after 10 photos. | fixed (branch) — `deinit` now removes `memoryWarning` + `denoiseObservers` + `lifecycleObservers` (added in batch 1 `5deccec`); not yet measured on the phone |

### Features together and output (R3, R5)

| # | Finding | Evidence | Reproduce / verify | Status |
|---|---|---|---|---|
| A12 | **Paste behaves differently in the editor.** ⋯ → Paste edits replaces everything except heals and AI Denoise: the other photo's Lens Blur focus and mask link, Heal switched off, its HDR mode, masks not adapted. The library's "Everything" keeps this photo's Lens Blur and Heal on/off and adapts masks. Paste logic lives in four places. `[1+2]` | code: EditorView.swift:685; EditorViewModel.swift:1399; LibraryStore.swift:464–509 | Logic test: same clipboard through each path → agreed rules hold. | fixed (0.1.521) - one paste rule everywhere (`Paste.swift`), Copy edits… and Paste in the editor and the library; logic tests. Phone: P7 |
| A13 | **Thumbnails never show AI-mask adjustments** (sky, subject, people, landscape, depth masks). Thumbnails come from a fresh decoder that works out only Lens Blur's masks; a regression from eca6a78. `[2]` | code: Graph.swift:221–231; LibraryStore.swift:958; EditorView.swift:149 | Sim: Sky mask −1 EV, back to library, thumbnail differs from an unedited one in the sky. | needs decision (23 Oct overnight) - this is a deliberate trade-off, not a plain bug: eca6a78 deliberately cut thumbnails back to Lens-Blur-only masks because computing every AI mask per thumbnail "loaded the phone and cut a UI-test drag short". The naive fix (always call prepareAutoMasks in the thumbnail path) was already tried and reverted for that reason. A proper fix is a design call: persist derived AI masks to per-photo sidecars so thumbnails reuse them, or a cheaper per-thumbnail mask approximation - both need a real on-phone perf test before landing. Not safe to force overnight. No-mask thumbnails already cost nothing. |
| A14 | **An SDR export from the editor differs from the same export from the library** when the photo is edited in HDR: the editor exports from its HDR decode, the library from an SDR decode. `[2]` | code: EditorViewModel.swift:1692; LibraryStore.swift:662 | Engine test: both paths, "Include HDR" off, compare pixels. | fixed (branch) - the library export now decodes the way the editor does (edits.hdr, not edits.hdr AND includeHDR): the Include-HDR toggle only controls the gain map, so an SDR export from the two paths is the same photo again |
| A15 | **The before/after split line doesn't follow the finger.** Its drag reads the moving handle's own coordinates; every other handle uses a named space. Cause of the flaky `testClippingWarningAndBeforeAfterSplit` (0.53 < 0.6). `[1]` | sim (flaky), code: EditorView.swift:610 | UI test: slow drag to 0.8 → 0.8 ± 0.03, 5 runs. Phone P4. | fixed (branch) - the split handle reads its drag in a full-canvas named space (splitSpace, like every other handle) instead of its own 30 pt frame; the test now asserts the line lands at the drag point, not just 'moved' |

### Failures handled (R4)

| # | Finding | Evidence | Reproduce / verify | Status |
|---|---|---|---|---|
| A16 | **"AI Denoise on but its result is missing" is silent.** After a model update (`modelVersion`), an iCloud restore (results are not backed up, edits are) or a damaged result file, the photo quietly loses AI Denoise in preview and thumbnails, the pill shows unlit while the setting stays on, and the next export re-cleans for 1–2 min with no progress or cancel (a batch: N times; fails if another clean holds the lock: "Export failed."). The launch sweep keeps old-version results forever (~300–500 MB each). No free-space check before any clean; no `denoiseFits` check for export or library batch. `[1+2]` | code: Denoise.swift:101, 145–181, 259–276, 348, 374, 417–450; Graph.swift:246–251; LibraryStore.swift:515; Panels.swift:207, 220 | Logic tests: version bump, truncated file, low free space → clear state and message; export asks first. | scoped (23 Oct overnight, not landed) - several distinct fixes bundled: (a) the launch sweep keeps old-model-version results forever (~300-500 MB each); (b) no free-space check before any clean; (c) no denoiseFits check for export or library batch (low-tier phones); (d) the result-missing state is silent - pill unlit, setting still on, export re-cleans with no progress/cancel. Each part is real work in Denoise.swift + LibraryStore + Panels; deferred to a dedicated pass. A17 already made the resulting export failure say "the cleaned copy could not be made" instead of "Export failed.". |
| A17 | **Every export failure says only "Export failed."**; when depth is unavailable, every export of a photo with Lens Blur fails. `[2]` | code: Graph.swift:250, 253, 269; EditorViewModel.swift:1703; LibraryStore.swift:684 | Engine test: no depth model → export reports Lens Blur and offers without it. | partly fixed (branch, 23 Oct) - renderData now has renderDataOutcome beside it (renderData itself is unchanged, so the engine tests' 8 call sites are untouched) with a specific reason per failure: denoise-missing, decode, depth-unavailable, encode, plus a distinct "not enough memory" when the memory coordinator refuses. Editor and library batch export show those specific messages; the batch also lists the distinct reasons. Follow-up (23 Oct): the format switch no longer falls through - each format returns .failed(.encode) on an encode failure instead of trying the next format (a failed JPEG could otherwise return a HEIC payload named .jpg); found while porting to the sandbox. Still open: Lens Blur with no depth still fails the export (checklist's "offer without it" UX); a UI check for the new messages. |
| A18 | **AI failures read as "nothing found".** Subject, people, scene and depth return nil on any error; that's stored as "tried" for the session and shown as "No people found in this photo"; a failed model load is remembered. `[2]` | code: Masks.swift:501, 614, 809, 877; Engine.swift:20, 147–151; EditorViewModel.swift:1481–1490 | Logic test with a failing request → "couldn't run, try again", retry possible. | fixed (0.1.521, batch 4) - AI failures say "couldn't run" with Try again; engine test + targeted UI tests |
| A19 | **Batch export and Remove people can't be cancelled** (only AI Denoise can). `[1]` | code: LibraryStore.swift:647; EditorViewModel.swift:1347 | UI test: batch export of 3, Cancel → stops after the current photo. | fixed (branch, 23 Oct) - batch export: a Stop button on the progress overlay sets exportCancel, the loop stops between photos, the photos already done are kept, and the summary says "Export stopped after N of M". Remove people: the picker's Cancel already existed; now the removal run itself (one heal per person) can be stopped with a Stop button under the busy badge - what's removed stays removed. Both mirror the existing AI-Denoise cancel flag pattern. Needs a UI check of the two new buttons. |
| A20 | **Library batch AI Denoise loose ends:** stays paused after a quick app switch (the "paused" result arrives after the return-to-screen check); a photo deleted during its clean leaves a result kept forever; no `denoiseFits` check. `[2]` | code: LibraryStore.swift:562–569 vs 625–628, 765, 515 | Logic test of the pause/resume order. | fixed (0.1.521, batch 4) - stray cleaned file removed, paused batch carries on; code review only |

## B. Suspected risks (confirm before fixing)

| # | Risk | Why suspected | How to confirm | Status |
|---|---|---|---|---|
| B1 | **CI runs every UI test as a low-memory phone.** `os_proc_available_memory()` very likely returns 0 in the simulator: the low tier (2048 px preview, no AI Denoise), no 100 % copy, the original copy skipped, and a 3 s pause before every heavy job (HeavyWork's new wait). Would make UI tests slower, skip real paths, and make `testLowMemoryPhoneZooms` meaningless. `[2]` | code: MemoryBudget.swift:12, Diagnostics.swift:82–85, HeavyWork.swift:82–85 | Log `MemoryBudget.summary` in a UI run. | checked (23 Oct overnight) - confirmed the mechanism: limitMB = footprintMB + os_proc_available_memory(), and the simulator returns ~0 for that, so every UI test lands on the low tier (2048 px, no AI Denoise, 3 s pre-job pause). The code is CORRECT on real phones - they report their true limit. So this is not a bug to fix, it is a test-fidelity decision: CI currently only ever tests the low-tier path and never the standard/high paths (denoise, 100% copy). The proposed fix (run CI at a faked standard tier via -lumenDemoMemoryMB, keeping testLowMemoryPhoneZooms as the one low test) is a broad change to every test's behaviour and speed and is not safe to flip unattended overnight - left as a decision. |
| B2 | **GPU work in the background isn't paused or checked** (only AI Denoise pauses): exports, heals, Remove people, AI masks, thumbnails keep rendering; iOS refuses background GPU work and Core Image doesn't throw; Heal's check passes an all-black result in dark scenes. Possible black or partial patches and exports after pressing Home. `[2]` | code: no `beginBackgroundTask`; Heal.swift:354–357 | Phone only: Home during a heal / batch export; look for black results. | open |
| B3 | **Heal and AI Denoise don't compose.** Patches are baked from the decode at the time (with that AI Denoise amount and HDR mode) and painted over every later decode: heal-then-denoise leaves noisy spots; denoise-then-heal-then-lower leaves clean spots; an HDR-made sky patch may not match in SDR or in thumbnails. `[1+2]` | code: Engine.swift:463–467; Heal.swift:238 | Engine test: noisy photo, heal, then denoise; noise inside vs outside the patch; HDR→SDR patch vs ring. | open |
| B4 | **Brush masks with long strokes bloat everything:** every point kept; the sidecar saved every 0.5 s on the main thread; up to 201 history snapshots rewritten after each save; the History list re-diffs all steps on every redraw; the brush raster redrawn from scratch on each finger move on the main thread. `[1+2]` | code: Masks.swift:170; LibraryStore.swift:422–447; EditSettings.swift:649–668; EditorViewModel.swift:988–996 | Sim: 20 long strokes → sidecar/history size, save time; phone P3. | open |
| B5 | **Moving AI Denoise strength re-decodes the photo** (and rebuilds the 100 % copy when zoomed). | phone 0.1.459 ("100% view: building" ×5 in 20 s); code | Count reloads per slider move in the demo log. | open |
| B6 | **Repeated AI work:** subject-at-a-point re-runs Vision; each model renders its own 1024 px copy; each heal blends over the whole picture; export works out masks at full size under 30 MP (fixed in #91, not merged). `[1+2]` | code | Engine timings before/after. | open |
| B7 | **The canvas may redraw the whole photo on unrelated screen updates** (`updateUIView` always calls `setNeedsDisplay()`), competing with AI Denoise for the GPU. `[1]` | code: CanvasView.swift:221–234 | Count "draw canvas" log lines during a clean. | fixed (branch) — `updateUIView` now redraws only when the layout (xform/HDR) changed; image changes and view resizes keep their own redraw paths. Existing UI tests (zoom, pan, rotate, split, every tool) guard that the canvas still follows the finger; phone P-check: watch for a frozen canvas |
| B8 | **iOS RAW decoder changes aren't tracked:** stored AI Denoise noise and heal patches assume today's decode; an iOS update with a new RAW engine could misalign them. `[2]` | code: Engine.swift:427–442 | Record the decoder version per photo; compare on update. | open |

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
