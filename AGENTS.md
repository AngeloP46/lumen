# Lumen session entry point

28 Oct resumed work: `clarity-single-engine` fixes weak Clarity, migrates every old recipe/history/preset to the
one current renderer and removes legacy processing code. The queued AI review also found deterministic mask/
noise-cache defects being corrected with regression coverage. Builds/release pending; 0.1.714 is still live.

Read `CLAUDE.md` in this folder before working on Lumen, the iPhone app or SideStore.
It holds the architecture, build and phone setup notes.
Read `PRODUCT-BRIEF.md` too. It defines the platform, audience, camera coverage and
product direction; use it for every feature, UI, testing and copy decision.

27 Oct 2026: adjustment-engine quality work is on `imaging-quality-v2`, starting from `2ad11b8`.
Read `docs/IMAGING-QUALITY.md` for the algorithms, legacy saved-edit protection and rollback instructions.
Angelo explicitly authorised implementing, validating and publishing the personal SideStore update, with shared
fixes also in the sandbox. Published and verified 28 Oct: SideStore 0.1.714 (PR #167, merge 0607d03,
publish run 40607002239). Full engine/memory checks passed (1,270 quality checks). Angelo requested publication
with 5% chat usage remaining and the rest of review afterwards: full UI run 40604410069 and sandbox PR #168
need follow-up. Sandbox remains unmerged: check 40604979559 failed after OFF/ON builds. PR #167 has the handoff.

28 Oct owner correction: next update should migrate all old saved edits/presets/copied settings to the new engine
and remove legacy processing code, keeping original photos and adjustment values. Existing rendering may change.
0.1.714 still retains legacy behaviour; the migration is not implemented. Read CLAUDE.md's latest direction first.
Outstanding image-quality reviews are queued in docs/QUALITY-CHECKLIST.md, "Next adjustment reviews". Angelo
asked to resume them when usage is available; this is a saved task list, not an instruction to start now.
Latest phone feedback: Clarity -100/+100 is barely distinguishable. This is now the first review/fix priority;
see CLAUDE.md and the first queued checklist item for the suspected signal cancellation and reproduction plan.

The canonical project folder is `C:\Users\pc user\Projects\app development\Lumen`.
App Store draft work and its latest handover live in the sibling `Lumen-Sandbox` folder.
Read `Lumen-Sandbox\HANDOFF.md`'s latest update before reviewing that work. Preserve the
existing personal SideStore app; do not publish or merge App Store changes to main without
Angelo's instruction. Windows cannot compile this iPhone app; builds run on GitHub Actions.
