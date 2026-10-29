# Lumen session entry point

**Latest verified: SideStore0.1.782,29Oct.** Main#184 mergedfe0a94c (sourced9c4064);
publish40791387290 succeeds. Freshfeed/log/asset agree356122572bytes,
SHA2564f7f7307d51c6d938640687fadb4472a5ca92a991f9676a4f108912b5a9432e4.
Shared sandbox#185 mergedbe2d802 after both builds/policy/identity/four StoreKit40788980740 pass.
All500 focused checks40789795464 pass: actual12checkpoints use2IOSurface backings,100run rebuild452ms,
16measured replacements564→max584→576MB under unchanged64MBgrowth.245 imaging/Clarity/cache/batch checks
pass40788880285;32RAWthumbnailcleanup1230–1240MB. Full774UI96/96passes40783388166;three currentUIspotchecks
40790759752 pass. Owner explicitly prioritized this publication before more long checking.

**Current verification:** full current engine40790966338 is now complete:2014 quality assertions,35 24MP memory
checks including AI Denoise,26 ProRAW checks pass. Real native HDR outputs reopen6000x4000 and3024x4032 with
HDR/ISO gain maps; export peaks5176/4463MB, denoise4973MB. This is distinct from the earlier failed40789798207:
that run aborted134 with virtualGPU OOM/MPSmedian assertion during encoding, before output inspection.
It remains intermittent evidence, not a diagnosed phone crash. No claim that a green retry alone fixes it.
Branch `native-export-resource-handoff` fixes exact-argument,90-second bounded crash diagnostics and adds three
consecutive native HDR exports after Heal in the narrow memory case. App/model code is unchanged; validate this
bounded case before any new cache-lifetime policy. Do not lower resolution, omit HDR or raise memory budgets.

**30-day sharing IPA:** owner requested it AFTER verified SideStorepublication. Existingtester-build workflow
40792070982 succeeded onfe0a94c withdays30. Verified file delivered at
LumenIPA/tester-2026-10-29/Lumen.ipa for manualGoogleDriveupload; ZIP/modelpresence/expiry/hash all checked. It expires30days from BUILD, not install.
PersonalSideStore app never gets that expiry. See current completioncheckpoint and reviewsummary.
Earlier status entries below are historical.

**Current follow-up:** released774 full engine quality40783385204 passes all1977 checks; its24MP/ProRAW memory
and full UI40783388166 remain live. Branch`brush-checkpoint-pooling` tests per-build half-float checkpoint buffer
reuse to reduce resource churn behind the variable brush heap metric. Final cachedR8 stays independent; fallback
allocation preserves masks on pool failure. New buffer-address reuse/fingerprint checks retain8+16/64MB limits.
Independent source review found no ownership/format/alias blocker. Candidate is not yet rendered or published.

**Latest verified: SideStore0.1.774, 28 October.** Main#180 merged24c29b7 (source6d4f50d,
application0a7e2a3); publication40783343904 succeeded. Fresh feed/log/GitHub asset agree:
356120040bytes, SHA2569fce6d2106086b02b27239bef8f7b5378cff4612a82223a28fcaa1f8cc0874c1.
Shared sandbox#181 merged079a63f; OFF/ON/policy/build identity/four StoreKit checks40781697900 pass.
All465 focused renderer checks and25 short memory checks pass40782782695 on identical29 committed
compiler/kernel inputs. Personal parallel Subject2399MB, shared2432MB, below unchanged2650MB;
six related UI methods40781694994 and protected readiness40782199912 pass; screenshots inspected.
Brush/Lens Blur/Grain/Vignette/Heal fixes and one-active visible-first basic/refined thumbnail revision4 are released.
Non-caching source/mask materialization reduced the measured memory; RAW cache release alone did not.
No layout, Store policy, model weights/inference or recipeformat3 changes; no2,000photo run.

**Remaining:** full engine/24MP+ProRAW memory40783385204 and full UI40783388166 are running on released24c29b7.
Do not call them green before reading results. Personal focused40782233771 passed pixels/Subject but its brush
GPU-heap high-water growth check failed648→716→689MB (64MB bound); identical shared run656→709→668passed.
Track measurement variability without raising limits or claiming a phone-memory guarantee. Further photographic
AI/high-ISO/Heal/subject-edge quality and phone timing still need phone evidence. Read the updated completion
checkpoint and quality checklist. All earlier pause/candidate status below is historical; owner resumed and release
is complete. Phone: LocalDevVPN on → SideStore My Apps → refresh → Update; never delete/reinstall.

**28 Oct resumed release follow-up:** owner explicitly resumed and wants the remaining fixes published efficiently.
PR#180 remains the active completion batch; SideStore0.1.756 stays live until a verified new publication.
Focused40758279578 completed430/433: two Lens Add assertions targeted an already100%selected fixture;
the other failure was repeated100-run brush memory growth. UI screenshots40749873518 show the general
missing-model notice hiding the injected people-search result. Correct those causes and verify the actual messages.
Subjectmemory2703/2650MB still needs measured improvement; do not raise budgets. See the completion report for
candidate RAWdecoder-cache release and bounded scalar brush checkpoints. No2,000photo run or model changes.
The older pause checkpoint below is historical; user has now asked to continue.

