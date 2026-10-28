# Lumen session entry point

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
