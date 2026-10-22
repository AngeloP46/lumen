# Lumen RAW 1.0: release checklist (from 22 Oct 2026)

**Feature freeze:** until 1.0 is live, only fixes go in (main and sandbox). New features are noted at the bottom and
wait.

## The bar for submitting
- About a week of Angelo's normal use with no crash and no iOS closure (diagnostics: "went to the background" or
  "open now" on every launch line, never "ended while Lumen was open").
- TestFlight: 3–5 testers on different iPhones (one 4–6 GB model, e.g. iPhone 13 / 14) for several days, same rule.
- The App Store compile check, StoreKit test and UI tests are green on the build that is submitted.

## Run through on the phone, every release candidate (about 10 minutes)
1. Import from Photos: a Sony ARW, an iPhone ProRAW (48 MP) and a JPEG.
2. RAW: Light, Color, Curve, Grade, Detail; HDR on and off; crop and straighten.
3. Masks: Subject, Sky, People, Depth, a brush; adjust each.
4. Heal: one spot, Remove people; undo and redo.
5. AI Denoise on the ARW and on the ProRAW; zoom to 100 % straight after.
6. Lens Blur on a portrait.
7. Export: JPEG, HEIC with HDR, TIFF; batch export 10 photos.
8. Library: copy edits, Paste → Look only / Choose…; delete a photo.
9. Leave Lumen during AI Denoise, come back: it carries on.
10. App Store build only: free export of a Pro edit shows the paywall and watermark; buy (sandbox account), restore.
11. ⋯ → Send diagnostics: no crash, peak memory under ~2.8 GB.

## Steps that need Angelo
1. Apple Developer Program (Individual, ~£79/year): developer.apple.com/programs/enroll.
2. App Store Connect → Users and Access → Integrations → App Store Connect API → generate a key with the **Admin**
   role. Note the Key ID and Issuer ID, download the .p8 (only downloadable once).
3. GitHub → AngeloP46/lumen → Settings → Secrets and variables → Actions → add `ASC_KEY_ID`, `ASC_ISSUER_ID`,
   `ASC_KEY_P8` (the whole .p8 file's text) and `APPLE_TEAM_ID` (developer.apple.com → Account → Membership).
4. App Store Connect → Apps → + New App: name Lumen RAW, bundle ID com.lumenraw.app (appears after the first
   TestFlight run registers it), SKU lumenraw.
5. In-app purchases as in `LISTING.md` (two subscriptions in group "Lumen RAW Pro", one non-consumable); paid apps
   agreement, bank and tax details.
6. Read the listing, pick a subtitle, approve the privacy and support pages for the website.

Then Claude runs **TestFlight upload** (`gh workflow run testflight.yml --ref sandbox`) and the build reaches
TestFlight in about 30 minutes.

## Waiting until after 1.0
- iPad layout and screenshots.
- iPhone SE landscape Crop panel (2 pt overlap).
