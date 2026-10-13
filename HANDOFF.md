# Lumen App Store project — status & hand-off (for a new chat)

**Last updated:** 13 Oct 2026 (by PC ASSISTANT, chat with Angelo)

## One-line summary

Lumen (free RAW photo editor for iPhone, `github.com/AngeloP46/lumen`) is being prepared for
the App Store with a Photomator-style **export-gate subscription** model. The main developer
(Claude, Anthropic) is offline ~48h; a capable **local LLM** is drafting the App Store code in
an isolated sandbox in the meantime.

## Where everything lives

| Thing | Where |
|---|---|
| The full plan (source of truth for the work) | `C:\Users\pc user\Downloads\GP work\Lumen\docs\APPSTORE-PLAN.md` |
| Real repo (Claude works here, pushes to GitHub) | `C:\Users\pc user\Downloads\GP work\Lumen` |
| Sandbox (local LLM works here — do not edit it yourself) | `C:\Users\pc user\Downloads\GP work\Lumen-Sandbox` |
| Sandbox rules the local LLM must follow | `Lumen-Sandbox\SANDBOX-BRIEF.md` |
| Local LLM's own work log (it writes this) | `Lumen-Sandbox\SANDBOX-LOG.md` (created by the LLM) |
| GitHub branch with the local LLM's pushed work | `sandbox/` branch on github.com/AngeloP46/lumen — https://github.com/AngeloP46/lumen/tree/sandbox |
| Test results from GitHub | repo → **Actions** tab (pass/fail) and the `test-previews` GitHub release (rendered ARW preview sheets) |

## Decisions already made (all locked, see plan §11)

- **Free export:** Light & Color + crop/rotate + presets only. **Pro:** curves, detail, HDR, all
  masks, heal → export requires the subscription.
- **Prices:** ≈£1/month (7-day trial) + ≈£8/year → closest Apple UK tiers.
- **Watermark:** clearly visible, large, corner, ~15–25% opacity, Pro-edited previews only,
  App Store build only.
- **iPhone-only** at launch, **instant release to 100%**, **worldwide, English only**.
- **Name:** placeholder **"Lumaforge"** in all code (that name is taken on the App Store — final
  name is Angelo's to pick before Gate 4; "Lumen" is also taken).
- **SideStore build stays frozen** — no paywall, no watermark, everything works. The existing
  `build.yml` (SideStore feed) and `project.yml` must never change for this work.

## What happened in the last chat (timeline)

1. Researched and wrote `docs/APPSTORE-PLAN.md` (v2, export-gate model) — gates 1–5, Claude's
   build spec, Apple setup steps, marketing plan, RAW-format findings.
2. **RAW finding:** the app already decodes all major camera RAW via Apple's CIRAWFilter —
   the "Sony-only" problem is mostly wording, plus a test matrix to prove (CR2/CR3/NEF/RAF/
   ARW/DNG/ProRAW must open, edit, export — hard requirement before Gate 2).
3. Built the sandbox: clone in `Lumen-Sandbox`, brief written, `sandbox/` branch created on
   GitHub and pushed. A 2-day fine-grained token (repo: lumen, Contents read/write) is embedded
   in the sandbox's `origin` remote — **it expires ~15 Oct**; after that the sandbox cannot
   push. Do not print or copy the remote URL (it contains the token).
4. Angelo created the token at github.com/settings/tokens; if it's revoked/expired, re-pointing
   the sandbox remote needs a fresh token (see SANDBOX-BRIEF for the rules).

## What to do next (in order)

1. **Check on the sandbox** (if Angelo asks "how's it going?"): read
   `Lumen-Sandbox\SANDBOX-LOG.md`, check `git log` in `Lumen-Sandbox`, and look at the Actions
   tab of the sandbox branch (browser: https://github.com/AngeloP46/lumen/actions — branch
   `sandbox`). Report: what was drafted, whether the engine test passes, open questions.
2. **When Claude's usage is back (~15 Oct):** give him the hand-off message below.
3. **Gate 3 (Angelo, free):** landing page + waitlist + ~2 weeks of before/after clips before
   any money is spent (plan §7).
4. **Gate 4 (Angelo, ~$99):** developer account, App Store Connect setup (plan §6), final name,
   TestFlight beta, submit.

## Message to give Claude when he's back (paste in his chat)

> Read `docs/APPSTORE-PLAN.md` in the repo before doing anything. It's a researched launch plan
> — treat it as the source of truth for the App Store route.
>
> A local LLM drafted App Store code while you were offline: review the **`sandbox/` branch** on
> GitHub (https://github.com/AngeloP46/lumen/tree/sandbox) and `SANDBOX-LOG.md` there. Treat
> everything as unreviewed draft — verify, fix, and rebuild it properly in the main repo.
>
> Then continue at **Gate 2**: the RAW test matrix (CR2, CR3, NEF, RAF, ARW, DNG, ProRAW —
> open/edit/export) is a hard requirement before we move on. The SideStore pipeline and
> `project.yml` stay frozen; all App Store work is additive, in new files, behind the build flag.
> Angelo decides the items in §11 of the plan; present options, don't decide for him.
>
> When done: RAW test results, what you kept from the sandbox draft, and what's left before Gate 3.

## How updates are tracked (no extra file needed)

- **Local LLM's progress:** its git commits in `Lumen-Sandbox` + `SANDBOX-LOG.md` + the
  `sandbox/` branch on GitHub + Actions results.
- **Claude's progress:** his commits in the real repo (`Lumen` folder) + his updates to
  `CLAUDE.md` (he keeps a status log there) + GitHub Actions.
- **Decisions/status for humans:** this file + `docs/APPSTORE-PLAN.md` §11. Keep §11 and this
  file updated when Angelo makes a new decision — that's the whole tracking system.

## Gotchas

- The token in the sandbox's git remote: don't display, copy or commit it. It's limited to the
  lumen repo and expires in 2 days anyway.
- Don't push anything to `main` from `Lumen-Sandbox` (the brief forbids it; the SideStore feed
  publishes from main only).
- Don't rename/move/delete anything in `Lumen-Sandbox` or the `Lumen` folder — just read and
  report.
- The plan is in the REAL repo's `docs/` — if it gets updated, update it there (it's committed),
  not just in the sandbox.
