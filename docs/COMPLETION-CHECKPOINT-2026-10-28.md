# Completion checkpoint — SideStore0.1.774 released, 28 October2026

The owner resumed and prioritized getting the fixes into SideStore. Publication is complete; broader validation
continues. Never describe every feature, full suite, AI photographic quality or phone memory as completely proved.

## Released state

- Main#180 merged24c29b7d2e188d5f28be474207bd8a7f96257291; reviewed source6d4f50d, application0a7e2a3.
- SideStore0.1.774 publication40783343904 succeeds. Fresh feed, publish log and GitHub asset agree:
  356120040bytes; SHA2569fce6d2106086b02b27239bef8f7b5378cff4612a82223a28fcaa1f8cc0874c1.
- Sandbox#181 merged079a63f683dd05ff697814b3fc3d562d3a7f3c3d, source97babf0. Shared editor parity complete.
  Unrelated local MARKETING.md and docs/appstore/LISTING.md remain uncommitted and must stay excluded.
- Phone: LocalDevVPN on, SideStore My Apps, refresh, Update Lumen. Preserve installation/library/originals.

## Actual evidence

- Shared focused40782782695 passes465 renderer/retention checks plus25 RAW/Subject memory checks. All28 Swift
  compiler inputs plus Kernels.metal have identical committed blobs in personal6d4f50d and sandbox97babf0.
- Personal40782233771 also passes all pixel assertions and Subject memory2399MB; shared2432MB. Previous2716MB;
  unchanged limit2650MB. Non-caching materialization with post-pool GPU cache clearing produced the reduction.
  RAW-decoder cache release alone and action autorelease pools did not demonstrate that benefit.
- Six related UI methods40781694994 pass; failed-search and valid-empty messages now visibly differ, screenshots
  inspected. Pixel-equivalent RAW decoder recreation and signed guided coefficients pass. Protected readiness
  40782199912 passes. Sandbox OFF/ON/export policy/build identity/four StoreKit tests40781697900 pass atdbd9359;
  later97babf0 only changes engine tests/workflow, not the application or compile-check inputs.
- Brush metric remains variable: personal648→max716→689MB fails maxgrowth64MB, identical shared656→709→668MB
  passes. Exactly one cached component throughout. Fixed8warmup+16measured real100-run rebuilds, all24 logged.
  Do not widen limits or claim every suite green; investigate process/driver heap measurement separately.
- New Lens Add failures were saturated fixtures (coverage already1), corrected to partial selection with unchanged
  response thresholds and a direct target assertion. Production Lens mapping did not change for this correction.
- Grain size0/100, geometry and HDR Lens fixture renders inspected. These are deterministic synthetic evidence,
  not a substitute for original-phone photographic quality. Model weights/inference settings remain unchanged.

## Pick up next

1. Read full engine quality/24MP+ProRAW memory40783385204 and full UI40783388166, both on released24c29b7.
   Do not dispatch duplicates while running. The earlier756 export logged virtualGPU OOM; new memory export now
   asserts file success rather than silently counting a nil result. Investigate any actual failure before claiming done.
2. Stabilize the brush retention benchmark with evidence of allocator/driver settling and actual live bitmap ownership.
   Keep64MB retention bound; do not fit a threshold to one runner or confuse cold/reusable heaps with accumulated history.
3. Phone Clarity/brush/Lens/grain feel, memory and automatic-thumbnail refinement confirmation. No2,000-image run.
4. Real noisy RAW/ProRAW colour/detail/seams, Heal structured texture/HDR and subject-edge blur; source reviews and
   synthetic fixtures cannot certify these. Read AI-VISUAL-REVIEW-2026-10-28.md before proposing model changes.

Details: ADJUSTMENT-COMPLETION-2026-10-28.md and QUALITY-CHECKLIST.md. Keep main protected, use PR/readiness,
verify fresh feed/log/IPA after releases, port shared fixes preserving Store hooks. Never stage .local or sandbox
marketing/listing changes with editor work. No Netlify or App Store submission authorized by this release.
