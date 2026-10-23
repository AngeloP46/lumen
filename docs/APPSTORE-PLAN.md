# Lumen → App Store: Full Launch Plan (v2 — export-gated model)

> **How to use this document (for Claude):** This is a complete, researched plan covering everything
> needed to take Lumen from a free SideStore app to a paid App Store app. Angelo (the owner, not a
> coder) reviews and approves; you decide the technical route within the guardrails below.
> Work through the **Decision Gates** in order. Never recommend spending money (the $99 Apple fee)
> before Gate 4 is complete. Where a decision is marked **[ANGELO]** it needs his explicit yes/no —
> present options and a recommendation, don't decide for him.
>
> **Two hard rules from Angelo that override everything else in this document:**
>
> 1. **The SideStore build must remain exactly as it is today.** No paywall UI, no watermark, no
>    "Pro" state — not even dormant code if it can be avoided. AI features work, exports work,
>    full quality, forever. The SideStore CI pipeline and everything it reads (`project.yml`, the
>    current workflow, model-fetch scripts) is **frozen**: all App Store work is additive, in new
>    files, triggered separately.
> 2. **The App Store monetisation is an export gate, not a feature gate** (the Photomator model):
>    free users can open, edit with *every* tool and watch the result live. They just cannot
>    **export** a photo that used any Pro feature unless they subscribe. Photos that used only
>    basic manual edits export free, clean, full-resolution.

**Key point first:** the only real cost is the Apple Developer Program ($99/year ≈ £80). There is
no server, no backend — the app runs 100% on-device. Break-even is roughly **8–12 paying users per
year**. The raw-format worry is mostly solved by Apple's system RAW engine (already in the code).
The main risks are (a) the 322 MB download size hurting store conversion, and (b) launching before
marketing has proven any demand.

---

## 1. The app today (facts from the repo, verified)

- SwiftUI, XcodeGen (`project.yml`), iOS 18+ deployment target, iPhone + iPad (`TARGETED_DEVICE_FAMILY: "1,2"`).
- Bundle ID: `com.example.lumen` — **Apple will reject this; the App Store build must use a real
  one** (e.g. `com.angelo.lumen`). SideStore keeps the old ID (it's already out in the wild, and
  the different ID lets both installs coexist on one phone).
- CI: GitHub Actions on macOS runner → XcodeGen → **unsigned IPA** → SideStore feed. Build number
  = workflow run number. This pipeline is **frozen** (see Hard Rule 1).
- Three AI models compiled in CI and embedded in the IPA (~322 MB total): DepthAnythingV2Small
  (depth), DETRResnet50 semantic segmentation (sky/landscape), LaMa (heal).
- **No StoreKit / IAP code exists anywhere.** Payments are a clean addition.
- RAW decoding: `Engine.swift` routes any file whose UTType conforms to `.rawImage` through
  **Apple's `CIRAWFilter`** — the OS's own RAW engine. Key fact for §3.
- Picker: `LibraryView.swift` uses `.fileImporter` with `allowedContentTypes: [.rawImage, .image]`
  (any RAW type) plus Photos-library import for DNG/ProRAW originals.
- Edits are modelled in `EditSettings.swift`: per-photo settings with sections/flags, and the
  engine knows exactly which sections, masks and heals are active per photo — **this is what makes
  the export gate trivial to implement**: at export time the app already knows whether a photo
  touched any Pro feature.
- Views are tool panels in `EditorView.swift` (masks, heal, crop, curves, grading, export).
- Import sheet copy says "or ARW files from Files or an SD card" — this is what makes the app
  *feel* Sony-only. Marketing problem, not engine problem (§3).

---

## 2. The two builds (architecture)

One folder of source code, one repo, two independent build pipelines.

### 2.1 The separation mechanism (Claude decides exact implementation; the contract is fixed)

All paywall/watermark/StoreKit code goes into **new files only** (e.g. `Sources/Store/` and a
paywall view) and is compiled into the App Store build only, via a build setting switch (e.g. a
`SWIFT_ACTIVE_COMPILATION_CONDITIONS` flag set **in the App Store pipeline only**). In that
universe the app sees a `LumenStore` object; in the SideStore universe the flag is off, those
files are never compiled, and a small compile-time stub provides the same interface with
**"Pro = always on"** behaviour.

The contract:

