# Lumen RAW: App Store listing (draft, 22 Oct 2026)

For Angelo to read and reword. Plain wording, no claims the app can't back up. Pro list matches
`Sources/Store/ProGate.swift`; prices match `Tests/store/LumenRAW.storekit`.

## Name (30 max)
`Lumen RAW` (9). Before registering: search the App Store for other "Lumen" photo apps (a clash can get the name
refused in App Store Connect).

## Subtitle (30 max), pick one
- `RAW photo editor for iPhone` (27)
- `Edit camera RAW on your phone` (29)

## Promotional text (170 max, can change without review)
Edit RAW files from your camera or iPhone on the phone itself. Light, colour and crop are free. Pro adds curves, AI masks, heal and AI Denoise.

## Description
```
I shoot a Sony A9 and wanted to edit the RAW files properly on my phone without paying a monthly fee for every basic tool. Lumen RAW is the editor I built for that.

OPENS THE RAW ITSELF
Sony ARW, Canon CR2/CR3, Nikon NEF, Fujifilm RAF, DNG and iPhone ProRAW. Lumen RAW decodes the RAW data, not the small preview inside it, so the highlight and shadow detail is there to pull back.

FREE
• Light: exposure, contrast, highlights, shadows, whites, blacks
• Colour: white balance (with a picker), vibrance, saturation, colour mix, black and white
• Crop, straighten, auto-level, perspective
• Built-in presets
• Export JPEG, HEIC or 16-bit TIFF, one photo or a whole batch

PRO
• Curves, colour grading and Detail (sharpening, texture, clarity, dehaze, noise reduction, grain)
• Masks: subject, people, sky, landscape parts, depth, brush, linear, radial, colour and luminance range
• Heal and Remove people
• AI Denoise for high-ISO photos
• Lens Blur
• HDR editing and HDR export for HDR screens

Everything runs on the iPhone. Your photos are never uploaded.

Edits never change the original file. Copy edits from one photo and paste them onto others, or pick which tools to paste.

Pro: £1.49 a month after a 7-day free trial, £9.99 a year, or £29.99 once. Free edits export without a watermark. Pro edits can be made and saved for free; Pro is needed to export them without the watermark.
```

## Keywords (100 max, commas, no spaces)
`raw,photo,editor,arw,dng,proraw,denoise,mask,curves,hdr,sony,camera,heal,tiff`
(No competitor names: Apple rejects them in keywords.)

## What's New (1.0)
`First release.`

## App Privacy
Data Not Collected. Diagnostics leave the phone only if the user taps Send diagnostics and sends the report
themselves. Re-check against the final build.

## Age rating: 4+

## URLs
- Privacy policy: https://lumen-raweditor.netlify.app/app-privacy.html (draft: `app-privacy.html` here)
- Support: https://lumen-raweditor.netlify.app/support.html (draft: `support.html` here)
Neither is published: Angelo's go is needed before deploying to Netlify.

## In-app purchases (App Store Connect)
| Product ID | Type | Price | Note |
|---|---|---|---|
| com.lumenraw.pro.monthly | Auto-renewable, group "Lumen RAW Pro" | £1.49 | 7-day free trial |
| com.lumenraw.pro.annual | Auto-renewable, same group | £9.99 | |
| com.lumenraw.pro.lifetime | Non-consumable | £29.99 | |

Bundle ID: com.lumenraw.app

## Screenshots
CI captures them on every sandbox push (artifact `app-store-shots`, see `docs/APPSTORE-ASSETS.md` §10). Masks and Heal
need real-phone captures (no AI in the simulator).
