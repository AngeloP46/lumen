# Lumen App Store + marketing: Angelo's decisions

Angelo set these on 18 October 2026. They replace older pricing notes elsewhere, such as
"≈£1/month + ≈£8/year" in `HANDOFF.md`. Ask Angelo before changing any of them.

## Pricing (Angelo's decision: keep it)
- £1.49/month, £9.99/year, £29.99 one-off (lifetime).
- Prices are low to win users first.
- Code still never hardcodes prices: they always come from the loaded StoreKit `Product`.

## Free vs Pro
- **Free:** light and colour edits, crop, built-in presets.
- **Pro:** curves, detail, masks, heal, lens blur.
- The goal is paying customers, not free-only users.

## Claims and comparisons
- Compare only against **Lightroom mobile, Photomator and Darkroom**, never desktop Lightroom.
- Don't claim "Lightroom-level" until it has been tested.
- RAW formats are all tested, so it's fine to say so. CI "RAW format matrix" opens, edits and exports Canon CR2 and CR3,
  Nikon NEF, Fuji RAF, Sony ARW and DNG on every sandbox push (passing, e.g. run 38803054702). Angelo has
  confirmed iPhone ProRAW works in Lumen on his phone (18 October).

## Goal
- A paying hobby (about £1,300 in year one), not a salary.

## Channels
- **Landing page:** https://lumen-raweditor.netlify.app/ (waitlist: 5 signups so far, plus a comparison
  table). Don't break the signup form. Source is in `landing-page\` in the parent folder. Don't
  deploy without Angelo's go-ahead.
- **Angelo can't make videos or market himself.** Claude writes the content and drafts; Angelo approves
  every post and email before it goes out.
- **TikTok:** the first 3 posts flopped (no hook, no sound, "building an app" framing). It is not the
  main channel.
- **Main plan:**
  1. Reddit: answer posts where people ask for a Lightroom alternative on iPhone. The r/SideProject post
     got caught by spam filters, so write helpful replies to people asking, not self-promo posts.
  2. Email small photography YouTubers and iPhone app sites, offering free Pro.
- **Press:** pitches to 9to5Mac and DIYPhotography were sent on 18 October with the others (see below).

## Outreach status (18 October)
- **Sent 18 October:** 15 pitch emails went to 9 small YouTubers and 6 iPhone/photo news sites (including
  9to5Mac and DIYP). They offer free Pro and early/TestFlight access. Angelo is holding off on the $99 Apple
  fee until there's interest. Replies get the free SideStore build first, and the $99 gets paid only if
  people want it.
- The Gmail connector wraps links in a google.com redirect. All 15 emails got that link, so a correction reply
  with the clean link went to each thread the same day. Send emails that contain links through Gmail web in Chrome.
- The contact list lives outside this public repo: `deliverables\outreach-list.md` in the parent folder.
  All 15 emails name every tested format.
- Reddit is blocked for every Claude tool, including Claude in Chrome. Angelo posts there himself, using the
  ready-to-paste replies and search links in `deliverables\reddit-replies.md` (parent folder).
- Forum threads with reply drafts are in `deliverables\forum-replies.md`. Nothing has been posted.
- TikTok: Angelo found the animated clips (01-05) unengaging. The new format is photo-mode slideshows of his own
  edits, with the payoff first, a number-plate close-up and "Rate it 1-10" at the end. The first one is
  `Content\TikTok\06-huracan-slideshow`. AI-avatar "customer" testimonials are not made: they break the FTC/ASA
  rules on fake endorsements and TikTok's AI rules. An AI presenter script that makes no customer claims is there for in-person demos.
- Replies: David Addison declined (he dislikes Apple's Core Image RAW rendering; Lumen decodes with CIRAWFilter,
  with Apple's sharpening off). He offered an intro to Greg McMillan (iPhoneography podcast), and Angelo asked for it on 18 Oct. David sent greg@iphoneography.ca, and the pitch to Greg is in Gmail Drafts waiting for Angelo's OK.
- SEO page: `landing-page\edit-sony-raw-on-iphone.html` ("How to edit Sony RAW files on your iPhone"). It's built and
  LIVE since 18 Oct at https://lumen-raweditor.netlify.app/edit-sony-raw-on-iphone.html (with a sitemap). It isn't linked from the homepage.
- Batch 2: 19 more small YouTubers (car photography, iPad/mobile editing, Sony/Fuji), SENT 18 Oct through Gmail web; list in
  `deliverables\outreach-batch-2.md` (parent folder).

## Not wanted (product)
- Lens corrections, AI denoise, cloud sync, Smart fill.

## App name (22 Oct 2026)
The App Store name is **Lumen RAW** (Angelo). The SideStore build keeps "Lumen". "Lumaforge" in code (watermark, product IDs, bundle ID) is a placeholder still to change.