| Behaviour | SideStore build | App Store build |
|---|---|---|
| Paywall UI | **None exists** | Shown at gated export |
| Watermark on preview | **Never** | When a Pro feature is active and user is not Pro |
| Export of Pro-edited photo | Always works | Requires Pro (or paywall) |
| Export of basic-edited photo | Always works | Always works, clean |
| AI masks / heal | Always work | Always work (viewable free) |
| Full-quality rendering | Always | Always |
| Bundle ID | `com.example.lumen` (frozen) | New ID (override in pipeline only) |
| Signing | Unsigned | Signed, App Store export |
| Trigger | Every push (frozen) | Manual/tag only |

`project.yml` stays untouched: the App Store pipeline overrides the bundle ID (and the
compilation flag) at build time. If Claude finds a cleaner mechanism that still leaves the
SideStore pipeline and `project.yml` byte-identical, that's fine — the contract above is what
matters. **After every App Store change, run the existing SideStore pipeline and confirm it
produces a normal feed entry with a working IPA.** That check is part of every PR.

### 2.2 CI

- **SideStore pipeline: frozen.** No edits.
- **New workflow file** (e.g. `.github/workflows/app-store.yml`), triggered manually or by tag
  (`as-*`), never on push:
  1. Reuses the same model-fetch scripts.
  2. Generates the XcodeGen project with overrides: new bundle ID + the App Store compilation flag.
  3. Signs with an App Store distribution certificate (`.p12`) + provisioning profile, stored as
     GitHub Actions **encrypted secrets** (one-time manual download by Angelo, §6 step 3).
  4. `xcodebuild archive` → export IPA (`method: app-store`) → upload to App Store Connect.
  5. Versioning: date-stamped or run-number build, always higher than the last uploaded (Apple
     rejects same/lower build numbers per version).
  6. **TestFlight:** distribute the same archive to an internal TestFlight track for Angelo's
     phone before public release.
- Certificates are **never generated in CI** — document the exact Apple pages for the one-time
  download.

---

## 3. The RAW format question (Angelo's concern)

**Finding: Lumen already works with nearly every camera's RAW files, with zero code changes.**

- iOS/iPadOS have system-level RAW support for third-party cameras, and Apple publishes the list —
  it is effectively the entire market: **Canon (all EOS/PowerShot), Nikon (all D/Z), Fujifilm
  (all X/GFX), Sony, Olympus, Panasonic, Leica, Hasselblad, Phase One, and DNG from anything** —
  https://support.apple.com/en-us/127493
- Lumen's `CIRAWFilter` path uses exactly that system engine. If the OS can decode the file,
  Lumen can edit it.
- The picker already accepts `.rawImage` of any vendor; iPhone ProRAW (DNG) arrives via the
  Photos-library import path.

**What still needs doing (small):**

1. **Test with real files** (unverified until done): Canon CR2/CR3, Nikon NEF, Fujifilm RAF,
   Panasonic RW2, converted DNG, iPhone ProRAW. Each: opens, orientation correct, histogram
   correct, export round-trips. The only engineering risk in this question. **Hard requirement
   before Gate 2 is marked done.**
2. **Fix the copy**: import sheet + App Store description say "edit RAW from any camera".
3. **Know the one real limitation:** camera RAW imported into iPhone Photos sometimes arrives as
   DNG rather than vendor RAW. DNG is supported — but support replies should expect it.
4. Optional (post-launch): a "supported cameras" page listing Apple's list by brand — also a
   marketing asset.

---

## 4. Monetisation: the export-gate model (Photomator-style)

### 4.1 The rule

- **Free users:** open any photo, use **every** tool, see the full live result. Export:
  - Photo used only **basic** features → exports free, clean, full-resolution.
  - Photo used **any Pro feature** → export button opens the paywall. After subscribing, export
    works.
- **Pro users:** export everything, no watermark, no prompts.

