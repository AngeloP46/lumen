# Usage checkpoint and exact next work

Owner requested a quick conclusion with10%usage remaining and continuation after reset. Do not mark the full goal
complete: the new adjustment batch is implemented but has unresolved validation. No new release after0.1.756.

## Authoritative state

- Main workspace branch `adjustment-quality-completion`; PR180 open, source`6f09c23d8d8f356c9cd6a4d372ad3bb3746a5e2a`.
  Branch started frommain`c2472cb`; all application candidates are committed/pushed. `.local` scratch is untracked.
- Personal **SideStore0.1.756** remains verified, main#176 merge`737e4fe`, publication40738521966. Its earlier
  Clarity/AI failure fixes are also in sandbox. Do not replace it with PR180 until the following gates pass.
- Sandbox workspace branch `sandbox-adjustment-completion` holds the same shared candidate plus preserved Store
  gates and explicit RAW-matrix ThumbnailFiles compiler dependency. Separate MARKETING.md and
  docs/appstore/LISTING.md modifications are unrelated and must never be staged with this work.

## Actual latest results

- iPhone Release build **40749848570 passes** on6f09c23. Initial LibraryView compiler timeout was fixed by splitting
  lifecycle modifiers from the existing large view expression; layout is unchanged.
- Logic **40749723296 passes** on320a724; final6f09 change adds GPU test code only. Scheduler fixtures exercise
  one-active IDs, priority/dedup/yield/backoff, atomic quality revisions, old-display retention, generations/deletion,
  recipe freshness and missing-denoise basic quality. No literal2,000-image test.
- Subject-memory **40749869459 fails2703MB versus2650MB**, unchanged limit. Earlier5d97a5f was2758MB; original
  released756 follow-up was2658MB. Variation is not proof of improvement. Latest code has source/Vision pools,
  editor work-item pools, and a full-resolution exact guided-coefficient materialization barrier. It is still over.
  Memory sampler now preserves whole-step peaks across diagnostic callbacks (old callbacks reset the peak).
- Six-method UI **40749873518**: five methods pass; `testRemovePeopleFailureIsDifferentFromNoPeople` has two
  failed assertions at910/919 looking for text. The note exists and busy-state checks pass. Need inspect screenshots
  and accessibility tree/log before deciding whether this is text lookup or real wrong-result handling.
- Focused new pixel/timing run **40758279578** started on6f09c23 (`only=adjustments`). It includes AI/mask state,
  signed-coefficient precision, brush invariance/benchmarks, Heal assets/detection, grain/vignette, Lens HDR/focus/
  refinement and4x geometry references. Read current state/artifact first; do not dispatch duplicates blindly.
- No full new engine/memory or full UI pass yet. The1644-pass suite belongs to the previous0.1.756 source.

## Next sequence

1. Read focused40758279578; fix any real pixel regressions/compile issues without weakening their thresholds.
   Inspect actual rendered images and full-frame grain/brush timing; integrated grain is more shader work.
2. Investigate subject memory. Current hypothesis: CIRAWFilter/session retains its full-size decoder after preview
   and4096copy materialization. A safe releasable decoder could reduce standing memory before Vision, but it is
   **only a proposal, not implemented or validated**. Review Engine init/decode lock/options/decoder identity before
   changing any lifecycle. Preserve exact color/HDR/orientation/RAW settings and no simultaneous duplicate loads.
   Do not raise the budget or reduce image/mask resolution to force green. Also investigate virtualGPU OOM logged
   during the older long export sequence; new full-step sampling may expose a higher true peak.
3. Inspect UI artifact40749873518 (people-search-failed/empty screenshots) and correct the actual message lookup/
   handling. Rerun the related method, then full UI for this broad renderer/library batch.
4. Run full engine quality and both24MP/ProRAW memory sequences, plus source-size-aware modest thumbnail batch.
   User explicitly said no2,000-photo testing before release; deterministic scheduling tests are enough for queue size.
5. Keep one PR per area, protected Release readiness, no admin bypass. Main#180 only merge once needed checks pass.
   Verify fresh SideStore feed/log/IPA digest+size. Then sandbox OFF/ON/policy/StoreKit and merge its shared PR.
   If sandbox draft commit uses `[skip ci]`, manual exact-branch checks are mandatory before its future merge.
6. Update reports/checklist with completed evidence versus actual phone-only/model-quality limits. No blind model
   swap: AI-VISUAL-REVIEW documents synthetic cat denoise and plausible-but-imperfect LaMa texture/structure.

## Implemented scope and tradeoffs

Read ADJUSTMENT-COMPLETION-2026-10-28.md. Candidates cover consistent per-run brush feather compositing (oldsame-
feather edges can change), manualfocus/refineidentity/combinedRGBHDR Lens Blur, footprint-filtered source-relative
grain and shape-normalized vignette, missing Heal assets and typed people-search failures, and visible-first
basic/refined revision4 thumbnail work with generation-safe editor upgrades. Existing recipeformat3 and one current
engine retained. No layout, payment, weights or inference settings changes. All original pixels/values preserved.

Independent agents reviewed each other's code, catching wide-focus bypass, cancellation interacting with active
Heal, missing-denoise thumbnail quality and reload-inflight refinement. Their local notes are in `.local` under
brush-thumbnail-completion-notes.md, effects-followup-notes.md, ai-followup-notes.md and mask-followup-notes.md.
