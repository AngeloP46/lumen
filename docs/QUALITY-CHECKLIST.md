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

## A. Confirmed bugs, ranked by user impact

### Work safety (R1)

| # | Finding | Evidence | Reproduce / verify | Status |
|---|---|---|---|---|
| A1 | **Opening a photo can permanently drop its masks, or all its edits, and its undo history.** When the strict decode fails (an older build after a rollback, a renamed mask kind, a new required field), `decodeSettings` retries without masks, then falls back to defaults, with no backup (a backup is kept only when the JSON doesn't parse at all). The editor then **saves on open**: `start()` sets `settings` → `settingsChanged` → `scheduleSave()` even while loading. History is decoded strictly with no migration, so it resets and is overwritten. `[2]`, damaged-file part `[1]` | code: LibraryStore.swift:293–344, 380–393; EditorViewModel.swift:171, 527–537; EditSettings.swift:45, 180, 200, 234 | Logic test: sidecar with `"kind":"futureKind"` / a missing `MaskComponent` key → masks kept, backup written, history loads, nothing written on open. | open |
| A2 | **Failed saves are silent.** Edits, history, photo list and presets are written with `try?`; storage full or a write error loses work with no message. A photo copied in but never listed (index write failed, or the app died mid-import) stays invisible: orphan files are adopted only when `index.json` is damaged. `[1+2]` | code: LibraryStore.swift:421, 446, 809–813, 943–947, 232–237 | Logic test on a read-only folder → error surfaced, edit kept in memory, retried; orphan file adopted at launch. | open |
| A3 | **"Remove from Lumen" on one photo deletes at once, with no confirmation or undo** (multi-select delete asks). It removes Lumen's copy, edits, history, heals and AI Denoise results. `[2]` | code: LibraryView.swift:~298 vs 200–209 | UI test: long-press → Remove → a confirmation appears. | open |
| A4 | **Leaving the editor during a heal, Remove people or export loses the result**, and the heal's patch files stay on disk. Back is always enabled; ⋯ → Previous/Next skip `canNavigate`; completions hold the editor weakly. Heal patches whose undo step falls off the 100-step history also stay forever. `[1+2]` | code: EditorView.swift:661, 695–696; EditorViewModel.swift:1215, 1374, 1700; HealStore has no sweep | UI test (`-lumenDemoPeople` + slow heal hook): tap Back while removing → result kept or navigation blocked; logic test: unreferenced patch swept at launch. | open |
| A5 | **A pending edit isn't saved when Lumen leaves the screen.** Saves wait 0.5 s; the resign handler writes history only. `[2]` | code: EditorViewModel.swift:544–555; LibraryStore.swift:109–112 | UI test: change a slider, send to background within 0.3 s, relaunch → change kept. | open |
| A6 | **A release build can ship without AI Denoise.** `build-denoise.sh` leaves an empty model and exits 0 on failure; `build.yml` publishes it; exports then silently skip AI Denoise. `[2]` | code: .github/ci/denoise-convert/build-denoise.sh:12, Graph.swift:246 | CI check: main builds fail if any `Models/*.mlmodelc` lacks `coremldata.bin`. | open |

### Responsiveness and memory (R2)

| # | Finding | Evidence | Reproduce / verify | Status |
|---|---|---|---|---|
| A7 | **The next photo waits behind the previous photo's work.** One serial `workQueue` (file-level, shared by every editor) runs preview decodes, AI masks, the 100 % copy, heals, Auto and preset thumbnails; nothing is cancelled when a photo closes; reloads aren't merged (five undos through heals = five full decodes). `[1+2]` | **phone 0.1.465**: open AWP09650 19:27:28; previous photo's AI masks finish 19:27:33; "photo ready" 19:27:33 (5 s). code: EditorViewModel.swift:7, 458–509; HeavyWork.swift:67–75 | UI test: photo with a Depth mask + `-lumenDemoSlowAI`, swipe at once → next photo ready < 2 s (demo log "loaded … queued Xs"). | fixed (branch) — AI masks moved to their own `aiMaskQueue` (memory gating stays with HeavyWork); new UI test `testNextPhotoDoesNotWaitForAIMasks` parses "queued" from the log. The cancellation and reload-merging parts remain for a later item |
| A8 | **Memory the job coordinator can't see or free:** the AI Denoise model warmed whenever Detail opens (outside the coordinator, kept 30 s); the Heal model left loaded if Heal is left while it loads; the editor's shared decoder keeping a full-size decode after export or a heal (only AI Denoise and batch export use their own decoder); preview opens, reloads and thumbnails decoding outside it; the "original copy" declared as 450 MB whatever the size; an unlimited thumbnail cache. `[1+2]` | **phone 0.1.465**: between photos after a clean Lumen sat at 892–1001 MB, vs ~300 MB in a session without (0.1.459). code: EditorViewModel.swift:430–440, 1166, 1179, 1257, 1692; Heal.swift:238; Denoise.swift:390–393; LibraryStore.swift:40, 956 | Engine `--memory` step: footprint after export with the session alive, then a heal. Phone P1. Log memory at editor close and when its view model is freed. | open |
| A9 | **The main thread can freeze while an AI model loads.** `LoadedModel` holds its lock for the whole load; `release()` takes it and is called on the main thread (closing the editor, memory warning, heal start, export, the heal release task). `[1+2]` | code: Engine.swift:12–24; EditorView.swift:149; EditorViewModel.swift:143, 1180, 1239, 1685 | Sim test with a slow fake model load and a release on the main thread; measure the stall. | open |
| A10 | **File work on the main thread that grows with photo size or selection:** Photos imports copy each original (after first writing a temp copy) and read EXIF on the main actor; paste onto N photos reads and writes each; delete waits on the history queue and re-reads every other photo's edits per deleted photo; thumbnails decode on the main thread; the batch-export sheet reads every selected photo's edits. `[1+2]` | code: LibraryStore.swift:910–941, 464–509, 740–756, 44–50; LibraryView.swift:213 | Phone P2; sim: main-thread stall timer in demo mode. | fixed (branch) — `delete` now does the history flush + Heal-patch scan (the per-photo sidecar reads) off the main thread in a detached task; list update, index save and patch removal stay on main as before; the per-file order is unchanged (a failed removal leaves a re-adoptable file, not a lost one). The Photos-import and thumbnail parts were already off-main; paste is left for the next pass |
| A11 | **Editor observers are never removed** (two per photo opened). `[1+2]` | code: EditorViewModel.swift:281, 298–317, 132 | Debug counter after 10 photos. | fixed (branch) — `deinit` now removes `memoryWarning` + `denoiseObservers` + `lifecycleObservers` (added in batch 1 `5deccec`); not yet measured on the phone |

### Features together and output (R3, R5)

| # | Finding | Evidence | Reproduce / verify | Status |
|---|---|---|---|---|
| A12 | **Paste behaves differently in the editor.** ⋯ → Paste edits replaces everything except heals and AI Denoise: the other photo's Lens Blur focus and mask link, Heal switched off, its HDR mode, masks not adapted. The library's "Everything" keeps this photo's Lens Blur and Heal on/off and adapts masks. Paste logic lives in four places. `[1+2]` | code: EditorView.swift:685; EditorViewModel.swift:1399; LibraryStore.swift:464–509 | Logic test: same clipboard through each path → agreed rules hold. | open |
| A13 | **Thumbnails never show AI-mask adjustments** (sky, subject, people, landscape, depth masks). Thumbnails come from a fresh decoder that works out only Lens Blur's masks; a regression from eca6a78. `[2]` | code: Graph.swift:221–231; LibraryStore.swift:958; EditorView.swift:149 | Sim: Sky mask −1 EV, back to library, thumbnail differs from an unedited one in the sky. | open |
| A14 | **An SDR export from the editor differs from the same export from the library** when the photo is edited in HDR: the editor exports from its HDR decode, the library from an SDR decode. `[2]` | code: EditorViewModel.swift:1692; LibraryStore.swift:662 | Engine test: both paths, "Include HDR" off, compare pixels. | open |
| A15 | **The before/after split line doesn't follow the finger.** Its drag reads the moving handle's own coordinates; every other handle uses a named space. Cause of the flaky `testClippingWarningAndBeforeAfterSplit` (0.53 < 0.6). `[1]` | sim (flaky), code: EditorView.swift:610 | UI test: slow drag to 0.8 → 0.8 ± 0.03, 5 runs. Phone P4. | open |

### Failures handled (R4)

| # | Finding | Evidence | Reproduce / verify | Status |
|---|---|---|---|---|
| A16 | **"AI Denoise on but its result is missing" is silent.** After a model update (`modelVersion`), an iCloud restore (results are not backed up, edits are) or a damaged result file, the photo quietly loses AI Denoise in preview and thumbnails, the pill shows unlit while the setting stays on, and the next export re-cleans for 1–2 min with no progress or cancel (a batch: N times; fails if another clean holds the lock: "Export failed."). The launch sweep keeps old-version results forever (~300–500 MB each). No free-space check before any clean; no `denoiseFits` check for export or library batch. `[1+2]` | code: Denoise.swift:101, 145–181, 259–276, 348, 374, 417–450; Graph.swift:246–251; LibraryStore.swift:515; Panels.swift:207, 220 | Logic tests: version bump, truncated file, low free space → clear state and message; export asks first. | open |
| A17 | **Every export failure says only "Export failed."**; when depth is unavailable, every export of a photo with Lens Blur fails. `[2]` | code: Graph.swift:250, 253, 269; EditorViewModel.swift:1703; LibraryStore.swift:684 | Engine test: no depth model → export reports Lens Blur and offers without it. | open |
| A18 | **AI failures read as "nothing found".** Subject, people, scene and depth return nil on any error; that's stored as "tried" for the session and shown as "No people found in this photo"; a failed model load is remembered. `[2]` | code: Masks.swift:501, 614, 809, 877; Engine.swift:20, 147–151; EditorViewModel.swift:1481–1490 | Logic test with a failing request → "couldn't run, try again", retry possible. | open |
| A19 | **Batch export and Remove people can't be cancelled** (only AI Denoise can). `[1]` | code: LibraryStore.swift:647; EditorViewModel.swift:1347 | UI test: batch export of 3, Cancel → stops after the current photo. | open |
| A20 | **Library batch AI Denoise loose ends:** stays paused after a quick app switch (the "paused" result arrives after the return-to-screen check); a photo deleted during its clean leaves a result kept forever; no `denoiseFits` check. `[2]` | code: LibraryStore.swift:562–569 vs 625–628, 765, 515 | Logic test of the pause/resume order. | open |

## B. Suspected risks (confirm before fixing)

| # | Risk | Why suspected | How to confirm | Status |
|---|---|---|---|---|
| B1 | **CI runs every UI test as a low-memory phone.** `os_proc_available_memory()` very likely returns 0 in the simulator: the low tier (2048 px preview, no AI Denoise), no 100 % copy, the original copy skipped, and a 3 s pause before every heavy job (HeavyWork's new wait). Would make UI tests slower, skip real paths, and make `testLowMemoryPhoneZooms` meaningless. `[2]` | code: MemoryBudget.swift:12, Diagnostics.swift:82–85, HeavyWork.swift:82–85 | Log `MemoryBudget.summary` in a UI run. | open — **check first** |
| B2 | **GPU work in the background isn't paused or checked** (only AI Denoise pauses): exports, heals, Remove people, AI masks, thumbnails keep rendering; iOS refuses background GPU work and Core Image doesn't throw; Heal's check passes an all-black result in dark scenes. Possible black or partial patches and exports after pressing Home. `[2]` | code: no `beginBackgroundTask`; Heal.swift:354–357 | Phone only: Home during a heal / batch export; look for black results. | open |
| B3 | **Heal and AI Denoise don't compose.** Patches are baked from the decode at the time (with that AI Denoise amount and HDR mode) and painted over every later decode: heal-then-denoise leaves noisy spots; denoise-then-heal-then-lower leaves clean spots; an HDR-made sky patch may not match in SDR or in thumbnails. `[1+2]` | code: Engine.swift:463–467; Heal.swift:238 | Engine test: noisy photo, heal, then denoise; noise inside vs outside the patch; HDR→SDR patch vs ring. | open |
| B4 | **Brush masks with long strokes bloat everything:** every point kept; the sidecar saved every 0.5 s on the main thread; up to 201 history snapshots rewritten after each save; the History list re-diffs all steps on every redraw; the brush raster redrawn from scratch on each finger move on the main thread. `[1+2]` | code: Masks.swift:170; LibraryStore.swift:422–447; EditSettings.swift:649–668; EditorViewModel.swift:988–996 | Sim: 20 long strokes → sidecar/history size, save time; phone P3. | open |
| B5 | **Moving AI Denoise strength re-decodes the photo** (and rebuilds the 100 % copy when zoomed). | phone 0.1.459 ("100% view: building" ×5 in 20 s); code | Count reloads per slider move in the demo log. | open |
| B6 | **Repeated AI work:** subject-at-a-point re-runs Vision; each model renders its own 1024 px copy; each heal blends over the whole picture; export works out masks at full size under 30 MP (fixed in #91, not merged). `[1+2]` | code | Engine timings before/after. | open |
| B7 | **The canvas may redraw the whole photo on unrelated screen updates** (`updateUIView` always calls `setNeedsDisplay()`), competing with AI Denoise for the GPU. `[1]` | code: CanvasView.swift:221–234 | Count "draw canvas" log lines during a clean. | open |
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

## H. Test failures and their causes

| Test | Seen | Cause | Status |
|---|---|---|---|
| testClippingWarningAndBeforeAfterSplit (0.53 < 0.6) | full suite 21 Oct | A15: split drag uses the moving handle's coordinates | cause found (code) |
| testLensBlurRevisionsAndPhotoInfo ("preview must clear") | full suite 22 Oct; passed alone | suspected: the test reads the log right after the drag; poll for 2 s — if "false" never comes, it's a real stuck preview | batch 0 |
| testPinchZoomsAndDoubleTapToggles | now and then | simulator double-tap timing (suspected); B1 may add load | batch 0 |
| StoreKit testAnnualUnlocksPro (no products in 10 s) | sandbox 22 Oct, first test only | suspected: products requested at app launch before the test session exists | batch 0 |
| iPhone SE: testLandscapeEveryToolFitsInTheSideColumn | 22 Oct | real 2 pt overlap of Crop's side panel at 667 pt width (Angelo: low priority) | won't fix now |
| iPhone SE: testPhotoRestsOnThePanelAndGrowsUpwardsWhenZoomed | 22 Oct | the test assumes spare height above a landscape photo; the SE has none | test to adapt |
