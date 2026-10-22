# App Store listing assets — DRAFT for review (Gate 4)

**Superseded 22 Oct 2026:** final name Lumen RAW, IDs and prices are in `docs/appstore/LISTING.md`; the Lumaforge sections below are the old draft.

Everything Apple asks for, drafted now so Gate 4 is a paste job, not a writing job.
Placeholder name: **Lumaforge** (final name is Angelo's decision — every "Lumaforge" below
is a find-and-replace). Prices: UK store, closest Apple tiers to the plan (≈£1.09/mo, ≈£7.99/yr).

**Status of each item:** [DRAFT] needs Angelo's eyes · [READY] paste as-is · [GATE 4] needs the
account to exist first.

---

## 1. App name [DRAFT]

`Lumaforge` (placeholder) — or final name. Max 30 chars. Must match the binary display name.

## 2. Subtitle (30 chars max) [DRAFT]

Candidates (Angelo picks):
- `RAW editing for your camera` (27)
- `Pro RAW edits on your iPhone` (28)
- `Edit RAW like a pro, on device` (30)

## 3. What's New (v1.0) [DRAFT]

```
Welcome to Lumaforge — pro RAW photo editing that runs entirely on your iPhone.

• Full RAW support: Sony, Canon, Nikon, Fuji, and DNG, decoded with Apple's cinematic image engine
• Light, Color, Curves, Grade and Detail — every adjustment non-destructive
• AI masks: subject, sky, people, landscape, depth and more
• AI heal: remove people, objects and distractions
• HDR export with gain maps for HDR screens
• Free to download; Pro (curves, detail, masks, heal) via subscription
```

## 4. Description (3000 chars max) [DRAFT — Angelo to read and reword anything he'd say differently]

```
Lumaforge is a pro photo editor for RAW files that works entirely on your iPhone — no uploads, no cloud, no subscription to even open your photos.

THE RAW EDITOR
Open the raw file straight from your camera — Sony ARW, Canon CR3, Nikon NEF, Fuji RAF and DNG — and edit it the way a desktop would: full bit depth, full highlight headroom. Lumaforge decodes RAW with Apple's cinematic image engine, so highlights come back in scenes that look flat in every other app.

EVERYTHING, NON-DESTRUCTIVE
Light, Color, Curves, Color Grade, Detail (sharpness, texture, noise), vignette and grain. Every edit is a sidecar file next to your original — the original pixel is never touched, and one tap resets everything.

AI MASKS, ON DEVICE
Subject, Sky, People, Landscape, Depth, plus linear, radial, luminance and colour masks. The AI runs on your phone: nothing leaves it.

AI HEAL
Lasso a person or an object and Lumaforge paints the scene back behind it — locally, with an on-device inpainting model.

HDR EXPORT
Export JPEG or HEIC with a gain map: brighter highlights on HDR screens, the normal photo everywhere else. Or lossless 16-bit TIFF.

FREE, THEN PRO
Light and Color adjustments, crop and presets are free — export them free too. Lumaforge Pro unlocks Curves, Grade, Detail, all masks and heal for a small subscription, with 7 days free. Cancel any time; your edits never require Pro to be made or saved — only to export.

Your photos are edited on your device. Lumaforge never sees them, stores them or uses them.
```
(~1,450 chars — under 3,000; room to grow.)

## 5. Keywords (100 chars, comma-separated, no spaces) [DRAFT]

```
raw,photo,editor,lightroom,develop,curves,mask,hdr,jpeg,heic
```
(100 chars. No app names other than Lightroom — Apple rejects competitor trademarks in
keywords. Do NOT include "lumaforge" — it's ignored if it matches the name.)

## 6. Promotional text (170 chars, changeable without review) [DRAFT]

```
Pro RAW editing on your iPhone: curves, AI masks and heal, on device. 7 days free.
```

## 7. Privacy / app data [GATE 4 + DRAFT]

Data collected: **None.** (No accounts, no analytics, no crash reporting in v1 — confirm
with the final build; if anything is added, the label must change.)
"Data Not Collected" — this is the strongest label Apple offers and a real selling point.

## 8. Age rating [READY] 4+ (no in-app purchases of anything risky; subscription = the 17 "mild"
check at most; 4+ is expected to pass)

