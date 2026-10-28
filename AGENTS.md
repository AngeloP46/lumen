# Lumen session entry point

**Current authoritative status, 28 Oct: SideStore 0.1.747 is published and feed/log/asset verified.**
Main #174 merged e4c9f97 (source39b9c5d), publish40687659637, 356072974 bytes, SHA256
56e7e0df52bf36d32c1ef7903d8b56305c4bd822a60f1ef34bbdfb671c7a5d36. Clarity's wide hard-edge veto replaced;
owner-approved actual car crop now responds broadly. All142 focused checks, logic, readiness and3 related UI pass.
Other-family SDR/HDR isolation checks prove the bad Clarity channel is not reused. Static independent review
found no actionable numerical/resource/scope defect; phone quality/timing remains unverified.
Full engine40687563996:1553/1557 passed; four small-fixture mask/export probe assumptions under investigation.
Full UI40687567667:94/95 passed; event log proves preview reload completed at fixed timeout boundary.
`clarity-release-followup` corrects test probes and records remaining reviews; do not call broad suites green yet.
Sandbox#175 has shared fix, OFF/ON/StoreKit40732458311 pending. Owner explicitly requested parallel agents;
AI, masks/export and effects/blur reviews resumed. See docs/QUALITY-CHECKLIST.md for actual remaining work.
Earlier dated entries below are historical and do not override this status.

28 Oct next phone finding: owner says 0.1.737 thumbnails work, but Clarity still affects only a tiny bonnet patch.
Actual +/- screenshots confirm windscreen/background essentially unchanged. `clarity-scene-coverage` removes
the broad maximum-dilated veto, replaces Clarity base with a bilateral grid and adds owner's car-proxy, dense-edge
coverage and other-slider isolation tests. Read docs/CLARITY-COVERAGE-2026-10-28.md. Validation/publication pending.
Do not claim another gain increase fixes coverage. Thumbnail recovery and larger-library draft remain separate.

**Latest: SideStore 0.1.737 published and feed/hash verified**, main #171 merged 300008d, publish 40678586380.
It fixes the owner's 0.1.728 startup thumbnail restart/memory regression, releases retained model hand-offs and
strengthens Clarity with fine squared travel near zero. 126 rendered/batch checks, logic/readiness and six targeted
UI cases pass. See docs/THUMBNAIL-RECOVERY-2026-10-28.md for exact evidence, limitations and next scheduler work.
Sandbox #172/check 40678793157 pending. No 2,000-image test is needed; owner requested recovery publication first.
Larger-library queue draft is separate and not in 0.1.737. Phone confirmation and broad UI 40677638862 remain.

Urgent 28 Oct follow-up: owner's 0.1.728 diagnostics show repeated startup thumbnail kills at 3371/3375 MB.
Branch `thumbnail-recovery-clarity` replaces batch invalidation with per-photo revision-named JPEG checkpoints,
preserves older display JPEGs until success, bounds decoded cache, drains each RAW render and uses HeavyWork's
memory reserve. Clarity gets a broader stronger band, abrupt-edge protection and squared travel near zero.
Validation/release pending; do not describe the phone crash as resolved yet. New 32-RAW-thumbnail stress regression.
Prior targeted UI 40673361219: five cases passed; Heal deletion's 11 PASS checks failed the stale expected count 9,
now corrected to 11. This was a test-count mismatch, not a Heal failure. Full UI 40671255251 is superseded.

28 Oct publication complete: **SideStore 0.1.728**, personal PR #169 merged a44a6bd, publish 40672946255.
Fresh feed, publish log and GitHub IPA size/digest agree: 356069402 bytes, SHA256
4e599416fc8ac13908ab0822a6c387fed1f1296afb83cacdda52dea36b0c26e1. All old edits now use one renderer;
Clarity strengthened; exact JSON recovery copies retained. Originals/values preserved; old looks can change.
All 1,315 engine quality checks and both memory sequences pass (40671575491), plus 89 focused checks, logic and readiness.
Sandbox PR #168 also merged 7efb41d; OFF/ON/export-policy/StoreKit checks all pass (40671675913).
Follow up six persistence UI checks 40673361219 and full UI 40671255251; both are still running.
Further review findings are queued in docs/QUALITY-CHECKLIST.md and the dated review reports, including
docs/REMAINING-ADJUSTMENT-REVIEW-2026-10-28.md. Do not call every feature comprehensively validated.

Read `CLAUDE.md` in this folder before working on Lumen, the iPhone app or SideStore.
It holds the architecture, build and phone setup notes.
Read `PRODUCT-BRIEF.md` too. It defines the platform, audience, camera coverage and
product direction; use it for every feature, UI, testing and copy decision.

Adjustment-engine work started from `2ad11b8`; the first improved release was 0.1.714 (main #167, 0607d03).
Read `docs/IMAGING-QUALITY.md` for current algorithms, saved-edit migration, backups and rollback instructions.
Angelo explicitly authorised implementing, validating and publishing the personal SideStore update, with shared
fixes also in the sandbox. 0.1.714 passed 1,270 engine quality/memory checks and full UI 40604410069.
The failed cold StoreKit fixture in 40604979559 was corrected; the final sandbox check above passed.

28 Oct owner correction: all old saved edits/presets/copied settings must use the new engine and duplicate legacy
processing code must go, keeping originals and values. This is implemented in PR #169; existing looks can change.
Legacy tone/colour processing is removed in 0.1.728. Exact old JSON stays as data for recovery; it does not choose
an old rendering implementation. Clarity's weak response was fixed and rendered at two sizes; phone feel remains
to verify. Outstanding reviews are in docs/QUALITY-CHECKLIST.md, "Next adjustment reviews"; Angelo resumed them
with "carry on". Remaining static findings need meaningful reproduction before further algorithm changes.

The canonical project folder is `C:\Users\pc user\Projects\app development\Lumen`.
App Store draft work and its latest handover live in the sibling `Lumen-Sandbox` folder.
Read `Lumen-Sandbox\HANDOFF.md`'s latest update before reviewing that work. Preserve the
existing personal SideStore app; do not publish or merge App Store changes to main without
Angelo's instruction. Windows cannot compile this iPhone app; builds run on GitHub Actions.
