# Current continuation — shared revisions complete, 14 October 2026

The checkpoint below is historical. Security-only publication 38627206272 succeeded;
SideStore 0.1.200 feed version/build/size/hash/URL verified. Lens Blur revisions and
photo information have since been implemented in both main and sandbox, and merged
through protected PR #2 (main 34b72c3). Read CLAUDE.md and PRODUCT-BRIEF.md for the
current status and owner-confirmed iPhone/RAW/all-popular-brands product direction.

Final app source d383f7e; test revision e9d997b. Passed: engine/metadata 38631365097
(79 checks), focused UI 38631369309 (one combined test, zero failures), IPA
38631360377, PR build/readiness 38632032581, sandbox policy/OFF-ON 38631373218.
Screenshots/renders inspected. No full UI suite was run. Personal SideStore is unlocked.

Angelo approved publication; SideStore 0.1.207/build 207 is now published and verified.
Run 38634930064 succeeded on main fbe5b7a; com.example.lumen, Lumen-207.ipa,
322324910 bytes, SHA256 4d5b0b1faa801f21a87ce2c4401e87135783ce9041b535dd556c0b0eaede94c6.
Feed version/build/URL/size/hash matched the release. It includes the shared revisions.
No repeated tests needed for this publication of unchanged checked source.
Real-phone RAW/HDR subject quality and speed remain owner checks.

Sandbox is on sandbox; payment and watermark code remain separate. Its checks_only
workflow now skips sample downloads/simulator boot/screenshot setup. Existing untracked
docs/APPSTORE-PLAN.md and .github/ci/__pycache__/ were preserved. Do not stage them.

---

# Lumen continuation — 14 October 2026

Read AGENTS.md and CLAUDE.md before code work. Owner wants a fresh chat to reduce
context/usage. This file records the exact checkpoint; do not repeat completed work.

## First finish security publication

- Main canonical: C:\Users\pc user\Projects\app development\Lumen (branch main).
- Sandbox canonical: sibling Lumen-Sandbox (branch sandbox).
- Original Downloads\GP work children are junctions. Canonical writes/network/git
  require approved elevation in this session. No Mac locally; GitHub Actions builds.
- Main security commit: 02b4e1b3499a907c6e80dbc3845c6f717a597223, merged PR #1:
  https://github.com/AngeloP46/lumen/pull/1
- Sandbox security commit: ccc760da13bb0b0677d58993b9c958886a3ac2ad.
- Final security-only SideStore publication run 38627206272 was IN PROGRESS at
  handoff (assess passed, device build running). Inspect it; fix failures if needed.
  Verify the sidestore release source.json version/build/hash/size/download URL
  before reporting a new update ready. Do not rerun completed tests unnecessarily.
- Last verified phone release before this run: 0.1.197. The security update removes
  deleted photo Heal remnants; it DOES NOT include the Lens Blur revisions below.
- Main and personal SideStore remain completely unlocked: no payment, watermark,
  subscription or Store code changes. Preserve sandbox payment code separately.

## Security fixes complete and checks passed

- Sandbox embedded origin credential removed; clean HTTPS URL. GitHub CLI uses
  system keyring. Owner confirmed deleting the old token; Git access reverified.
  Never print sandbox old config/backups or credentials. GitHub CLI path:
  C:\Program Files\GitHub CLI\gh.exe, repo AngeloP46/lumen.
- Secret scanning and push protection enabled. Main protected: PR required,
  Release readiness check from GitHub Actions app 15368, strict current branch,
  admin enforcement, no force pushes/deletion, zero additional reviewers (sole owner).
  Do not bypass or disable protection. Normal protected PR #1 passed and merged.
- Read-only build/test tokens, checkout credentials not persisted; only isolated
  main publish job writes releases, rejecting stale main commits. Test renders are
  Actions artifacts. Build actions pinned to exact commits; XcodeGen 2.46.0 checked
  SHA256; three models immutable revisions + every-file sizes/SHA256. Source cache
  verified; compiled model cache ignored and rebuilt.
