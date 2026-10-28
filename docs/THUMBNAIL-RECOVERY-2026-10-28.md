# Thumbnail recovery and Clarity phone follow-up

## Published recovery

SideStore **0.1.737**, main #171 merged `300008d` (source `4df9b79`), publish `40678586380`.
Fresh feed, publish log and uploaded IPA agree: **356071476 bytes**, SHA256
`78fff6e803a7d00567f50333058711b89d9b914efe8669662ddb2122150264e1`.

The owner reported 0.1.728 closing during thumbnail generation after about 25 photos and repeating the same work
after relaunch. His iPhone18,2 diagnostics showed 24 MP thumbnail/depth work reaching **3371 of 3375 MB**.
The all-library completion marker had not been reached, so startup deleted the already-written JPEGs again.
Earlier single-photo engine memory sequences passed but did not reproduce this batch pattern.

The recovery uses per-photo, renderer-revision filenames and atomic writes. Each completed thumbnail is durable
without waiting for the rest of the library. Older JPEGs remain visible until replacement succeeds. Each RAW job
has an autorelease boundary, reusable GPU/model resources are evicted between jobs, and decoded grid images have
a 64 MB cost limit. Optional thumbnail work reserves source-size memory and cannot overlap other heavy jobs;
when it cannot fit, it leaves its thumbnail unfinished for a later retry instead of squeezing into the limit.

`LoadedModel` also retained its last result after clearing its primary cache. The hand-off now lasts only until
waiting callers consume it, without starting a second model load while they wake up. Active jobs retain their own
models. Weights, compute units, inputs and numerical inference paths were not changed.

Clarity now uses a broader, stronger medium-detail band. Abrupt boundaries are detected locally before their
protection is extended, so a smooth surface is not excluded merely because its total brightness range is large.
Signed squared travel gives fine control near zero; positive contrast is softly bounded and negative strength
remains a convex blend toward the broad base. No legacy rendering implementation was reintroduced.

## Evidence and limits

- Final source build/readiness `40677646205` and Linux logic `40677638960` pass. Logic includes exact thumbnail
  restart progress, retained older JPEGs, low-memory refusal, thumbnail/editor mutual exclusion and 32 actual
  weak-reference model-release checks, plus the existing concurrent-load/waiter tests.
- Render source `e419c08` passes **126 checks** in `40677111283`; `4df9b79` only adds coordinator admission rules,
  their logic checks and documentation. Clarity -100/0/+100 medium-band EV amplitudes: **.092/.350/.940** at
  1280 px and **.095/.350/.936** at 2560 px; the fine band stays near .060. Fine-grain, flat, hard-edge and fine
  central-travel guards pass. RAW/JPEG endpoint sheets inspected.
- The same 24 MP Sony RAW was thumbnailed **32 consecutive times**, including Lens Blur/depth preparation, saved
  to disk and cleaned up each time. Settled Mac memory remained **1276–1277 MB**. This measures retained growth,
  not transient peak or phone memory. It is not a claim about 32 different cameras or 2,000 real photographs.
- Six persistence/UI tests pass in `40677114414` with a simulated 3375 MB limit: save recovery, Heal deletion,
  history, no sidecar save on open, selected-tool copy and library paste. The Heal fixture's old expected count
  was corrected from 9 to 11; all 11 underlying privacy checks remain. Broad UI `40677638862` is still follow-up.
- Phone recovery, memory peak and Clarity feel still need the owner's new-build observations. The Mac cannot
  establish iPhone residency or model GPU precision. No 2,000-photo run was started or required before release.
- Shared sandbox port is PR #172, source `b97513f`; OFF/ON/policy/StoreKit `40678793157` pending. Store code/prices
  unchanged. Unrelated sandbox marketing/listing edits preserved.

## Larger-library work follows the recovery

The owner wants a large library to work in small batches, release memory, prioritise visible images and defer
expensive refinement until a photograph is selected for editing. He explicitly requested the phone recovery
before any 2,000-image test, then clarified that a literal 2,000-image run is unnecessary.

The current recovery already serializes/bounds memory and retains completed disk work. It still initially queues
the missing thumbnails; the more selective scheduler is **not in 0.1.737**. The draft is preserved locally at
`.local/large-library-queue-wip.patch`. Complete/review it on a separate branch, not by changing this release:

1. Queue only photo IDs; materialize one recipe/source/model lease at a time. Deduplicate requests, promote visible
   photos, yield between small batches and pause while the editor or background is active.
2. Reuse an existing finished thumbnail for expensive old looks; avoid running automatic masks/depth models for
   every background grid rebuild. Use a bounded basic preview when no prior thumbnail exists.
3. Persist basic/refined quality separately. An unchanged photo currently skips `updateLibraryThumbnail` because
   of `changedSinceOpen`; a photo needing refinement must refresh from its prepared editor preview even when
   the user makes no edit. Clear queued work when that refined image is saved so it cannot be overwritten by an
   older basic job. Include depth selections via `needsAnalysis`, not only `isAutomatic`.
4. Keep failed/pressure-skipped requests bounded with backoff, and never reclassify a pressure skip as unreadable.
   Preserve the existing unreadable-photo indication if `EditSession` construction itself fails.
5. Verify scheduling, restart, deletion, editing priority and quality-upgrade rules with a small set of IDs and
   controlled workers. Repeat a modest real RAW batch to check memory stability. A literal 2,000-image run is
   optional throughput measurement, not required to understand or validate the bounded architecture.