## 9. Support URL / marketing URL [GATE 4] Angelo's website (Gate 3 landing page doubles as
the support page — one URL serves both).

## 10. Screenshot plan (6.7" required; 6.5"/5.5" optional) [READY — real captures on every push]

The `app-store-sandbox.yml` workflow now captures 10 real simulator screenshots of the app
on every push to `sandbox` (artifact `app-store-shots`). These are the actual app screens with
real edits pre-loaded, not mockups: 01 free Light edit, 02 Grade, 03 Curve, 04 Detail, 05 Masks
(AI sky mask), 06 Heal (people found), 07 Export options sheet, 08 Batch selection, 09 the
watermark (free user, Pro edit), 10 the paywall.

App Store screenshots are not raw captures: each is one of these composited inside a phone
frame with a one-line headline (672×480, 6.7"; 6.5" and 5.5" are the same images). Proposed
order and headlines for the final 6:
1. **01 free-light** — "Edit any RAW, free"
2. **03-curve** — "Full manual control"
3. **05-masks** — "AI masks: sky, subject, depth"
4. **06-heal** — "Remove people and objects"
5. **08-batch** — "Batch export your whole roll"
6. **10-paywall** — "Free to start. Pro when you need it."

## 11. App Preview video (optional, 15–30 s) [GATE 4]

Record on a real iPhone from the TestFlight build: import ARW → Light edits → Curve → mask →
heal → export. Slow, deliberate, one edit every ~2 s. No music in v1 (Apple allows it;
reviewer dislikes it less than a messy edit).

## 12. Subscription setup checklist [GATE 4 — for Angelo, in order]

1. App Store Connect → In-App Purchases → **Subscribe** (App Store Subscriptions)
2. Subscription group **Pro** → two products:
   - `lumaforge.pro.monthly` (placeholder ID — decide with final name), Auto-renewing, 1 month,
     Introductory Offer: **7 days free**, then UK price tier ≈ £1.09 (Apple tier 1)
   - `lumaforge.pro.annual`, Auto-renewing, 1 year, Introductory Offer: **7 days free**,
     then UK tier ≈ £7.99
3. Add a **Free Trial** (7 days) on both, or pick one (Apple allows intro offers; test
   both in the sandbox app on-device before submitting)
4. Agreement: enroll in a paid app agreement, banking details (you get paid ~monthly, minus 30%/15%)
5. The code (`LumenStore.swift`) already reads these product IDs — **they must match
   character-for-character** (see §13)
6. Sandbox testing on a real iPhone: use a TestFlight build + an Apple sandbox test account
   (App Store Connect → Users and Access → Sandbox Testers). Verify: purchase, trial, cancel,
   re-subscribe, restore on a second device.

## 13. Product IDs — single source of truth [GATE 4]

`Sources/Store/LumenStore.swift`:
- `static let monthlyID = "lumaforge.pro.monthly"`
- `static let annualID  = "lumaforge.pro.annual"`

When the final name is chosen: rename these two lines AND create the products with the
same IDs in App Store Connect. Nothing else needs to change.

## 14. Rejection-risk checklist (read before submitting) [DRAFT]

- [ ] Name in the store ≠ "Lumen"/"Lightroom"/any trademark (Lumaforge check: search the
      store first)
- [ ] 7-day free trial is clearly stated in the paywall AND the description (it is)
- [ ] Paywall is reachable but **not** blocking: the app is fully usable without paying
      (it is — free tier exports free edits)
- [ ] No external links to payment (there are none)
- [ ] "Data Not Collected" label is true for the exact submitted build (verify with the
      final build — if any logging/networking crept in, relabel)
- [ ] 4+ rating questionnaire matches the app (it will)
- [ ] Export gate wording doesn't claim features that differ between free/Pro (the plan's
      §4.1 line is the contract — keep it in sync with ProGate.swift)
