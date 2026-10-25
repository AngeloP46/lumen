# Lumen RAW 1.0: content, licences and compliance (25 Oct 2026)

What App Store Connect and the law ask for beyond the listing (`LISTING.md`) and the release steps
(`RELEASE-CHECKLIST.md`). ✅ = done in the app or the docs, 🟡 = Angelo decides or fills in, 🔴 = must be done before
submitting. This is a practical checklist, not legal advice.

## 1. Licences for what ships inside the app ✅
| Ships in the app | Used for | Licence | What it asks |
|---|---|---|---|
| SCUNet (cszn/SCUNet) | AI Denoise | Apache 2.0 | keep the licence with it, credit |
| LaMa (advimman/lama; Core ML by mlboydaisuke) | Heal, Remove people | Apache 2.0 | same |
| Depth Anything V2 Small (Core ML by Apple) | Depth mask, Lens Blur | Apache 2.0 | same |
| DETR ResNet-50 segmentation (Core ML by Apple) | Sky and landscape masks | Apache 2.0 | same |
| Vision, Core Image, Core ML, StoreKit | Apple's own frameworks | Apple SDK terms | nothing extra |

All four allow commercial use in a paid app. Done (main, `appstore-compliance`): Library menu → **Acknowledgements**
lists each model, its authors and source, and the full Apache 2.0 text (`Sources/Legal/Apache-2.0.txt`). Fonts are
the system's. No other third-party code is in the app. Keep this table current when a model changes (the
`lumen-ai-models` rule already requires permissive licences only).

## 2. App Store Connect answers
| Question | Answer | Why |
|---|---|---|
| App Privacy ("nutrition label") | **Data Not Collected** | nothing leaves the phone; diagnostics only if the user shares the report themselves |
| Privacy manifest | ✅ `PrivacyInfo.xcprivacy` | no tracking, no data; UserDefaults (CA92.1), file dates (C617.1, 3B52.1) |
| Encryption / export compliance | ✅ No (`ITSAppUsesNonExemptEncryption = NO`) | only iOS's own HTTPS/StoreKit; no questions on each upload |
| Age rating questionnaire | all "None" / "No" → **4+** | no user content shared, no web browsing, no gambling |
| Content rights: third-party content? | **No** | users edit their own photos; the app ships no photos, music or video |
| Uses the Advertising Identifier (IDFA)? | **No** | no ads, no tracking |
| Sign-in for App Review | **Not required** | no accounts |
| Made for Kids | No | |
| Devices | ✅ iPhone only for 1.0 | an iPad build would need its own layout and 13-inch iPad screenshots |

## 3. Things Angelo must decide or fill in
- 🔴 **EU trader status (Digital Services Act).** Apple asks every developer whether they are a "trader". Selling
  subscriptions makes Lumen a business activity, so the expected answer is **trader**: Apple then shows a contact
  **address, phone number and email** on the EU App Store page. If that's not wanted, the alternatives are: a business
  address/virtual office or a PO box service that accepts legal post, or leaving the EU storefronts out at launch
  (UK and the rest of the world are unaffected). Decide before submitting.
- 🔴 **Paid Apps agreement, bank and tax** in App Store Connect (needed before in-app purchases can be sold). UK
  tax: App Store income is self-employment income; register for Self Assessment if total self-employed income goes
  over £1,000 in a tax year (trading allowance). Apple handles VAT on sales.
- 🟡 **Name check:** search the App Store and the UK IPO trade mark register (trademarks.ipo.gov.uk) for "Lumen" in
  photo apps (class 9). "Lumen RAW" is distinctive enough to try, but a clash can get the name refused.
- 🟡 **Copyright line** for App Store Connect: `© 2026 Angelo Parodi`.
- 🟡 **Terms of Use:** the paywall links Apple's standard licence (EULA), which is accepted for subscriptions.
  Add the same link at the end of the App Store description: `Terms of Use: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/`.

## 4. Screenshots and marketing material
- Use **only Angelo's own photos** in App Store screenshots and the preview video. The CI screenshot photos come
  from raw.pixls.us and Wikimedia: some of those licences require credit or forbid commercial use, so they are fine
  for tests but not for the listing.
- No other apps' names in the App Store name, subtitle, keywords or screenshots (guideline 2.3.7). The website's
  price comparison is fine on the website (dated, sourced, "may change"), but keep it out of App Store metadata.
- Photos showing identifiable people (the Remove people example): use people who agreed, or Angelo himself.
- Website libraries: GSAP (free "standard" licence, includes commercial sites) and Lenis (MIT): nothing to show.

## 5. Subscriptions (guideline 3.1.2) ✅
The paywall shows each price and period, the 7-day trial, "renew automatically unless cancelled, manage in your
Apple Account", Restore, the Privacy Policy and Terms of Use. App Store Connect still needs: a display name and a
one-line description for each product, the review screenshot of the paywall, and the privacy policy URL.

## 6. Website pages (need Angelo's go to publish)
- `app-privacy.html` → https://lumen-raweditor.netlify.app/app-privacy.html (privacy policy URL, required)
- `support.html` → https://lumen-raweditor.netlify.app/support.html (support URL, required)
- The waitlist privacy notice stays as it is.

## 7. App Review notes (paste into App Store Connect)
```
Lumen RAW is a photo editor; no account or sign-in is needed. To try it: tap + → From Photos and pick any photo
(RAW files such as DNG or ProRAW show every tool). AI features (masks, Heal, AI Denoise, Lens Blur) run on the device
with Core ML; nothing is uploaded. Pro tools can be tried for free; exporting a photo that uses them shows the paywall
(three products: monthly with a 7-day trial, annual, lifetime). Restore is in the paywall's top bar.
```