**The free/Pro line (Angelo's decision, locked):**
- **Free export:** photos that used only **Light & Color** adjustments, **crop/rotate/straighten**,
  and **presets** export free, clean, full-resolution.
- **Pro (everything else):** curves, sharpen/denoise, HDR, all masks (AI sky/subject/depth/
  landscape and manual brush/shape), and Heal. A photo that used any of these → export requires
  Pro.

Note: free users can still *use* the Pro tools and see the live result — the gate is at export
only (§4.1 model). This line is what the paywall and marketing copy describe: "Free: light,
color, crop, presets. Pro: curves, AI masks, heal, and everything else."

**Implementation note for Claude:** the gate is at the **export path only** —
`EditorViewModel`'s export functions and the export views. The app already knows per-photo which
sections/masks/heals are active (`EditSettings`), so the check is: `photo.usesAny(ProSet) && !store.isPro
→ paywall`. Everything else — panels, preview, canvas — is untouched. "Used" should mean
*currently active or contributing* (a disabled section doesn't count; a mask with zero brush
strokes shouldn't count — verify against how `disabled`/empty states work).

### 4.2 Pricing

- Apple Developer Program: **$99/year**.
- **Small Business Program** → **15%** on subscriptions (not 30%); Angelo qualifies (<$1M revenue).
  Apply in App Store Connect before launch (few days to approve).

| Offer | Angelo keeps per user/year | Users to cover the $99 |
|---|---|---|
| £1.00/month (closest Apple tier) | ~£10.20 | **8** |
| £7.99/year (closest Apple tier) | ~£6.79 | **12** |

- **Offers (Angelo's decision, locked):** monthly + annual, **7-day free trial on monthly**.
  Angelo wants **≈£1/month and ≈£8/year** — Apple only offers fixed price tiers, so at
  product-creation time pick the **closest available UK tiers** (expect ≈£1.49/mo and
  ≈£7.99–£8.99/yr; the exact ladder is visible in App Store Connect when the product is made —
  confirm with Angelo which adjacent tier he wants if two are equally close).
- **Worldwide availability, English only.** Apple auto-localises prices to each country's ladder;
  **do not translate** any app text, paywall copy or store description.
- **Post-launch option (not launch scope):** a one-time "lifetime Pro" (~£29.99) — ~35% of apps
  now mix lifetime purchases with subscriptions [3], and RAW enthusiasts often hate subscriptions.
- **No ads, no consumables, no per-export metering.** Keep it one subscription.

### 4.3 Revenue reality (grounding the "£99 for nothing" fear)

- Typical freemium app: ~9% of free users convert to monthly subs; ~5.3% monthly churn [3].
- Realistic goal for a niche RAW editor: **a few hundred paying users = costs covered ~10× over.**
- The $99 fee is the *small* risk (it covers the whole year — launch can slip months without extra
  cost). The real risk is launching without marketing (§7). The gates in §9 ensure no money moves
  until the app and demand are proven.

### 4.4 The paywall screen (App Store build only)

- Triggered **only** from the export gate.
- Content: what Pro unlocks (clean full-res export of Pro-edited photos), monthly/annual rows with
  prices from the loaded `Product` (never hardcoded), "7-day free trial" line, **Restore** button
  (Apple requirement), privacy line ("your photos never leave your device"), a "keep editing
  free" close path (the app must remain fully usable without paying — review requirement 3.1.1
  is satisfied because everything digital is purchased via IAP; nothing links out to payment).
- StoreKit 2 (no SKPaymentQueue): `Transaction.currentEntitlements` + `Transaction.updates`,
  `AppStore.sync()` for restore, products loaded by ID.
- A small "Pro" badge next to mask/heal tools so the export gate is never a surprise.

---

## 5. Anti-screenshot / piracy protection

**State the limit honestly:** you cannot stop screenshots or screen recordings on iPhone — Apple
doesn't allow apps to block them. The model is: **screenshots are visible as screenshots, and
clean full-res output only exists through the real export (paywalled).** This is exactly how
Photomator/Lightroom/VSCO operate.

### 5.1 Watermark (App Store build, free users only)

- When a photo has any Pro feature active **and** the user is not Pro: the preview (and the 100%
  zoom view) shows the watermark — **Angelo's decision, locked: big enough to be clearly
  visible**, not subtle. Design: the app's logo, large (e.g. 25–35% of screen width), in a
  corner, with an opacity that stays visible when screenshotted but doesn't block editing
  (~15–25%). **Logo and final name are still Angelo's to confirm** — see the naming note in §11.
  Claude should prototype two placements (corner vs centre-low) at that size and let Angelo pick
  on his own phone before Gate 2 is marked done.
- Shown in every view of the photo (canvas, 100% view). Free exports of basic-edited photos are
  **always clean** — the watermark only ever appears on Pro-edited previews.
- SideStore build: watermark code never compiled (Hard Rule 1).
- Implementation: a pure overlay layer above the canvas image in the App Store build — does not
  touch the Core Image pipeline or the export pipeline at all.

### 5.2 What NOT to do

- No "blank the screen on screenshot" tricks — hostile to legit users, trivially defeated.
- No resolution degradation of previews — it damages the product demo; the watermark is enough.
- Don't chase AirPlay recording or camera-on-screen; nobody stops it, it's not the model.

### 5.3 What it achieves

| Attack | Result |
|---|---|
| Screenshot | Watermarked, screen-res, no EXIF/adjustments → not usable as a clean deliverable |
| Screen recording | Same |
| Copying settings by eye | Unstoppable, irrelevant — the edit is the product, not the recipe |
| Clean export | Subscription only |

---

## 6. Apple-side setup (Angelo's manual work, ~2–3 hours, one-time — ONLY at Gate 4)

1. **developer.apple.com → enroll** ($99, name + card). Wait for email.
2. **App Store Connect → My Apps → + → New App**: name "Lumen", primary language English (UK),
   bundle ID = the new one.
3. **Certificates & profiles:** App Store distribution certificate + App Store provisioning
   profile for the bundle ID → export `.p12` + profile → GitHub Actions encrypted secrets.
4. **Small Business Program** application (15% fee) — needs bank details; start before launch.
5. **Products → Subscriptions:** one group "Lumen Pro", monthly + annual, UK tiers, 7-day trial
   on monthly, review info (what it unlocks, what the app does). **Subscription products need
   ~1 business day of Apple review** — schedule it.
6. **App record:** description + subtitle + keywords (30 chars, no spaces — "raw editor,
   lightroom, photo, arw, proraw, ai masks, on device"), **iPhone 6.5" screenshots only**
   (iPhone-only launch — see §11), App Privacy labels (photos processed on-device, not
   collected; declare photo-library access), age rating (all ages), support URL, **privacy policy
   URL** (one static page: "<App name> processes photos on your device; nothing leaves it;
   contact <email>").
7. **Pricing/availability:** worldwide, Apple auto-localises prices, English text only.
8. **Submit** → typically 1–7 days. **Instant release to 100%** (Angelo's decision: no existing
   user base, wants maximum reach — phased release is only useful for gradual testing and buys
   nothing here).

**No Mac required — how the signing works without a MacBook (Angelo has no Mac; this is by
  design):**
- The GitHub Actions runner **is** the Mac — the same one already building the SideStore IPA.
  Angelo never needs Xcode or a Mac of his own.
- The distribution certificate and provisioning profile are created **in a web browser** at
  developer.apple.com (works on Angelo's PC or phone): a few clicks, then two small files are
  downloaded.
- Claude uploads those two files to the GitHub repo as **encrypted secrets** (Claude can walk
  Angelo through the GitHub settings screen by screen), and the App Store pipeline reads them
  automatically. One-time, ~15 minutes of clicking; every build after that is fully automatic.

**Review-risk note:** photo editors are unproblematic for Apple. The export gate keeps the free
version genuinely functional (import → manual edit → free export works end-to-end), which is what
review needs. IAP is used for all digital access (3.1.1 satisfied). No external payment links.

---

## 7. Marketing plan (this decides whether the fee is wasted)

**Angle:** *"Lightroom-class RAW editing on your iPhone, free to use — and your photos never
leave the phone."* The on-device privacy point is a real differentiator; the free tier is a
shareable fact that makes community posts non-spammy.

### 7.1 Before launch (3–4 weeks, free)

- **Landing page + waitlist:** one page, demo GIF of the AI sky mask on a real ARW, "free on the
  App Store — [date]", email capture. **The demand probe: ~2 weeks, then count.**
- **Before/after content:** the highest-converting type for editors. 5–10 clips ≤60s: dull RAW →
  graded RAW, AI sky mask in 2 taps, heal removing a tourist. TikTok, YouTube Shorts, and
  (respecting self-promo rules) r/IPhonography, r/sonyalphaphotography, r/photography,
  r/PhotoEditing.
- **The "I built this" story:** "I built a free Lightroom for iPhone that runs entirely
  on-device" — r/iOSProgramming, r/indiehackers, Show HN, Mastodon.
- **TestFlight beta (at Gate 4):** 5–10 people, one week, fix, then public.

### 7.2 Launch day

- **Product Hunt** (one well-prepared launch ≈ a week of downloads).
- Before/after clips with the store link; reply to every review for two weeks.

### 7.3 Ongoing

- One before/after clip weekly; ASO upkeep (keywords monthly, screenshots on feature ships).
- In-app review request (SKStoreReviewController) after 3rd+ export, max once/90 days.

### 7.4 KPIs (App Store Connect → Analytics)

- Downloads/week (target: 300+ by week 4 = healthy niche).
- Paywall reach: 15–30% of downloads hit the export gate.
- Trial→paid: 40–60% on a 7-day trial.
- **Paying users: 10 = break-even · 50 = fee earned · 150 = real business.**

---

## 8. SideStore (unchanged by all of this)

- Keep it alive: it's free, it's the power-user channel, costs nothing.
- The App Store free tier means nothing is lost by switching: everything still works, and the
  App Store version adds nothing the SideStore version lacks.
- The ~16 Oct free-signature expiry still applies (LocalDevVPN + Refresh All) — untouched.
- Long-term option (not now): point SideStore at the real build or retire it.

---

## 9. Decision gates (do not skip ahead)

**Gate 1 — Model + pricing decided [ANGELO]:** free/Pro feature line (Decision 1), price tiers,
trial, watermark design (Decision 2), iPad (Decision 3). *(Nothing costs money.)*

**Gate 2 — Code [Claude]:** StoreKit module + paywall behind the build flag, export gate,
watermark overlay, App Store CI pipeline (new file only, `project.yml` untouched), §2.2 build
contract verified on a test build, and hygiene items (App Store icon set, `ITSAppUsesNonExemptEncryption: false`).
**Hard requirements: RAW test matrix passed (CR2, CR3, NEF, RAF, ARW, DNG, ProRAW — open/edit/
export), and the SideStore pipeline re-run successfully producing a normal feed entry with a
working, paywall-free IPA.** *(Nothing costs money. If a RAW format fails, report it — DNG is
the safety net — don't paper over it.)*

**Gate 3 — Demand probe [Angelo]:** landing page live, ~2 weeks of content, waitlist ≥ 50 or
equivalent community interest. If weak: fix the message, re-probe; the $99 stays unspent.

**Gate 4 — Pay the fee & submit [Angelo]:** $99 → developer account → §6 setup → TestFlight beta
(5–10 people, 1 week) → fix → **submit for review.**

**Gate 5 — Launch [Angelo]:** approval → phased or instant release → marketing push → 4 weeks of
KPI watching → first pricing/feature review with real numbers.

---

## 10. Post-launch backlog (ranked, none urgent)

1. Download models on first use to shrink the IPA (322 MB → ~100 MB) — biggest conversion lever.
2. One-time "lifetime Pro" purchase (experiment).
3. iPad polish (or drop iPad at launch — Decision 3).
4. RAW support page (Apple's camera list by brand).
5. DNG export option.
6. Android port (only if iOS revenue proves out).

---

## 11. Decisions (Angelo's — status)

| # | Decision | Status |
|---|---|---|
| 1 | Free vs Pro line | **Locked:** free export = Light & Color + crop/rotate + presets. Everything else = Pro. |
| 2 | Watermark | **Locked:** clearly visible, large (25–35% screen width), corner, ~15–25% opacity, on Pro-edited previews only. Claude prototypes placements; Angelo picks. |
| 3 | iPad | **Locked:** iPhone-only at launch (Angelo can't test iPad). Revisit later. |
| 4 | Release style | **Locked:** instant release to 100% (no existing users; maximum reach). |
| 5 | Availability | **Locked:** worldwide, English only, no translations. |
| 6 | Prices | **Locked:** ≈£1/month (7-day trial) + ≈£8/year → closest Apple UK tiers at product-creation time. |
| 7 | **App name & logo** | **Placeholder set: "Lumaforge"** — final name Angelo's to confirm before Gate 4. See below. |

### 11.1 The name (placeholder now, final before Gate 4)

**Findings (web-verified):**
- "Lumen" is taken by **"Lumen: Photo Editor, Retouch"** (id1514363710, actively updated) — same
  category, so keeping that exact name risks a guideline 4.2 rejection and search confusion.
- **"Lumaforge" (the placeholder) is also already taken** by "LumaForge - Photo Editor"
  (id6761913120, FilmPix Studios). It is therefore a **build placeholder only** — it must not be
  the submitted name.

**Working rules for Claude:**
- Use **"Lumaforge"** everywhere in code, paywall copy, the App Store pipeline, TestFlight build
  names and placeholder screenshots. Keep it in one place (a single constant / the App Store
  pipeline's display-name override) so the real name is a one-line swap.
- The **final name is Angelo's decision, due before Gate 4** (app record creation in App Store
  Connect — easy to change before first submission, awkward after). When he picks one, run a
  fresh App Store name check (search the App Store for the exact name + "photo editor") and
  confirm no clash before it goes in the app record.
- The final name must: (a) not clash in the App Store photo category, (b) fit an icon, (c) pair
  with the subtitle **"RAW Photo Editor"** (the subtitle carries the search visibility, not the
  brand).
- The SideStore app keeps its existing name regardless — the rename only affects the App Store
  build (display name override in the pipeline) and, if Angelo wants, the shared icon asset later.

### 14 October clarification — free presets

Angelo confirmed: built-in preset looks export free, including their strength control, while
additional Pro edits still require Pro. Validate the actual advanced settings against the
built-in recipes; never waive the gate merely because a preset was once applied. HDR, active
masks and healing stay Pro even when a preset is added. Arbitrary saved/custom presets do
not receive a blanket exemption. Single exports, batches, copying and saved-edit reloads
must all use the same rule.