- Heal deletion covers current/undo/redo/owned patches (including trimmed future
  history); preserves other-photo/preset/clipboard references; active render leases
  defer cleanup. Late Heal writes and delayed saves cannot resurrect deleted data.
  Older orphan patches absent from all sidecars cannot safely be attributed; corrupt
  retained sidecar warns and preserves patches. No destructive global sweep.
- Passed: six model-security unit cases/local workflow policy; personal IPA/model
  build 38625860904; focused testHealDeletionPrivacy 38625864692 (1 test, 8 storage
  cases, 0 failures); sandbox payment OFF/ON compile 38625938312 (success, screenshots
  skipped); protected PR build/readiness 38626612845 (success). Empty commit 5da887a
  only triggered PR checks; app source identical to tested 1ae535d.
- Sandbox checks_only input skips screenshots but currently still fetches samples
  and boots simulator. Optional tidy: skip these setup steps and screenshot artifact
  too when checks_only=true; no need to rerun compilation for that workflow-only tweak.
- Public unrestricted IPA/source remain public for free standard Mac builds and
  working SideStore feed. Distribution before Pro sales still needs owner's decision;
  do not make private/delete feed/add paywall without agreement. Account 2FA unverified.

## Next: requested Lens Blur revisions (NOT implemented yet)

Owner authorized these shared improvements in both personal and sandbox:
- Automatically select/protect the whole subject; tap focus should understand the
  selected subject, not merely sample a single depth pixel. Camera RAW/Sony is primary.
- First explicit Lens Blur activation should start amount 8; untouched photos stay
  unchanged. Preserve saved user zero/off values when reopening.
- Make blur progressively stronger farther behind the focus plane; current mask
  ramps briefly then saturates. Estimated depth is relative, not measured metres.
- Improve far-distance slider travel/calibration; derive useful focus range from
  subject depth distribution and protect the whole subject despite depth errors.
- Recheck Near/Far depth-mask slider constraints. Current 0...50 feather range and
  endpoint disabling/bar caps still limit the owner's real use. Previous Middle
  slider test passed but did not establish these endpoints are satisfactory.
- Refine background must stay INSIDE Lens Blur and reuse detailed mask controls,
  brush/add/subtract/refinement UI; retain linked mask in Masks for Light/Colour edits.
- While Lens sliders are actively touched, show the existing red mask overlay;
  hide on release and offer a preview-off preference. Respect crop/rotation geometry.
- Existing readable horizontally scrolling toolbar stays. No landing-page changes.

Current Lens code: Views/LensBlurView.swift, Views/EditorView.swift, Edit/EditorViewModel.swift,
Edit/EditSettings.swift, Edit/Graph.swift, Edit/Masks.swift, Views/MaskViews.swift.
Vision computeSubject is private in Masks.swift; reuse actual instance/subject masks
and depth distribution, provide honest manual fallback when detection fails.
Existing amount default is 0, distance .3, width .12; pickLensFocus samples depth;
Refine switches to Masks. Do not claim these behaviors already satisfy new feedback.

## Working conventions / preserving work

Owner nontechnical: explain outcomes simply; act without unnecessary permission
questions, run only meaningful focused tests. Parallel work previously authorized,
but avoid needless agent/tool usage. Do not run full UI suite for this security fix.
Stage named files only: existing untracked docs/APPSTORE-PLAN.md belongs to earlier
work; .github/ci/__pycache__ is local test output. This handoff is newly saved/untracked.
Use owner noreply git author, especially sandbox (default author Sandbox LLM).
Never print remote URLs unless confirmed clean; clean push URL is
https://github.com/AngeloP46/lumen.git . Update CLAUDE.md/HANDOFF.md with final evidence.
Main notes currently describe validation as pending: update after publication through
a NOTES-ONLY PR (quick assess/readiness, Mac build skipped). Do not advance main with
notes before publication: publisher intentionally refuses a stale main build.
Branch/code commits [skip ci] require manual focused checks; PR-generated Release
readiness must exist on latest head. Manual workflow checks started BEFORE PR creation
were not associated with PR #1; an empty non-skip commit correctly triggered PR checks.
Merge via protected GitHub PR, never direct main push. Main merge [skip ci] avoids
duplicate automatic full engine/UI runs; manually dispatch build.yml main to publish.
User wants fresh-chat handoff, so continue from this checkpoint without re-auditing.