**28 Oct usage checkpoint — owner requested a quick conclusion and continuation after usage resets.**
Personal SideStore0.1.756 remains verified live. Do not merge/publish completion PR#180 yet.
Source6f09c23d8d8f356c9cd6a4d372ad3bb3746a5e2a on `adjustment-quality-completion` compiles (40749848570).
Logic passes320a724 (40749723296); newer changes since that are view extraction/tests only.
TargetedSubjectmemory40749869459 still fails2703/2650MB; pools+coefficient barrier are NOT a measured solution.
TargetedUI40749873518: five methods pass; newpeople failure/empty method has two failed text assertions910/919.
Do not assume testaccessibility vsactualmessaging until inspectingits artifact. Newfocused adjustments run40758279578
was started on6f09c23; re-check its live/terminal state rather than restarting blindly. Allnewpixel regressions,
grain/brush timings and geometryreferences still need execution/outputinspection. FullUI and finalmemory/ProRAW
also remain; no2,000photo run. Sandbox draft `sandbox-adjustment-completion` is prepared but unvalidated, preserves
unrelated MARKETING.md and docs/appstore/LISTING.md. Read docs/COMPLETION-CHECKPOINT-2026-10-28.md first next time.

**Active completion batch, 28 Oct:** `adjustment-quality-completion` from currentmain c2472cb. Owner said
"dont stop till youre done" and authorized parallel agents. Candidate: brush compositing consistency and bounded
rasters; Lens Blur manual focus/refinement/HDR radiance; filtered Grain Size and aspect-normalized Vignette;
missing Heal patch and failed people detection; one-active visible-first basic/refined thumbnail scheduling.
Memory run40738195410 quality passes1644 but subject memory2658MB exceeds2650; export also logs virtualGPU OOM.
Explicit source-analysis/subject autorelease pools and per-work-item editor queues are being validated; budgets
are unchanged. Memory sampler now keeps the whole-step peak despite diagnostic substep callbacks.
New production-path tests plus small library scheduling fixtures; no literal2,000-photo run. Validation pending;
SideStore0.1.756 remains the latest verified release. Do not claim candidate fixes or phone memory validated.

**Latest: SideStore 0.1.756 is published and feed/log/GitHub asset verified.** Main #176 merged 737e4fe,
source f6e3465, publish 40738521966. IPA 356082659 bytes, SHA256
b13e5cc8200f6b9a1d8493a2d92147de0fbbf8154c5b73089734e695f8cf7365.
Clarity correction from 0.1.747 retained. AI export failure-state fixes now released: missing denoise/cache,
structurally invalid legacy PNG, failed automatic/inverted masks, outcome transfer and Landscape retry.
132 focused GPU regressions and six related UI cases pass. Independent source reviews completed.
Full engine quality 40738195410 passes all 1644 checks; its longer memory sequences are still running.
The earlier 1638/1639 run's sole failure was a CIColor test
fixture assumption, diagnosed and corrected with raw-scalar/native/scaled/alpha checks, without loosening tolerance.
Sandbox #175 merged 8649421, #177 merged a54fa93; both OFF/ON/policy/four StoreKit checks pass
(40732458311 / 40737807973). No Store code, pricing or model inference changed.
See docs/AI-RELIABILITY-2026-10-28.md and docs/QUALITY-CHECKLIST.md for evidence and remaining work.
Brush compositing, Lens Blur focus/refinement/HDR, Grain/Vignette ranges, Heal/detection error paths, broader
photographic validation and the larger-library scheduler remain queued. Do not claim every adjustment is finished.
Phone verification of new Clarity/reliability remains needed; owner confirmed thumbnail recovery works.
Earlier status entries below are historical.

**Prior Clarity release, 28 Oct: SideStore 0.1.747 was published and feed/log/asset verified.**
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

Tester delivery verified29October: workflow40792070982 succeeded onfe0a94c (samecode as SideStore0.1.782).
Localfile C:\Users\pc user\Projects\app development\LumenIPA\tester-2026-10-29\Lumen.ipa,
version0.1.3/build3 (separate tester workflowcounter), expiry2026-11-28T00:00:00Z,356048440bytes,
SHA2563d7499ab90eb674c4c64a233af8eb4502c73dd432dc93d65a9361bdf1bdebcae. ZIPCRC passes andall4AI models
have nonemptycoremldata.bin. build-details.json/README.txt arebeside it. Ownerreceivedthelink for manualGoogleDrive
upload; no externalupload/send performed. Old26October tester IPA preserved. SideStorepublication precededtesterbuild.
Fullcurrentenginequality40790966338 passes2014assertions; itslongmemoryphase wasstillrunninglastcheck.
